import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/browser/browser_driver.dart';
import '../../core/browser/snapshot_script.dart';

/// 从 `/json/list` 的结果里挑出**我们自己那个页面**的调试地址。
///
/// **不能简单地取"第一个 `type == 'page'`"**。实测（2026-10-10，本机 Edge）：
/// 一个全新 profile 下 `/json/list` 里会有两个 page target——
///
/// ```
/// page | edge://sync-confirmation-dialog/
/// page | https://www.baidu.com/
/// ```
///
/// 同步对话框可能排在我们页面**前面**。挑错了的话 `open()` 会把那个对话框
/// 导航走，之后每次快照读的都是错的页面，而症状只是"读不到东西"——很难
/// 想到是 target 挑错了。所以按"这个是我们的页面吗"排序，不按列表顺序。
///
/// 优先级：我们启动时那个 `about:blank` → 第一个 http(s) 页面 → 剩下的随便。
/// 排在最后那一档是兜底：真到那一步，有页面总比没有强。
String? pickPageTarget(Object? decoded) {
  if (decoded is! List) return null;

  String? blank;
  String? http;
  String? other;

  for (final item in decoded) {
    if (item is! Map) continue;
    if (item['type'] != 'page') continue;
    final ws = item['webSocketDebuggerUrl'];
    if (ws == null) continue;
    final url = '${item['url']}';

    if (url == 'about:blank') {
      blank ??= '$ws';
    } else if (url.startsWith('http://') || url.startsWith('https://')) {
      http ??= '$ws';
    } else {
      // edge:// ./ chrome:// ./ chrome-extension:// ./ devtools:// 都落这儿
      other ??= '$ws';
    }
  }

  return blank ?? http ?? other;
}

/// Windows 上的浏览器驱动：**自己拉起一个干净的 Edge/Chrome，用 CDP 操纵它。**
///
/// ## 为什么不用用户正在用的那个浏览器
///
/// 复用要往用户已开的实例上开调试端口，而那需要**先把人家的浏览器全关掉**
/// （调试端口是启动参数，不能事后打开）。更别说那样会带着用户全部登录态，
/// 一个能自己点页面的 agent 拿着你的网银会话，风险不用细说。
///
/// 所以这条路是**临时 profile**：App 起一个自己的浏览器、用完杀掉、profile 删掉。
/// 代价写在明处——**需要登录的站点做不了**，技能文档里也这么告诉模型。
///
/// ## 进程处理是最容易出事的一段
///
/// `Process.start(msedge.exe)` 拿到的经常是个 **launcher stub**：它把活儿交给
/// 真正的 browser 进程然后自己退出。所以 `process.kill()` 杀不掉 renderer，
/// 每次操作都会留下一个孤儿浏览器和一个几十 MB 的临时 profile。必须
/// `taskkill /F /T`（连同子树）。
class CdpBrowserDriver extends BrowserDriver {
  CdpBrowserDriver({
    Future<String?> Function()? findExecutable,
    Future<Process> Function(String executable, List<String> arguments)?
    startProcess,
    Future<Directory> Function()? tempDirectory,
    this.settleDelay = const Duration(milliseconds: 250),
    this.loadTimeout = const Duration(seconds: 15),
    this.startTimeout = const Duration(seconds: 20),
    this.commandTimeout = const Duration(seconds: 20),
    void Function(String message)? logger,
  }) : _findExecutable = findExecutable ?? _defaultFindExecutable,
       _startProcess = startProcess ?? Process.start,
       _tempDirectory = tempDirectory ?? _defaultTempDirectory,
       _log = logger ?? ((m) => debugPrint('[browser] $m'));

  /// 找浏览器可执行文件。默认按注册表 → 常见安装路径 → PATH 的顺序找。
  final Future<String?> Function() _findExecutable;

  /// 起进程。抽出来是为了测试能塞一个假的。
  final Future<Process> Function(String executable, List<String> arguments)
  _startProcess;

  final Future<Directory> Function() _tempDirectory;
  final void Function(String message) _log;

  /// 点完/填完之后等一小会儿——页面上的 JS 渲染、下拉建议、表单校验
  /// 都是"点完立刻"发生的，不缓一下拍到的是中间态。
  final Duration settleDelay;

  /// 等页面加载完的上限。
  final Duration loadTimeout;

  /// 等浏览器把调试端口开出来的上限。冷启动真的慢，别设得太紧。
  final Duration startTimeout;

  /// 单条 CDP 命令的上限。**存在的意义是"绝不 hang"**：用户手动关掉窗口时，
  /// 有些实现下命令不会报错，就那么挂着。宁可超时报错，也不能卡住整轮对话。
  final Duration commandTimeout;

