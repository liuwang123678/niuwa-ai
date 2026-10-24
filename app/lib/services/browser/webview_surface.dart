import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 驱动和真 WebView 之间的**接缝**。抽这一层纯粹是为了能测。
///
/// 真的 `WebViewController` 要 `WebViewPlatform.instance`（插件在 `MainActivity`
/// 里注册），单测里造不出来——它是个带私有构造的具体类，也没法继承。而
/// "手机上到底能不能干活"这件事如果只有真机才知道，那它平时就是一句验证不了
/// 的话。所以把驱动真正用到的那几件事抽成一个几行就能实现的接口。
///
/// ⚠️ 抽的是**能力**不是**实现细节**：这里不出现 Pigeon、不出现 JS 源码。
abstract class WebViewSurface {
  /// 建好 WebView 并**把 JS 打开**。
  ///
  /// 🩸 实现里必须调 `setJavaScriptMode(JavaScriptMode.unrestricted)`。安卓的
  /// `WebSettings` **默认 JS 是关的**，不调的话所有 `runJavaScript`
  /// **静默无效**——不报错、不抛异常，就是不执行。你会以为是自己脚本写错了，
  /// 然后去改一个根本没被运行的脚本。
  Future<void> prepare();

  Future<void> navigate(String url);

  /// 跑一段 JS，返回**原始**结果。
  ///
  /// ⚠️ "原始"是重点。安卓那条路会把返回值过一遍
  /// `num.tryParse(result) ?? result`，所以到手的可能是 num、bool 或 String，
  /// 而且字符串**带着外层引号和转义**。怎么解交给
  /// [decodeScriptPayload] / [BrowserSnapshot.fromScriptResult] / [unwrapJsString]，
  /// 这一层别自作聪明，也别抛。
  Future<String> evaluate(String js);

  Future<void> historyBack();

  /// 上一次导航失败的原因（已经翻成人话）。成功时是 null。
  ///
  /// 存在的理由：`loadRequest` 是**成功返回**的——域名解析不了、这个站被墙、
  /// 明文被系统挡掉，它都不报错，错误悄悄走 `onWebResourceError`。不看这个
  /// 字段的话，模型会收到一个空白页快照，然后开始怀疑自己的选择器写错了。
  String? get lastLoadError;

  void clearLoadError();

  /// 给视图层显示用的句柄。假的实现返回 null。
  ///
  /// **驱动为什么要暴露这个**：安卓的 WebView 不 attach 到窗口就没有布局，
  /// 快照会读到**零个元素**。所以视图层必须把它挂进 widget 树（移出屏幕、
  /// 但保持真实尺寸），那就得拿到 controller。
  WebViewController? get controller;
}

/// 真的那个。
class PlatformWebViewSurface implements WebViewSurface {
  PlatformWebViewSurface({WebViewController? controller})
    : controller = controller ?? WebViewController();

  @override
  final WebViewController controller;

  String? _lastLoadError;

  @override
  String? get lastLoadError => _lastLoadError;

  @override
  void clearLoadError() => _lastLoadError = null;

  @override
  Future<void> prepare() async {
    // 🩸 这一句不能省。见接口上的说明。
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);

    // 加载过程中会先铺一层底色再画内容，不设的话那一瞬间是白的，
    // 而我们把它挂在界面底下——不设就是"底下闪一下白"。
    await controller.setBackgroundColor(const Color(0x00000000));

    await controller.setNavigationDelegate(
      NavigationDelegate(
        onWebResourceError: (error) {
          // 只认主框架的错。子资源（图片、统计脚本、广告位）挂掉是常态，
          // 拿它当"这个页面打不开"会误报得离谱。
          if (error.isForMainFrame == false) return;
          _lastLoadError = describeLoadError(error);
        },
        onPageFinished: (_) {
          // 这一页成功了，把上一页留下的错清掉。不清的话，第一次失败之后
          // 后面每一次 open 都会报上一次的错。
          _lastLoadError = null;
        },
      ),
    );
  }

  @override
  Future<void> navigate(String url) => controller.loadRequest(Uri.parse(url));

  @override
  Future<String> evaluate(String js) async {
    final result = await controller.runJavaScriptReturningResult(js);
    return '$result';
  }

  @override
  Future<void> historyBack() => controller.goBack();
}

/// 把 WebView 的加载错误翻成**给模型看的一句话**。
///
/// 抽成顶层函数是为了能直接测：`WebResourceError` 是个普通数据类，不需要
/// 任何平台实现就能造出来。
String describeLoadError(WebResourceError error) {
  final description = error.description;

  // 明文网页在安卓上会被系统挡掉（`targetSdk >= 28` 默认禁止 cleartext），
  // 报出来是 `net::ERR_CLEARTEXT_NOT_PERMITTED`。**这句必须翻译**：
  // 模型看见 `net::ERR_...` 只会换个选择器瞎试，试到轮数用完为止。
  if (description.toUpperCase().contains('CLEARTEXT')) {
    return '这个站是 http 的，安卓不让开明文网页。'
        '换一个 https 的地址，或者用 http_fetch 抓它的内容。';
  }

  // 一个字的页面都没有，多半不是站点的问题，是没连上网
  if (description.contains('ERR_NAME_NOT_RESOLVED') ||
      description.contains('ERR_INTERNET_DISCONNECTED') ||
      description.contains('ERR_ADDRESS_UNREACHABLE')) {
    return '打不开这个页面：连不上（$description）。先确认手机有网，'
        '或者这个域名是不是拼错了。';
  }

  return '打不开这个页面：$description';
}
