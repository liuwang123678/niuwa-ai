import 'dart:async';

// `Uint8List` 从这儿来（foundation 会把它带出来），所以不用再单独
// import 'dart:typed_data' —— 两个都写是 analyzer 的 unnecessary_import。
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/browser/browser_driver.dart';
import '../../core/browser/snapshot_script.dart';
import 'webview_surface.dart';

/// 安卓上的浏览器驱动：**驱动 App 自己那个 WebView。**
///
/// 和 Windows 那套（拉起临时 Edge）不一样，这里没有"干不干净"的问题——这个
/// WebView 是 App 自己造的，一开始就什么 cookie 都没有，用完跟着页面一起没。
/// 所以"遇到登录就停下来找用户"这条在两端都成立。
///
/// ## 三件必须做对的事
///
/// 1. 🩸 **JS 必须显式打开**（在 [WebViewSurface.prepare] 里）。安卓
///    `WebSettings` 默认是关的，不打开的话所有脚本**静默无效**。
/// 2. 🩸 **视图必须挂进 widget 树**，而且要**真实尺寸**。不 attach 就没有布局：
///    `getClientRects()` 全空 → 快照读到**零个元素**；`window.innerHeight` 是 0
///    → 滚动滚不动。这不是"能不能跑 JS"的问题，是"页面上有没有东西可读"。
///    见 `BrowserHost`。
/// 3. **截图做不到**。`webview_flutter` 没有截图 API，所以 [screenshot] 会
///    **如实报错**——不能返回空字节然后让上层说"页面可能还没加载出来"，
///    那是撒谎。
class WebViewBrowserDriver extends BrowserDriver {
  WebViewBrowserDriver({
    WebViewSurface Function()? createSurface,
    this.settleDelay = const Duration(milliseconds: 250),
    this.loadTimeout = const Duration(seconds: 15),
    void Function(String message)? logger,
  }) : _createSurface = createSurface ?? PlatformWebViewSurface.new,
       _log = logger ?? ((m) => debugPrint('[browser] $m'));

  final WebViewSurface Function() _createSurface;
  final void Function(String message) _log;

  /// 点完/填完之后等一小会儿。页面上的 JS 渲染、下拉建议、表单校验都是
  /// "点完立刻"发生的，不缓一下拍到的是中间态。
  final Duration settleDelay;

  /// 等 `document.readyState === 'complete'` 的上限。
  final Duration loadTimeout;

  WebViewSurface? _surface;
  Future<void>? _warming;

  bool _ready = false;
  bool _hostMounted = false;
  bool _disposed = false;
  String? _reason;

  @override
  bool get isAvailable => _ready && _hostMounted && !_disposed;

  /// 手机上浏览器能力一直在（一个隐藏 WebView），只是可能还没挂上/热好。
  @override
  bool get supportsWarmUp => true;

  /// 给 `BrowserHost` 拿去渲染 [`WebViewWidget`] 的。
  ///
  /// 为什么驱动要往外递这个：安卓的 WebView **不挂进 widget 树就没有布局**，
  /// 快照会读到零个元素。所以视图层必须把这个 controller 贴进树里（移出屏幕、
  /// 但保持真实尺寸）。见 [WebViewSurface.controller]。
  WebViewController? get controller => _surface?.controller;

  @override
  String? get unavailableReason {
    if (isAvailable) return null;
    final reason = _reason;
    if (reason != null) return reason;

    // 到这儿只有一种情况：WebView 建好了、JS 也开了，**但视图还没挂进界面**。
    // 这时候工具是"能跑但读不到东西"，比不能用更坏——模型会拿着空快照
    // 一直换选择器重试，直到轮数用完。所以宁可说"用不了"。
    //
    // 会看到这一句基本只有一个原因：`BrowserHost` 没被挂进 widget 树（接线断了）。
    // 正常运行时天然不会出现——第一帧就挂上了。
    return '浏览器还没准备好（页面视图还没接上）。这一句先别用浏览器，'
        '改用 http_fetch，或者如实告诉用户稍后再试。';
  }

  // ────────────────────────────────────────────────────────────────
  // 预热
  // ────────────────────────────────────────────────────────────────

  /// 幂等：重复调只等第一次那个 future。
  ///
  /// **绝不抛异常**——boot 阶段是 `unawaited` 调的，让异常逃出去就成了
  /// unhandled async error，直接打崩 zone。
  @override
  Future<void> warmUp() => _warming ??= _doWarmUp();

  Future<void> _doWarmUp() async {
    if (_disposed) return;
    try {
      final surface = _createSurface();
      await surface.prepare();
      _surface = surface;
      _ready = true;
      _reason = null;
      _log('手机上的浏览器就绪（JS 已打开）。');
    } catch (e) {
      // 单测里没有平台实现时就走这儿：`WebViewPlatform.instance` 是 null，
      // 造 controller 直接抛。这是**正常的退化**，不是 bug。
      _fail('手机上的浏览器起不来：$e');
    }
  }

  void _fail(String reason) {
    _ready = false;
    _reason = reason;
    _log(reason);
  }

  // ────────────────────────────────────────────────────────────────
  // 视图接线
  // ────────────────────────────────────────────────────────────────