  bool _ready = false;
  String? _reason;

  CdpConnection? _cdp;
  Process? _process;
  Directory? _profile;

  Future<void>? _warming;
  bool _disposed = false;

  @override
  bool get isAvailable => _ready && !_disposed;

  /// Windows 上浏览器能力一直在，只是没预热。工具层据此先注册、用时再拉。
  @override
  bool get supportsWarmUp => true;

  @override
  String? get unavailableReason => isAvailable ? null : (_reason ?? '浏览器现在用不了。');

  // ────────────────────────────────────────────────────────────────
  // 预热
  // ────────────────────────────────────────────────────────────────

  /// 幂等：重复调只会等第一次那个 future，不会拉起第二个浏览器。
  ///
  /// **绝不抛异常**——boot 阶段是 `unawaited` 调的，让异常逃出去就成了
  /// unhandled async error，直接打崩 zone。
  @override
  Future<void> warmUp() => _warming ??= _doWarmUp();

  Future<void> _doWarmUp() async {
    if (_disposed) return;
    try {
      final exe = await _findExecutable();
      if (exe == null) {
        _fail('这台机器上没找到 Edge 或 Chrome，浏览器功能用不了。');
        return;
      }

      final root = await _tempDirectory();
      final profile = Directory(
        p.join(root.path, 'niuwa-browser-${DateTime.now().millisecondsSinceEpoch}'),
      );
      await profile.create(recursive: true);
      _profile = profile;

      _log('拉起浏览器：$exe（profile: ${profile.path}）');
      _process = await _startProcess(exe, [
        // 端口写 0 让系统分配，真正的端口从 profile 里的 DevToolsActivePort 读。
        // 写死一个端口的话，撞上占用就整个起不来，而且报错很难懂。
        '--remote-debugging-port=0',
        // ⚠️ **独立的 user-data-dir 是硬要求，不是讲究。**
        // 不加的话，已经在跑的 Edge 会接手这些参数，然后这个新进程直接退出：
        // 调试端口永远不开，而你会去怀疑代码写错了。
        '--user-data-dir=${profile.path}',
        '--no-first-run',
        '--no-default-browser-check',
        // 全新 profile 下 Edge 会自己开一个 `edge://sync-confirmation-dialog/`
        // 页面去问要不要同步——我们是个用完就删的干净实例，没有可同步的东西，
        // 而那个页面会在 /json/list 里多出一个 page target。
        '--disable-sync',
        // 崩溃恢复气泡会盖在页面上、还会抢焦点
        '--hide-crash-restore-bubble',
        '--disable-session-crashed-bubble',
        '--window-size=1280,900',
        // **刻意不用 --headless**：这是个陪伴型 App，让用户看得见它在干活，
        // 比省那点内存重要。已知代价是窗口被最小化时截图可能全黑。
        'about:blank',
      ]);

      // launcher 退出得很快，先听一下：立刻挂了就不用白等 20 秒。
      unawaited(
        _process!.exitCode.then((code) {
          if (!_ready && !_disposed) {
            _log('浏览器进程提前退出了（退出码 $code）');
          }
        }),
      );

      final port = await _waitForDebugPort(profile);
      final wsUrl = await _pageWebSocketUrl(port);

      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      await channel.ready.timeout(startTimeout);
      final cdp = CdpConnection(
        incoming: channel.stream,
        outgoing: channel.sink,
        commandTimeout: commandTimeout,
        onClosed: (reason) {
          // 用户手动把窗口关了就走这儿。清掉可用状态，之后每次调用**立刻失败**
          // 并说明原因——不能 hang，也不能让模型以为还能接着用。
          _ready = false;
          _reason = reason;
          _log(reason);
        },
      );
      _cdp = cdp;
      // **忘了这一句的话，所有命令都会卡到超时**：没人去听回复，
      // Completer 永远不完成。症状是"浏览器起来了但每个操作都超时"。
      cdp.start();

      // 先把域打开，后面的命令才有事件和运行时环境。
      await cdp.send('Page.enable');
      await cdp.send('Runtime.enable');

      _ready = true;
      _reason = null;
      _log('浏览器就绪（端口 $port）');
    } catch (e) {
      _fail('浏览器起不来：$e');
      // 起了一半就失败的话，进程和临时目录都得收掉，否则一次失败泄漏一份。
      await _teardown();
    }
  }

  void _fail(String reason) {
    _ready = false;
    _reason = reason;
    _log(reason);
  }

