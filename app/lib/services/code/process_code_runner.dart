import 'dart:async';
import 'dart:convert';
import 'dart:io';
// `BytesBuilder` 直接来自这里。不显式写这一行也能编译，但会报
// `deprecated_export_use`——`dart:io` 那个间接导出已经被弃用了。
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/code/code_runner.dart';

/// 起进程的可注入口子。默认就是 [Process.start]。
///
/// 抽出来不是为了"将来换实现"，是为了让测试能验"超时之后到底有没有杀进程"——
/// 那个行为在真实的 `Process` 上只能靠"跑个慢命令然后看它多久回来"来间接观察。
/// **参数不给默认值**：函数类型里写 `bool runInShell = false` 直接编译不过
/// （`default_value_in_function_type`），默认值只能落在实现那一侧的形参上。
typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool runInShell,
    });

/// 探一个候选解释器能不能用。
typedef InterpreterProbe =
    Future<bool> Function(List<String> candidate, {required Duration timeout});

/// 桌面上的代码执行器：**真的起子进程**。
///
/// ## 进程处理是这里唯一容易出事的地方
///
/// `Process.run(...).timeout()` **不杀子进程**。`while True: pass` 那种脚本，
/// 超时之后 Dart 这边以为结束了，那个 python 进程还活着，一次留一个——
/// 跑一下午能攒出一屏孤儿进程和满 CPU。所以必须 `Process.start` 拿到 pid，
/// 超时后 `taskkill /F /T`（Windows）或 `kill`（POSIX）**连子树一起**收掉。
/// `cdp_browser_driver.dart` 已经踩过这个坑，实现照抄。
///
/// ## 输出是流式读的，而且超了也得接着读
///
/// 两个坑叠在一起：
///
///   1. `Process.run` 会把全部输出**缓冲进内存**——`while True: print(i)`
///      两秒钟就能把内存吃光。所以流式读 + 按字节截断。
///   2. **截断之后不能停止读取。** 管子（pipe）的缓冲区满了以后子进程会
///      阻塞在 write 上，我们这边不读、它永远不退出 → 看起来就是"卡死了"，
///      而且 `taskkill` 之前那个进程一直挂着。所以超上限之后**继续排空，
///      只是不往内存里存**。
class ProcessCodeRunner extends CodeRunner {
  ProcessCodeRunner({
    Future<String?> Function()? homeDirectory,
    Future<Directory> Function()? tempDirectory,
    InterpreterProbe? probe,
    ProcessStarter? startProcess,
    this.defaultTimeout = const Duration(seconds: 60),
    this.maxTimeout = const Duration(seconds: 120),
    this.maxOutputBytes = 64 * 1024,
    this.keepScriptFiles = 200,
    bool? isWindows,
    void Function(String message)? logger,
  }) : _homeDirectory = homeDirectory ?? _defaultHomeDirectory,
       _tempDirectory = tempDirectory ?? _defaultTempDirectory,
       _probe = probe ?? _defaultProbe,
       _startProcess = startProcess ?? Process.start,
       _isWindows = isWindows ?? Platform.isWindows,
       _log = logger ?? _defaultLog;

  /// 单个请求的默认超时。可以按请求覆盖，但天花板是 [maxTimeout]。
  final Duration defaultTimeout;

  /// 硬上限。**用户手动点"停"和这个是一条线**：一条命令挂 10 分钟，
  /// 用户会以为 App 死了。
  ///
  /// ⚠️ **它必须小于工具层那个超时**（`N1Runtime.codeToolTimeout`，150 秒）。
  /// 反过来的话，注册表先超时把工具挂掉，而这边真正的看门狗还没到点——
  /// 进程继续跑，**模型收到的是注册表那句干巴巴的"超时"，不是这边
  /// 「超时了，进程已经被杀掉」**，用户也看不到到底发生了什么。
  /// 层与层之间要嵌起来，最里面那层负责把话说清楚。
  final Duration maxTimeout;

  /// stdout / stderr 各自最多留多少字节。超了标记"已截断"。
  final int maxOutputBytes;

  /// 临时脚本文件最多留几个（按修改时间，超出的删最老的）。
  final int keepScriptFiles;

  final Future<String?> Function() _homeDirectory;
  final Future<Directory> Function() _tempDirectory;
  final InterpreterProbe _probe;
  final ProcessStarter _startProcess;
  final bool _isWindows;
  final void Function(String message) _log;