  /// `BrowserHost` 挂上之后调这个。**没挂上就不干活**——见 [unavailableReason]。
  void markHostMounted() {
    if (_hostMounted) return;
    _hostMounted = true;
    _log('浏览器视图已挂上。');
  }

  /// `BrowserHost` 卸载时调。App 关掉时也会走到这儿。
  void markHostUnmounted() => _hostMounted = false;

  // ────────────────────────────────────────────────────────────────
  // 操作
  // ────────────────────────────────────────────────────────────────

  WebViewSurface _requireSurface() {
    if (_disposed) throw const BrowserException('浏览器已经关掉了。');
    final surface = _surface;
    if (surface == null || !_ready) {
      throw BrowserException(_reason ?? '浏览器现在用不了。');
    }
    if (!_hostMounted) {
      throw const BrowserException(
        '浏览器视图还没挂到界面上，这会儿读不到页面内容。过一下再试。',
      );
    }
    return surface;
  }

  @override
  Future<void> open(String url) async {
    final surface = _requireSurface();

    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw BrowserException('"$url" 不是个能打开的网址。要带 http:// 或 https://。');
    }

    surface.clearLoadError();
    await surface.navigate(uri.toString());
    await _waitForLoad(surface);

    // 导航失败时 `loadRequest` 是**成功返回**的，错误在 delegate 里。
    // 不看它就等于给模型一个空白页，然后它开始怀疑自己的选择器。
    final error = surface.lastLoadError;
    if (error != null) throw BrowserException(error);
  }

  @override
  Future<BrowserSnapshot> snapshot() async {
    final surface = _requireSurface();
    final raw = await surface.evaluate(browserSnapshotJs);
    return BrowserSnapshot.fromScriptResult(raw);
  }

  @override
  Future<void> click(String ref) async {
    final surface = _requireSurface();
    ensureBrowserScriptOk(
      await surface.evaluate(browserClickJs(parseBrowserRef(ref))),
    );
    await _settle();
  }

  @override
  Future<void> type(String ref, String text) async {
    final surface = _requireSurface();
    ensureBrowserScriptOk(
      await surface.evaluate(browserTypeJs(parseBrowserRef(ref), text)),
    );
    await _settle();
  }

  @override
  Future<void> scroll(ScrollDirection direction, {double amount = 0.8}) async {
    final surface = _requireSurface();
    ensureBrowserScriptOk(
      await surface.evaluate(browserScrollJs(direction, amount)),
    );
    await _settle();
  }

  /// **如实失败**：这个平台的 WebView 不给截图接口。
  ///
  /// 架构文档里原来写的是"用 `RepaintBoundary` 截 WebView 区域"——那个方案
  /// 要求 WebView 在树上是**可见**的，而我们是把它挂在界面底下的，不成立。
  ///
  /// 返回空字节的话，上层现有逻辑会判失败，但**错误文案是错的**（它写的是
  /// "页面可能还没加载出来"）。那是撒谎：页面好得很，是这儿截不了。所以
  /// 直接抛一句真话，让模型改用 snapshot。
  @override
  Future<Uint8List> screenshot() async {
    _requireSurface();
    throw const BrowserException(
      '手机上截不了页面图（这个平台的 WebView 不给截图接口）。'
      '要看页面内容就用 browser_snapshot，它能把文字和可点元素都读出来。',
    );
  }

  @override
  Future<void> back() async {
    final surface = _requireSurface();
    await surface.historyBack();
    await _waitForLoad(surface);
  }

  Future<void> _settle() => Future<void>.delayed(settleDelay);

  /// 等页面加载完，再加一小段静默期。
  ///
  /// 不等的话会拍到半成品：`loadRequest` 一返回就去读 DOM，读到的往往是还没
  /// 跑 JS 的空壳。这是"快照是空的"最常见的直接原因。
  Future<void> _waitForLoad(WebViewSurface surface) async {
    final deadline = DateTime.now().add(loadTimeout);
    while (DateTime.now().isBefore(deadline)) {
      // 加载已经失败了就别再等满超时。
      //
      // 失败的主框架导航**照样会把 `document.readyState` 走成 `complete`**
      // （浏览器渲染的是它自己的错误页），所以光看 readyState 看不出失败，
      // 只能靠 delegate 那个回调。不看这一句的话，一个打不开的域名会让
      // 用户干等 15 秒才看到"打不开这个页面"——而他第一秒就该知道。
      if (surface.lastLoadError != null) return;

      try {
        // 🩸 **必须 unwrap**。安卓把 JS 的字符串按 JSON 编码回传，`complete`
        // 到手是 `"complete"`（带引号）。不剥的话这个比较永远为假，循环一直
        // 转到超时——症状是"页面好像永远加载不完"，而页面早就好了。
        final state = unwrapJsString(await surface.evaluate(browserReadyStateJs));
        if (state == 'complete') break;
      } catch (_) {
        // 页面正在换，这时候跑 JS 可能失败——继续等就是
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await _settle();
  }

  // ────────────────────────────────────────────────────────────────
  // 收摊
  // ────────────────────────────────────────────────────────────────

  /// 不用杀进程、不用删 profile：这个 WebView 是 App 自己的，跟着页面一起走。
  /// 要做的只是把状态收掉，让之后每一次调用**立刻失败**而不是 hang。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    _hostMounted = false;
    _surface = null;
  }
}