  /// 轮询 `DevToolsActivePort` 拿真实端口。
  ///
  /// **这个文件是浏览器初始化之后才写的**（内容两行：端口、ws 路径），
  /// 所以必须轮询带超时——读一次就放弃的话，冷启动永远拿不到。
  Future<int> _waitForDebugPort(Directory profile) async {
    final file = File(p.join(profile.path, 'DevToolsActivePort'));
    final deadline = DateTime.now().add(startTimeout);

    while (DateTime.now().isBefore(deadline)) {
      if (await file.exists()) {
        try {
          final text = await file.readAsString();
          final first = text.split('\n').first.trim();
          final port = int.tryParse(first);
          if (port != null && port > 0) return port;
        } catch (_) {
          // 文件刚建出来、还没写完，下一轮再读
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw BrowserException(
      '浏览器起来了，但调试端口 ${startTimeout.inSeconds} 秒都没打开。',
    );
  }

  /// 从 `/json/list` 里挑一个 page target 的调试地址。
  Future<String> _pageWebSocketUrl(int port) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/json/list'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      final decoded = jsonDecode(body);
      if (decoded is! List) throw BrowserException('/json/list 返回的不是列表。');

      final url = pickPageTarget(decoded);
      if (url == null) throw BrowserException('浏览器里一个页面都没有。');
      return url;
    } on SocketException catch (e) {
      throw BrowserException('连不上浏览器的调试端口（$e）。');
    } finally {
      client.close(force: true);
    }
  }

  // ────────────────────────────────────────────────────────────────
  // 操作
  // ────────────────────────────────────────────────────────────────

  void _ensureReady() {
    if (_disposed) throw const BrowserException('浏览器已经关掉了。');
    if (_ready && _cdp != null) return;
    throw BrowserException(_reason ?? '浏览器现在用不了。');
  }

  @override
  Future<void> open(String url) async {
    _ensureReady();
    final result = await _cdp!.send('Page.navigate', {'url': url});

    // 导航本身失败（域名解析不了、证书不对）时 CDP 是**成功返回**的，
    // 错误藏在 errorText 里。不看它的话，模型会收到一个空白页快照，
    // 然后开始怀疑自己的选择器写错了。
    final error = result['errorText'];
    if (error is String && error.isNotEmpty) {
      throw BrowserException('打不开这个网址：$error');
    }
    await _waitForLoad();
  }

  @override
  Future<BrowserSnapshot> snapshot() async {
    _ensureReady();
    final raw = await _cdp!.evaluate(browserSnapshotJs);
    return BrowserSnapshot.fromScriptResult(raw == null ? '' : '$raw');
  }

  @override
  Future<void> click(String ref) async {
    _ensureReady();
    await _runScript(browserClickJs(parseBrowserRef(ref)));
    await _settle();
  }

  @override
  Future<void> type(String ref, String text) async {
    _ensureReady();
    await _runScript(browserTypeJs(parseBrowserRef(ref), text));
    await _settle();
  }

  @override
  Future<void> scroll(ScrollDirection direction, {double amount = 0.8}) async {
    _ensureReady();
    await _runScript(browserScrollJs(direction, amount));
    await _settle();
  }

  @override
  Future<Uint8List> screenshot() async {
    _ensureReady();
    final result = await _cdp!.send('Page.captureScreenshot', {'format': 'png'});
    final data = result['data'];
    if (data is! String || data.isEmpty) {
      throw const BrowserException(
        '截图没截到内容。如果浏览器窗口被最小化了，先把它还原再试。',
      );
    }
    return base64Decode(data);
  }

  @override
  Future<void> back() async {
    _ensureReady();
    // 用 history.back() 而不是 Page.navigateToHistoryEntry：后者要先
    // Page.getNavigationHistory 拿 entryId，多一次往返，而且 SPA 里
    // 那两个概念经常对不上。
    await _cdp!.evaluate('history.back()');
    await _waitForLoad();
  }

  /// 跑一个"返回 {status: ...}"的小脚本，把 status 翻成人话。
  ///
  /// 协议判定在 core 里（[ensureBrowserScriptOk]），安卓那边调的是同一个——
  /// 各写一份的话，改了一边另一边不会有人发现。
  Future<void> _runScript(String js) async {
    final raw = await _cdp!.evaluate(js);
    ensureBrowserScriptOk(raw == null ? '' : '$raw');
  }

  Future<void> _settle() => Future<void>.delayed(settleDelay);

  /// 等页面加载完，再加一小段静默期。
  ///
  /// 不等的话会拍到半成品：`Page.navigate` 一返回就去读 DOM，读到的往往是
  /// 还没跑 JS 的空壳。这是"截图和快照是空的"最常见的直接原因。
  Future<void> _waitForLoad() async {
    final deadline = DateTime.now().add(loadTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final state = await _cdp!.evaluate(browserReadyStateJs);
        if ('$state' == 'complete') break;
      } catch (_) {
        // 页面正在换，这时候 evaluate 可能失败——继续等就是
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await _settle();
  }

  // ────────────────────────────────────────────────────────────────
  // 收摊
  // ────────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    await _teardown();
  }

  Future<void> _teardown() async {
    final cdp = _cdp;
    _cdp = null;
    if (cdp != null) {
      try {
        await cdp.close();
      } catch (_) {}
    }
    await _killProcess();
    await _deleteProfile();
  }

  /// 杀进程**连子树一起**。
  ///
  /// `msedge.exe` 起的那个进程经常只是个 launcher：真正干活的是它的子进程，
  /// 只杀父进程的话 renderer 还活着，窗口还开着，临时 profile 还占着。
  /// 每次留一份，用久了就是一堆孤儿 + 一堆几百 MB 的临时目录。
  Future<void> _killProcess() async {
    final process = _process;
    _process = null;
    if (process == null) return;

    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', [
          '/F',
          '/T',
          '/PID',
          '${process.pid}',
        ]).timeout(const Duration(seconds: 10));
      } else {
        process.kill(ProcessSignal.sigkill);
      }
    } catch (e) {
      // 已经退出了就会报错，这不算问题；但留一条日志，真泄漏时能查。
      _log('杀浏览器进程时出岔子（多半是它已经退了）：$e');
    }
  }

  /// 删临时 profile。**要重试**：进程刚被杀掉时它可能还占着文件句柄，
  /// 立马删会失败，而那正是"临时目录越堆越多"的来源。
  Future<void> _deleteProfile() async {
    final profile = _profile;
    _profile = null;
    if (profile == null) return;

    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        if (!await profile.exists()) return;
        await profile.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    _log('临时目录删不掉，留在这儿了：${profile.path}');
  }
}