  final Map<CodeLanguage, List<String>> _interpreters = {};
  bool _warmed = false;
  bool _disposed = false;

  /// Windows 上命令行工具的名字。
  static const String shellExecutable = 'cmd';

  @override
  bool get isAvailable => !_disposed && _interpreters.isNotEmpty;

  @override
  String? get unavailableReason {
    if (_disposed) return '代码执行器已经关掉了。';
    if (_interpreters.isEmpty) {
      return '这台电脑上没找到 Python 或 Node.js，所以跑不了代码。'
          '装一个就能用（Python 去 python.org，Node 去 nodejs.org），装完重启一下这个 App。';
    }
    return null;
  }

  @override
  Set<CodeLanguage> get supportedLanguages => _interpreters.keys.toSet();

  /// 桌面上跑不跑得了命令行。
  ///
  /// **跟 [isAvailable] 不是一回事**：这台机器可能没装 Python 和 Node，但
  /// `cmd` / `dir` / `ping` 一定有。所以它只看"执行器还在不在"，
  /// 不看解释器探测结果——探不到解释器不该让 `run_command` 也跟着消失。
  @override
  bool get supportsCommand => !_disposed;

  /// 探一遍本机真装了哪些解释器。幂等。
  ///
  /// ⚠️ 光看 `where python` 找不找得到**不够**：Windows 上 `python` 常常是
  /// 应用商店的跳转 stub，`where` 找得到它、执行起来没输出也没报错。用户会
  /// 看到"能跑 Python"然后每次跑都得到空结果。所以探的时候真跑一次 `--version`。
  @override
  Future<void> warmUp() async {
    if (_warmed || _disposed) return;
    _warmed = true;

    for (final entry in _candidates.entries) {
      for (final candidate in entry.value) {
        final ok = await _probe(candidate, timeout: const Duration(seconds: 8));
        if (ok) {
          _interpreters[entry.key] = candidate;
          _log('找到 ${entry.key.id}：${candidate.join(' ')}');
          break;
        }
      }
    }
  }

  /// 每个语言按优先级试的候选。`py -3` 是 Windows 官方启动器，
  /// 它比 PATH 里的 `python` 可靠得多（后者经常是那个商店 stub）。
  static const Map<CodeLanguage, List<List<String>>> _candidates = {
    CodeLanguage.python: [
      ['python'],
      ['py', '-3'],
      ['python3'],
    ],
    CodeLanguage.node: [
      ['node'],
      ['nodejs'],
    ],
  };

  @override
  Future<CodeResult> runCommand(CommandRequest request) async {
    _ensureUsable();
    final command = request.command.trim();
    if (command.isEmpty) {
      throw const CodeException('命令是空的，没东西可跑。');
    }

    final timeout = _clampTimeout(request.timeout);
    final cwd = await _resolveWorkingDirectory(request.workingDirectory);
    final started = DateTime.now();

    // Windows：把命令写成临时 `.cmd` 再交给 `cmd /c` 跑，**不**把整串命令当成
    // 可执行文件塞给 `runInShell: true`。
    //
    // 🩸 这是真机上撞出来的，不是想出来的。`runInShell: true` 走的是 Dart 的
    // 参数转义：它按 MSVCRT 那套把 `"` 转成 `\"`，而 **cmd.exe 不认反斜杠转义**
    // ——反斜杠原样传下去，引号也就原样带着反斜杠到了子进程手里。症状是
    // **任何带引号的命令都坏**：
    //   `python "C:\Program Files\a.py"`
    //     → python: can't open file '…\"C:\Program Files\a.py"'
    // 也就是"路径里有空格"这一类全跑不了，而那恰恰是最需要引号的场合。
    // 自己拼 `cmd /c`、改用 `%COMSPEC%` 两条绕法实测掉进同一个坑——转义发生在
    // Dart 这一层，跟怎么拼外壳无关。
    //
    // 落成 .cmd 之后转义层整个消失：文件里是命令**原文**，cmd 按自己的规矩解析。
    // 唯一要管的是文件编码，见 [_writeCommandScript]。
    if (_isWindows) {
      final script = await _writeCommandScript(command);
      return _spawn(
        'cmd',
        ['/c', script.path],
        workingDirectory: cwd,
        timeout: timeout,
        // 同一套 UTF-8 环境变量也带给命令行。对非 Python 的命令是三个没人看的
        // 变量，没有任何副作用；而 `python -c "print('中文')"` 这种写法能救回来。
        environment: _interpreterEnvironment(CodeLanguage.python),
        runInShell: false,
        started: started,
      );
    }

    // 非 Windows 保持原样：`sh -c` 那条路上 `\"` 正好就是 shell 的转义，
    // 语义是对的。而且这里验不了，**没验过的东西不动**。
    return _spawn(
      command,
      const [],
      workingDirectory: cwd,
      timeout: timeout,
      environment: _interpreterEnvironment(CodeLanguage.python),
      runInShell: true,
      started: started,
    );
  }

