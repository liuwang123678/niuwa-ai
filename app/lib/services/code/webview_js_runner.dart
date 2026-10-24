import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/browser_driver.dart' show unwrapJsString;
import '../../core/code/code_runner.dart';
import '../../core/code/js_script.dart';
import '../../core/util/clip.dart';
import '../browser/webview_surface.dart';

/// 安卓上的代码执行器：**借一个专用 WebView 跑 JavaScript**。
///
/// 手机上跑不了 Python 和 Node（没有解释器、也没有给 App 用的 shell），
/// 但每个安卓都带着一个完整的 JS 引擎。这条路给它用起来。
///
/// ## 跟浏览器那个 WebView 是**两个**，各管各的
///
/// 不共用 `BrowserHost` 里那个：那个上面挂着页面状态、登录 Cookie、
/// 用户正在看的东西；在这上面跑模型写的代码，等于让它跟用户共享一个环境——
/// 代码里一句 `document.body.innerHTML = ''` 就把用户正在看的页面毁了。
/// 所以这里自己造一个，从头到尾只有 `about:blank`，用完连页面一起没。
///
/// ## 🩸 最反直觉的一条：**不用挂进 widget 树**
///
/// 浏览器那边非挂不可——不 attach 就没有布局，`getClientRects()` 全空、
/// `window.innerHeight` 是 0，快照读到零个元素。
///
/// **求值不吃这一条。** `webview_flutter_android` 4.14.1 的
/// `AndroidWebViewController` 构造函数里就摸了 `_webView`，原生 WebView
/// **一构造就建好了**；`evaluateJavascript` 是纯粹的 JS 引擎调用，不要求 attach。
/// 所以这里没有 `_hostMounted` 这一项，`isAvailable` 只看"建好了、预热过了"。
///
/// ⚠️ 但这是**源码证据，不是真机证据**。真机验收里专门有一条：
/// 不挂树、不开页面，直接 `runJavaScriptReturningResult('1+1')` 看回不回来。
/// 那条不过，整条路都得换成挂一个屏幕外的 `WebViewWidget`（照 `BrowserHost` 抄）。
///
/// ## 🩸 第二条：JS 死循环没法中断
///
/// `while (true) {}` 会把那个渲染线程焊死，而我们**没有任何手段叫停它**——
/// WebView 没给中断接口，`evaluateJavascript` 回不来就是回不来。
/// 唯一的出路是把**整个 WebView 丢掉**换一个新的。所以超时之后这个执行器会
/// 进"中毒"状态：下一个请求先重开一个干净的，再干活。
///
/// ⚠️ 丢掉引用只是 Dart 这边不再用它；**那个卡住的引擎会不会真的停下来，
/// 我不知道**（真机验收要看：跑一次死循环之后手机是不是一直在发烫/掉电）。
/// 所以这里还尽力去 `navigate` 一下空白页——浏览器进程通常能借导航把渲染进程
/// 掀掉，但**这一条同样没验过**。
class WebViewJsRunner extends CodeRunner {
  WebViewJsRunner({
    WebViewSurface Function()? createSurface,
    this.defaultTimeout = const Duration(seconds: 30),
    this.maxTimeout = const Duration(seconds: 120),
    this.startupTimeout = const Duration(seconds: 10),
    this.maxOutputChars = 64 * 1024,
    void Function(String message)? logger,
  }) : _createSurface = createSurface ?? PlatformWebViewSurface.new,
       _log = logger ?? ((m) => debugPrint('[js] $m'));

  final WebViewSurface Function() _createSurface;
  final void Function(String message) _log;

  /// 单个请求的默认超时。可以按请求覆盖，但天花板是 [maxTimeout]。
  ///
  /// 比桌面短：JS 这条路是冲着"算个数、转个格式"去的，30 秒还没完
  /// 多半是死循环。用户看着一个不动的界面等一分钟，还不如早点告诉他。
  final Duration defaultTimeout;

  /// 硬上限。⚠️ **必须小于工具层那个超时**（`N1Runtime.codeToolTimeout`，150 秒）：
  /// 反过来的话注册表先超时把工具挂掉，而这边真正的看门狗还没到点，
  /// 模型收到的就是注册表那句干巴巴的"超时"，而不是这边"卡住了、环境已丢掉"。
  final Duration maxTimeout;

  /// 建完 WebView 之后等多久才开始求值。
  final Duration startupTimeout;

  /// 回给模型的文本最多多少字。超了如实标注截断。
  final int maxOutputChars;

  WebViewSurface? _surface;
  Future<void>? _warming;
  bool _ready = false;
  bool _poisoned = false;
  bool _disposed = false;
  String? _reason;

  @override
  bool get isAvailable => _ready && !_disposed;

  @override
  String? get unavailableReason {
    if (_disposed) return '代码执行器已经关掉了。';
    if (_poisoned) {
      return '上一次跑的代码卡住了（多半是个死循环），刚才那个运行环境已经丢掉了，'
          '下一次调用会重开一个——现在这一句先别用。'
          '还有，**别再写死循环**，跑不完的代码这边没有任何办法中断。';
    }
    if (!_ready) {
      return _reason ??
          '手机上的 JS 运行环境还没准备好。过一下再试，或者这次先如实告诉用户做不到。';
    }
    return null;
  }