/// CDP 连接：发命令、收回复，把事件丢掉。
///
/// **刻意按 `Stream` / `StreamSink` 收口，而不是直接吃一个 `WebSocketChannel`**：
/// 这样测试能拿两个 `StreamController` 把它整个驱动起来，不用为此引入
/// `stream_channel` 依赖，也不用起真的 WebSocket。
class CdpConnection {
  CdpConnection({
    required this.incoming,
    required this.outgoing,
    this.commandTimeout = const Duration(seconds: 20),
    this._onClosed,
  });


  final Stream<dynamic> incoming;
  final StreamSink<dynamic> outgoing;
  final Duration commandTimeout;
  final void Function(String reason)? _onClosed;

  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  StreamSubscription<dynamic>? _subscription;
  int _nextId = 0;
  bool _closed = false;
  String? _closedReason;

  /// 开始听。构造完必须调一次。
  void start() {
    _subscription = incoming.listen(
      _onData,
      onError: (Object error) => _die('浏览器连接出错了：$error'),
      onDone: () => _die('浏览器被关掉了。'),
      cancelOnError: true,
    );
  }

  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?>? params,
  ]) {
    if (_closed) {
      throw BrowserException(_closedReason ?? '浏览器连接已经断开了。');
    }

    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;

    outgoing.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': ?params,
      }),
    );

    return completer.future.timeout(
      commandTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw BrowserException(
          '浏览器 ${commandTimeout.inSeconds} 秒没回话（$method），可能卡住了。',
        );
      },
    );
  }

  /// 跑一段 JS，返回值直接拿回来（`returnByValue`）。
  Future<Object?> evaluate(String expression) async {
    final result = await send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      // 页面里的脚本不需要用户手势——但**不需要不等于能给**：给了的话
      // 某些站点会弹出「允许自动播放」之类的横幅，挡在内容上面。
      'userGesture': false,
    });

    final exception = result['exceptionDetails'];
    if (exception != null) {
      throw BrowserException(
        '页面上的脚本出错了：${_describeException(exception)}',
      );
    }

    final value = result['result'];
    if (value is! Map) return null;
    if (value['subtype'] == 'null') return null;
    return value['value'];
  }

  void _onData(dynamic raw) {
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw, allowMalformed: true);
    } else {
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return; // 不是 JSON 的东西（心跳之类）直接忽略
    }
    if (decoded is! Map) return;

    final id = decoded['id'];
    // 没有 id 的是事件。我们一个事件都没订阅，忽略就对了。
    if (id is! int) return;

    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;

    final error = decoded['error'];
    if (error != null) {
      final message = error is Map ? error['message'] : error;
      completer.completeError(
        BrowserException('浏览器拒绝了这次操作：$message'),
      );
      return;
    }

    final result = decoded['result'];
    completer.complete(
      result is Map ? result.cast<String, Object?>() : <String, Object?>{},
    );
  }

  void _die(String reason) {
    if (_closed) return;
    _closed = true;
    _closedReason = reason;
    _drainPending(reason);
    _onClosed?.call(reason);
  }

  void _drainPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(BrowserException(reason));
      }
    }
    _pending.clear();
  }

  Future<void> close() async {
    _closed = true;
    _closedReason = '浏览器连接已经关掉了。';
    _drainPending(_closedReason!);
    await _subscription?.cancel();
    _subscription = null;
    try {
      await outgoing.close();
    } catch (_) {}
  }
}