  @override
  Future<CodeResult> run(CodeRequest request) async {
    _ensureUsable();
    final interpreter = _interpreters[request.language];
    if (interpreter == null) {
      throw CodeException(
        '这台电脑上跑不了 ${request.language.label}。'
        '现在能用的是：${_interpreters.keys.map((l) => l.label).join('、')}'
        '${_interpreters.isEmpty ? '（一个都没有）' : ''}。',
      );
    }

    final source = request.source;
    if (source.trim().isEmpty) {
      throw const CodeException('源码是空的，没东西可跑。');
    }

    final timeout = _clampTimeout(request.timeout);
    final cwd = await _resolveWorkingDirectory(request.workingDirectory);
    final script = await _writeScript(request.language, source);

    final started = DateTime.now();
    final result = await _spawn(
      interpreter.first,
      [...interpreter.skip(1), script.path],
      workingDirectory: cwd,
      timeout: timeout,
      environment: _interpreterEnvironment(request.language),
      runInShell: false,
      started: started,
    );

    return CodeResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      duration: result.duration,
      timedOut: result.timedOut,
      truncated: result.truncated,
      looksGarbled: result.looksGarbled,
      // 留个出处：审计、以及让模型知道要改哪个文件。
      note: '脚本文件：`${script.path}`',
    );
  }

  // ─────────────────────────── 下面都是实现细节 ───────────────────────────

  void _ensureUsable() {
    if (_disposed) throw const CodeException('代码执行器已经关掉了。');
  }

  /// 夹住超时。**用户/模型给的数不能直接信**——它偶尔会写个 `timeout: 100000`，
  /// 那条命令就会在下一次重启之前一直挂着。
  Duration _clampTimeout(Duration requested) {
    if (requested <= Duration.zero) return defaultTimeout;
    return requested > maxTimeout ? maxTimeout : requested;
  }

  /// 工作目录。模型没指定就用家目录——跟用户在自己的终端里跑命令一个预期。
  ///
  /// **不用临时目录当默认**：脚本里一句 `open('out.txt','w')` 会写到一个
  /// 用户永远找不到的地方，然后他来问"我的文件呢"。
  Future<String> _resolveWorkingDirectory(String? requested) async {
    final wanted = requested?.trim();
    if (wanted != null && wanted.isNotEmpty) {
      final dir = Directory(wanted);
      if (!await dir.exists()) {
        throw CodeException('工作目录不存在：$wanted');
      }
      return wanted;
    }
    final home = await _homeDirectory();
    if (home != null && home.trim().isNotEmpty) return home;
    return Directory.systemTemp.path;
  }

  /// 子进程要带的环境变量。
  ///
  /// Python 那三个是**为了治中文乱码**，不是可有可无：中文 Windows 上
  /// Python 默认按 GBK 输出，我们按 UTF-8 解，中文全是 U+FFFD。
  /// `PYTHONUTF8=1` 让它全程用 UTF-8，`PYTHONIOENCODING` 是给老版本兜底，
  /// `PYTHONUNBUFFERED` 保证 print 立刻出来（不然超时被杀时一个字节都看不到）。
  Map<String, String> _interpreterEnvironment(CodeLanguage language) {
    if (language != CodeLanguage.python) return const {};
    return const {
      'PYTHONUTF8': '1',
      'PYTHONIOENCODING': 'utf-8',
      'PYTHONUNBUFFERED': '1',
    };
  }

  /// 源码落成临时文件。见 `CodeRequest.source` 的说明。
  Future<File> _writeScript(CodeLanguage language, String source) async {
    final dir = await _tempDirectory();
    await dir.create(recursive: true);

    final file = File(p.join(dir.path, _tempName(language.extension)));
    await file.writeAsString(source, flush: true);

    // **先写后清**。反过来（先清后写）留下的是 keep+1 个，清理上限就成了
    // "其实多留一个"——数字对不上很容易被当成没清干净。
    await _pruneScripts(dir);
    return file;
  }

  /// 把命令行写成一个临时 `.cmd`，返回它。
  ///
  /// 为什么绕这一圈，见 [runCommand] 里那段。这里只说文件本身的讲究。
  ///
  /// ## 为什么要带 `chcp 65001`
  ///
  /// `.cmd` 是**文本文件**，cmd.exe 按当前控制台代码页去读它。中文 Windows 上
  /// 那是 936（GBK），而这里写的是 UTF-8——不带这一行，命令里**任何中文都会被
  /// 读歪**：`python "D:\重要资料\a.py"` 会变成一串找不到的乱码路径。
  /// 三条编码路线都在真机上量过：
  ///
  /// | 写法 | 中文路径 | `echo 中文` | `@echo off` |
  /// |---|---|---|---|
  /// | 纯 UTF-8 | ✗ 打不开 | ✓（碰巧，echo 只转发字节） | ✓ |
  /// | UTF-8 + BOM | ✗ | ✓ | ✗ 连它都不认 |
  /// | UTF-8 + `chcp 65001` | ✓ | ✓ | ✓ |
  ///
  /// 顺带的好处：cmd **自己**的报错（"不是内部或外部命令"）、`dir` 的输出也跟着
  /// 变成 UTF-8，回来是看得懂的英文，不再是一片乱码。按 ANSI 代码页输出的第三方
  /// 工具仍然可能乱码——那部分没变，`looksGarbled` 那套判断照旧有用。
  Future<File> _writeCommandScript(String command) async {
    final dir = await _tempDirectory();
    await dir.create(recursive: true);

    final file = File(p.join(dir.path, _tempName('.cmd')));
    await file.writeAsString(
      '@echo off\r\n'
      'chcp 65001>nul\r\n'
      '$command\r\n',
      encoding: utf8,
      flush: true,
    );

    await _pruneScripts(dir);
    return file;
  }

  /// 临时文件名。
  ///
  /// 名字里带个随机尾巴：同一毫秒内两次提交（模型并行调两个工具）会撞名，
  /// 撞名就会互相覆盖，症状是"跑的东西和我写的不一样"。
  ///
  /// 前缀 `n1_` 是 [_pruneScripts] 认领自己人的标记，别改。
  String _tempName(String extension) {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 17);
    final salt = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'n1_${stamp}_$salt$extension';
  }

  /// 临时脚本攒着会越堆越多。按修改时间留最新的 [keepScriptFiles] 个。
  ///
  /// 失败**不抛**：清理失败不该让"跑代码"这件事跟着失败。
  Future<void> _pruneScripts(Directory dir) async {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('n1_'))
          .toList();
      if (files.length < keepScriptFiles) return;

      final stamped = <MapEntry<File, DateTime>>[];
      for (final f in files) {
        try {
          stamped.add(MapEntry(f, f.statSync().modified));
        } catch (_) {
          // 刚被别的实例删掉了，跳过。
        }
      }
      stamped.sort((a, b) => b.value.compareTo(a.value));
      for (final entry in stamped.skip(keepScriptFiles)) {
        try {
          entry.key.deleteSync();
        } catch (_) {}
      }
    } catch (e) {
      _log('清理临时脚本失败（不影响这次执行）：$e');
    }
  }

  /// 起进程、收输出、超时就杀。
  Future<CodeResult> _spawn(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required Map<String, String> environment,
    required bool runInShell,
    required DateTime started,
  }) async {
    final Process process;
    try {
      process = await _startProcess(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment.isEmpty ? null : environment,
        runInShell: runInShell,
      );
    } on ProcessException catch (e) {
      // 最常见的两种：命令名打错了（`pythn`），以及没装。
      throw CodeException('起不来：$executable —— ${e.message}');
    }

    final out = _OutputCollector(maxOutputBytes);
    final err = _OutputCollector(maxOutputBytes);
    out.attach(process.stdout);
    err.attach(process.stderr);

    final exited = Completer<int>();
    unawaited(
      process.exitCode.then((code) {
        if (!exited.isCompleted) exited.complete(code);
      }),
    );

    var timedOut = false;
    Timer? giveUp;
    final deadline = Timer(timeout, () {
      timedOut = true;
      unawaited(() async {
        await _killTree(process);
        // 兜底：杀了还不退（权限不够、进程卡在不可中断的系统调用里），
        // 也不能把工具挂死在这儿——挂死比报错难查得多。
        giveUp = Timer(const Duration(seconds: 5), () {
          if (!exited.isCompleted) exited.complete(-1);
        });
      }());
    });

    final exitCode = await exited.future;
    deadline.cancel();
    giveUp?.cancel();

    // 输出可能还压在管子里。给 5 秒收尾；收不上来就用已经拿到的那部分，
    // **不能一直等**——上面那个"杀不掉"的分支走到这儿就是等不到 EOF 的。
    await _settle(out, err);

    final stdout = out.text();
    final stderr = err.text();
    return CodeResult(
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
      duration: DateTime.now().difference(started),
      timedOut: timedOut,
      truncated: out.truncated || err.truncated,
      looksGarbled: looksGarbledText(stdout) || looksGarbledText(stderr),
    );
  }

  static Future<void> _settle(_OutputCollector a, _OutputCollector b) async {
    try {
      await Future.wait([
        a.done,
        b.done,
      ]).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // 拿已经拿到的。
    }
  }

  /// 杀进程**连子树一起**。
  ///
  /// 只杀父进程是不够的：`cmd /c python x.py` 里真正的干活的是 Python 那个
  /// 孙子进程，父进程死了它还活着。每次留一个，跑一天就是一堆孤儿 + 一个满载的 CPU。
  Future<void> _killTree(Process process) async {
    try {
      if (_isWindows) {
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
      // 已经自己退了就会报错，这不算问题；但留一条日志，真泄漏时能查。
      _log('杀进程时出岔子（多半是它已经退了）：$e');
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }

  // ────────────────────────── 默认实现 ──────────────────────────

  static Future<String?> _defaultHomeDirectory() async {
    final env = Platform.environment;
    for (final key in const ['USERPROFILE', 'HOME']) {
      final v = env[key];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static Future<Directory> _defaultTempDirectory() async => Directory(
    p.join(Directory.systemTemp.path, 'n1-code'),
  );

  /// 真跑一次 `--version`。见 [warmUp] 里那个"商店 stub"的说明。
  static Future<bool> _defaultProbe(
    List<String> candidate, {
    required Duration timeout,
  }) async {
    try {
      final result = await Process.run(
        candidate.first,
        [...candidate.skip(1), '--version'],
      ).timeout(timeout);
      if (result.exitCode != 0) return false;
      final text = '${result.stdout}${result.stderr}'.trim();
      return text.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static void _defaultLog(String message) => debugPrint('[code] $message');
}

/// 输出收集器：**按上限截断，但管子继续排空。**
///
/// 见 [ProcessCodeRunner] 的类注释第 2 条——停止读取会让子进程阻塞在 write 上，
/// 那是"跑到一半卡死"的真正成因，而且看起来完全不像输出太多引起的。
class _OutputCollector {
  _OutputCollector(this.cap);

  final int cap;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();

  int _length = 0;
  bool truncated = false;
  String? _text;

  Future<void> get done => _done.future;

  void attach(Stream<List<int>> stream) {
    stream.listen(
      _add,
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );
  }

  void _add(List<int> chunk) {
    final room = cap - _length;
    if (room <= 0) {
      // 满了：**不存，但这一条订阅还留着**，管子继续排空。
      truncated = true;
      return;
    }
    if (chunk.length <= room) {
      _bytes.add(chunk);
      _length += chunk.length;
    } else {
      _bytes.add(chunk.sublist(0, room));
      _length = cap;
      truncated = true;
    }
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  /// 解一次就缓存住——`BytesBuilder.takeBytes()` 会把里面掏空，
  /// 调第二次拿到的是空串（而且不报错，表现是"输出神秘消失"）。
  String text() => _text ??= utf8.decode(_bytes.takeBytes(), allowMalformed: true);
}

/// 输出里替换字符太多，就当解码失败（页面/输出多半是 GBK）。
///
/// 口径跟 `ToolContext._looksGarbled` 一致。那一个是私有的，改口径要两边一起改——
/// 之所以没抽成共用函数，是因为 `ToolContext` 在那之前就已经被测试钉住了，
/// 为一个六行的启发式去动它不划算。
bool looksGarbledText(String text) {
  if (text.isEmpty) return false;
  var bad = 0;
  for (final rune in text.runes) {
    if (rune == 0xFFFD) bad++;
  }
  return bad > 0 && bad / text.length > 0.02;
}