  /// 手机上只有 JavaScript。
  ///
  /// 返回 `JavaScript` 而不是空集合，是给 `RunCodeTool` 生成 schema 用的——
  /// 那个 enum 直接决定模型会去试哪门语言（见 `code_tools.dart` 里的说明）。
  @override
  Set<CodeLanguage> get supportedLanguages =>
      isAvailable ? const {CodeLanguage.javascript} : const {};

  /// 手机上不给 `run_command`：普通 App 没有 shell 可用。
  @override
  bool get supportsCommand => false;

  /// 手机上的 JS 摸不到文件系统。
  @override
  bool get scriptHasFileSystem => false;

  @override
  String? get scriptEnvironmentNote =>
      '它跑在手机自带浏览器的 JS 引擎里，有两件事和电脑上不一样：'
      '**摸不到文件系统**（要读写文件得用电脑版），'
      '**异步等不到结果**（Promise / async / await / 定时器都不行，'
      '只能同步算完直接给结果）。';

  // ────────────────────────────────────────────────────────────────
  // 预热
  // ────────────────────────────────────────────────────────────────

  /// 幂等，不抛。**空转和失败都不写日志刷屏**。
  ///
  /// ⚠️ 跟浏览器那边不一样：这里**不缓存完成后的 future**。
  /// 那边一个 WebView 用一辈子，缓存下来正好；这边超时一次就得换一个，
  /// 缓存了以后重建永远走不到，"中毒"状态会一直粘着。
  /// 缓存只用来**合并同时来的几个请求**，做完就放掉。
  @override
  Future<void> warmUp() {
    if (_disposed || (_ready && !_poisoned)) return Future<void>.value();
    return _warming ??= _doWarmUp();
  }

  Future<void> _doWarmUp() async {
    try {
      final surface = _createSurface();
      await surface.prepare();
      // 🩸 先导一次空白页。刚建出来的 WebView 手上一份文档都没有，
      // 那时候求值没有可执行的环境，`evaluateJavascript` 只会回一个 null——
      // 而它在 Dart 这边跟"用户代码返回了 null"长得一模一样。
      await surface.navigate(jsBlankPage);
      await _waitUntilEvaluable(surface);

      if (_disposed) return;
      _surface = surface;
      _ready = true;
      _poisoned = false;
      _reason = null;
      _log('手机上的 JS 运行环境就绪。');
    } catch (e) {
      // 单测里没有平台实现时就走这儿：`WebViewPlatform.instance` 是 null，
      // 造 controller 直接抛。这是**正常的退化**，不是 bug。
      _ready = false;
      _reason = '手机上的 JS 运行环境起不来：$e';
      _log(_reason!);
    } finally {
      _warming = null;
    }
  }

  /// 等到**能求值**为止。
  ///
  /// 探的脚本是 `document.readyState`，但我们要的其实不是"页面加载完了"——
  /// 是"这儿已经有个能跑 JS 的环境了"。所以拿到任何一个像样的回复就算数，
  /// 不非得等到 `complete`：`about:blank` 上那点东西，`loading` 的时候
  /// 也一样能跑 `new Function`。
  ///
  /// 等不到也不抛：宁可让第一次求值自己去失败（错误信息更具体），
  /// 也不要因为一句 readyState 读不到就把整个能力判死。
  Future<void> _waitUntilEvaluable(WebViewSurface surface) async {
    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final raw = await surface.evaluate(jsReadyStateScript);
        // `PlatformWebViewSurface.evaluate` 是 `'$result'`，所以 JS 回 null
        // 的时候我们会拿到一个**字面量字符串 `null`**，不是空串。
        // 不认这一条的话，头一次探测就会"成功"，因为 `'null'` 是非空的。
        final state = unwrapJsString(raw);
        if (state.isNotEmpty && state != 'null') return;
      } catch (_) {
        // 文档正在换，这会儿跑 JS 可能失败——继续等就是。
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _log('等了 ${startupTimeout.inSeconds} 秒也没探到能跑 JS 的环境，先按能的走。');
  }

  // ────────────────────────────────────────────────────────────────
  // 执行
  // ────────────────────────────────────────────────────────────────

  /// 手机上不给命令行。[`supportsCommand`] 是 false，正常情况下工具层
  /// 压根不会调到这里；真调到了就如实说。
  @override
  Future<CodeResult> runCommand(CommandRequest request) async {
    throw const CodeException('手机上跑不了命令行。要跑命令得在电脑上用。');
  }