/// 把 CDP 的 `exceptionDetails` 拼成一句能看懂的话。
///
/// **不能只用 `text`。** 单个字段的话，脚本抛异常时拿到的往往只有 "Uncaught"
/// 一个词——真正的错误（哪一行、什么错）在 `exception.description` 里。
/// 我第一次跑真机就是被这个坑住的：报错说"Uncaught"，等于什么都没说。
String _describeException(Object? exception) {
  if (exception is! Map) return '$exception';

  final parts = <String>[];

  final detail = exception['exception'];
  if (detail is Map) {
    final description = detail['description'] ?? detail['value'];
    if (description != null && '$description'.trim().isNotEmpty) {
      parts.add('$description');
    }
  }

  if (parts.isEmpty && exception['text'] != null) {
    parts.add('${exception['text']}');
  }

  final line = exception['lineNumber'];
  if (line is int) {
    final column = exception['columnNumber'];
    parts.add(
      '（第 ${line + 1} 行'
      '${column is int ? ' 第 ${column + 1} 列' : ''}）',
    );
  }

  return parts.isEmpty ? '$exception' : parts.join(' ');
}

/// 放临时 profile 的目录。
///
/// 优先用 `path_provider` 给的临时目录；它要过插件通道，在**纯测试环境里
/// 没有实现会直接抛**，所以退回 `Directory.systemTemp`。临时目录本来就是
/// 临时目录，退这一步不影响任何语义，却让整个驱动能在单测里真跑起来。
Future<Directory> _defaultTempDirectory() async {
  try {
    return await getTemporaryDirectory();
  } catch (_) {
    return Directory.systemTemp;
  }
}

/// 默认的浏览器查找：注册表 → 常见安装路径 → PATH。
///
/// 顺序是有讲究的：注册表的 `App Paths` 是**用户实际装了哪个**的权威答案，
/// 用户把 Edge 装到 D 盘时只有这里查得到。常见路径是兜底（注册表被改坏、
/// 或者绿色版），PATH 放最后（企业环境里 PATH 上的 `msedge` 可能是包装脚本）。
Future<String?> _defaultFindExecutable() async {
  for (final key in const [
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
    r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
  ]) {
    final found = await _readRegistryAppPath(key);
    if (found != null) return found;
  }

  final candidates = <String>[
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ];

  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData != null) {
    candidates.add(p.join(localAppData, 'Microsoft', 'Edge', 'Application', 'msedge.exe'));
    candidates.add(p.join(localAppData, 'Google', 'Chrome', 'Application', 'chrome.exe'));
  }

  for (final path in candidates) {
    try {
      if (await File(path).exists()) return path;
    } catch (_) {}
  }

  for (final name in const ['msedge.exe', 'chrome.exe']) {
    final found = await _which(name);
    if (found != null) return found;
  }
  return null;
}

Future<String?> _readRegistryAppPath(String key) async {
  try {
    final result = await Process.run('reg', [
      'query',
      key,
      '/ve',
    ]).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) return null;

    // 输出形如：`    (默认)    REG_SZ    C:\...\msedge.exe`
    for (final line in '${result.stdout}'.split('\n')) {
      final marker = line.indexOf('REG_SZ');
      if (marker < 0) continue;
      final value = line.substring(marker + 'REG_SZ'.length).trim();
      if (value.isEmpty) continue;
      if (await File(value).exists()) return value;
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<String?> _which(String executable) async {
  try {
    final result = await Process.run('where', [
      executable,
    ]).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) return null;
    for (final line in '${result.stdout}'.split('\n')) {
      final path = line.trim();
      if (path.isEmpty) continue;
      if (await File(path).exists()) return path;
    }
    return null;
  } catch (_) {
    return null;
  }
}