  @override
  Future<CodeResult> run(CodeRequest request) async {
    if (_disposed) throw const CodeException('代码执行器已经关掉了。');
    if (request.language != CodeLanguage.javascript) {
      throw CodeException(
        '手机上跑不了 ${request.language.label}，只能跑 JavaScript。',
      );
    }

    final source = request.source;
    if (source.trim().isEmpty) {
      throw const CodeException('源码是空的，没东西可跑。');
    }

    // 上次卡死过就重开一个。放在这儿而不是超时那一瞬间：卡死之后模型未必
    // 还会再调这个工具，那就没必要白白多造一个 WebView 出来。
    if (!_ready) await warmUp();
    final surface = _requireSurface();

    final timeout = _clampTimeout(request.timeout);
    final script = jsRunScript(source);
    final started = DateTime.now();

    final pending = surface.evaluate(script);
    // 被超时抛弃的那个 future 上也要挂个空的错处理。不挂的话，它以后报错
    // 就成了 unhandled async error——而那时候这条消息早就返回了，没人知道
    // 是它，日志里只有一句没头没尾的话。
    unawaited(pending.then((_) {}, onError: (Object _) {}));

    String raw;
    try {
      raw = await pending.timeout(timeout);
    } on TimeoutException {
      _abandon(surface);
      final seconds = (timeout.inMilliseconds / 1000).toStringAsFixed(0);
      return CodeResult(
        exitCode: -1,
        duration: DateTime.now().difference(started),
        timedOut: true,
        stderr:
            '这段代码跑了 $seconds 秒还没停，多半是个死循环（`while (true)` 那种）。'
            '这个运行环境已经被丢掉了，下次调用会重开一个。'
            '**别再写死循环**——跑不完的代码这边没有任何办法中断。',
      );
    } catch (e) {
      throw CodeException('跑的时候出错了：$e');
    }

    return _toCodeResult(raw, started);
  }

  /// 把 JS 带回来的东西翻成一次正常/失败的结果。
  CodeResult _toCodeResult(String raw, DateTime started) {
    final duration = DateTime.now().difference(started);

    final outcome = JsRunOutcome.tryParse(raw);
    if (outcome == null) {
      // 到这儿说明连信封都没拆开。最常见的是引擎在跑的过程中没了
      // （内存炸了、渲染进程被系统回收），拿回来一个 null 或者半截。
      return CodeResult(
        exitCode: -1,
        duration: duration,
        stderr:
            '代码跑完了，但引擎没把结果带回来（拿到的是一段读不出来的东西）。'
            '多半是这段代码把 JS 引擎弄崩了。换个写法再试——**别原样重试**。',
      );
    }

    var truncated = false;
    String clip(String text) {
      if (text.length <= maxOutputChars) return text;
      truncated = true;
      return clipAtCodeUnit(text, maxOutputChars);
    }

    final out = StringBuffer();
    if (outcome.hasValue) out.writeln('返回值：${outcome.value}');
    for (final line in outcome.logs) {
      out.writeln(line);
    }
    if (outcome.logsCut) {
      out.writeln('（console 输出只收了前 ${outcome.logs.length} 条，后面的没记）');
    }

    return CodeResult(
      // 呼应 `CodeResult.ok`：退出码说的是"这件事办成了没有"。
      // 代码报错是正常的一轮（写→跑→看报错→改），不是工具坏了。
      exitCode: outcome.ok ? 0 : 1,
      stdout: clip(out.toString().trimRight()),
      stderr: clip(outcome.error ?? ''),
      duration: duration,
      truncated: truncated,
      note: outcome.ok
          ? null
          : '（JavaScript 这条路没有真的"退出码"：1 就是"代码自己报错了"，'
                '不是命令没跑起来。）',
    );
  }

  // ────────────────────────────────────────────────────────────────
  // 收摊
  // ────────────────────────────────────────────────────────────────

  /// 把卡死的那个环境丢掉，等下一次调用重开。见类注释里的说明。
  void _abandon(WebViewSurface surface) {
    _ready = false;
    _poisoned = true;
    _surface = null;
    _reason = null;
    _log('上一次求值超时，这个 WebView 丢掉，下次重开。');

    // 尽力而为：再导一次空白页。浏览器进程通常能借一次导航把卡住的那个
    // 渲染进程掀掉，但这条路**没验过**（真机验收里要看手机还烫不烫）。
    // 超时只给 2 秒，而且全部吞掉——它是善后，不是主流程；
    // 这里再抛一个异常出去只会盖掉真正有用的那句"你写了个死循环"。
    try {
      unawaited(
        surface
            .navigate(jsBlankPage)
            .timeout(const Duration(seconds: 2))
            .then((_) {}, onError: (Object _) {}),
      );
    } catch (_) {}
  }

  WebViewSurface _requireSurface() {
    if (_disposed) throw const CodeException('代码执行器已经关掉了。');
    final surface = _surface;
    if (surface == null || !_ready) {
      throw CodeException(unavailableReason ?? '手机上的 JS 运行环境现在用不了。');
    }
    return surface;
  }

  /// 夹住超时。模型偶尔会写个 `timeout_seconds: 100000`，那条请求就会在
  /// 下一次重启之前一直挂着。
  Duration _clampTimeout(Duration requested) {
    if (requested <= Duration.zero) return defaultTimeout;
    return requested > maxTimeout ? maxTimeout : requested;
  }

  /// 不用杀进程、不用删 profile：这个 WebView 是 App 自己的，跟着页面一起走。
  /// 要做的只是把状态收掉，让之后每一次调用**立刻失败**而不是挂在那儿。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    _poisoned = false;
    _surface = null;
  }
}
