/// 跑代码这件事的平台抽象。仿 [`BrowserDriver`]。
///
/// 两端各一个实现，接口和结果格式统一：
///   - Windows/桌面：`ProcessCodeRunner` —— 真的起子进程（Python / Node / 命令行）
///   - Android：`WebViewJsRunner` —— 借一个专用 WebView 跑 JavaScript
///
/// ⚠️ **这个文件必须待在内核里，而且不许 import 任何 `package:` 平台包。**
/// `test/core_is_pure_test.dart` 只 grep `package:flutter/`，你在这儿写
/// `package:webview_flutter` 它照样绿——**别指望那条测试替你守**。
/// 所以这里只有类型和纯逻辑，碰进程、碰 WebView 的东西全在 `lib/services/code/`。
library;

/// 能跑什么语言。
///
/// ⚠️ **两端不是同一套**，而这件事必须让模型看得见（见 `code_tools.dart` 里
/// 按平台生成枚举的那段）：安卓上跑不了 Python，但模型从 schema 里看到
/// `python` 就会去试，试完失败再试第二遍——这正是 `tool_registry.dart` 注释里
/// 说的"注册了再返回不支持，比不注册更坏"。
enum CodeLanguage {
  python('python', 'Python', '.py'),
  node('node', 'Node.js', '.js'),

  /// 只有安卓有。桌面上的 JS 就用 [node]（那才有文件系统之类的 API）。
  javascript('javascript', 'JavaScript', '.js');

  const CodeLanguage(this.id, this.label, this.extension);

  /// 给模型看的名字，也是 schema 枚举里的值。
  final String id;

  /// 界面上显示的名字。
  final String label;

  /// 落临时文件时用什么后缀。
  final String extension;

  static CodeLanguage? fromId(String id) {
    for (final l in values) {
      if (l.id == id) return l;
    }
    return null;
  }
}

/// 驱动里出的事。[message] 是**直接说给模型听的话**。
///
/// 跟 `BrowserException` 同一个道理：失败原因五花八门（解释器没装、目录不存在、
/// 脚本语法错），但模型需要的都是同一件事——一句人话。用这个类型当载体，
/// 工具层就能把 [message] 原样翻成一次工具失败，不会走到
/// `ToolRegistry.invoke` 那个 `'${e.runtimeType}: $e'` 的兜底分支上去。
class CodeException implements Exception {
  const CodeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 跑一条命令行。
class CommandRequest {
  const CommandRequest({
    required this.command,
    this.workingDirectory,
    this.timeout = const Duration(seconds: 60),
  });

  /// 原样的命令行。**不给它做任何改写**——弹窗上要给用户看的就是这个。
  final String command;

  final String? workingDirectory;
  final Duration timeout;
}

/// 跑一段脚本。
class CodeRequest {
  const CodeRequest({
    required this.language,
    required this.source,
    this.workingDirectory,
    this.timeout = const Duration(seconds: 60),
  });

  final CodeLanguage language;

  /// 源码。**落成临时文件再执行**，不走 `-c`：
  /// 一是躲开多层引号转义那摊烂事，二是留下可核对的东西。
  final String source;

  final String? workingDirectory;
  final Duration timeout;
}

/// 一次执行的结果。
///
/// [ok] 说的是**这件事办成了没有**，不是**被跑的代码对不对**。
/// 一个语法错的 Python 脚本返回 exitCode 1：命令跑完了、输出也拿到了，
/// 只是程序自己报错——那属于"写→跑→看报错→改"这个循环的正常一轮，
/// 不该被当成工具坏了。
class CodeResult {
  const CodeResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.duration = Duration.zero,
    this.timedOut = false,
    this.truncated = false,
    this.looksGarbled = false,
    this.note,
  });

  /// 进程退出码。-1 表示被我们杀掉了（超时）或者压根没拿到。
  final int exitCode;

  final String stdout;
  final String stderr;
  final Duration duration;

  /// 超时，进程树已经被杀。
  final bool timedOut;

  /// 输出太长，超出的部分丢掉了。**必须如实告诉模型**——
  /// 不说的话它会以为"输出就这么点"，然后基于残缺信息下结论。
  final bool truncated;

  /// 输出里替换字符太多，多半是 GBK。跟 `ToolContext._looksGarbled` 一个口径。
  final bool looksGarbled;

  /// 附注（比如"这个 WebView 被换掉了"）。进模型上下文。
  final String? note;

  /// 命令本身跑完了，而且是正常退出。
  bool get ok => !timedOut && exitCode == 0;

  /// 渲染成喂给模型的文本。
  ///
  /// **两端必须完全一致**（跟 `BrowserSnapshot.toModelText` 同一个理由）：
  /// 桌面走子进程、安卓走 WebView，格式不统一的话同一个技能在两端行为不一样。
  String toModelText() {
    final buffer = StringBuffer();

    final seconds = (duration.inMilliseconds / 1000).toStringAsFixed(1);
    buffer.writeln('用时：$seconds 秒');

    if (timedOut) {
      buffer.writeln('⏱ 超时了，进程已经被杀掉。');
    } else {
      buffer.writeln('退出码：$exitCode');
      if (exitCode != 0) {
        buffer.writeln('⚠️ 退出码不是 0，是程序自己报错了。看下面的错误输出。');
      }
    }

    final out = stdout.trimRight();
    final err = stderr.trimRight();

    if (out.isNotEmpty) {
      buffer.writeln('\n输出：');
      buffer.writeln(out);
    }
    if (err.isNotEmpty) {
      buffer.writeln('\n错误输出：');
      buffer.writeln(err);
    }
    if (out.isEmpty && err.isEmpty) {
      buffer.writeln('\n（它什么都没输出）');
    }

    if (truncated) {
      buffer.writeln('\n⚠️ 输出太长，上面只留了开头一段（后面的丢掉了）。'
          '要看全部就改成只输出你真正需要的部分。');
    }
    if (looksGarbled) {
      buffer.writeln('\n⚠️ 输出里有大量乱码：这个工具按系统代码页（中文 Windows 是 GBK）'
          '输出，这边按 UTF-8 解不了。**别拿乱码去分析**。'
          '要中文输出就用 run_code 跑脚本——那边给解释器设了 UTF-8，实测有效；'
          '命令行那一路 cmd 自己是 UTF-8 了（跑在带 `chcp 65001` 的临时脚本里，'
          '实测中文路径和中文输出都正常），但**按老代码页写字节的第三方工具**'
          '仍然会乱，这部分没法从外面救。');
    }

    final extra = note?.trim();
    if (extra != null && extra.isNotEmpty) {
      buffer.writeln('\n$extra');
    }

    return buffer.toString().trimRight();
  }
}

/// 跑代码的驱动。两端各一个实现。
abstract class CodeRunner {
  /// 显式 const 构造，**是为了让子类能写 `const XxxRunner()`**——
  /// 不写的话 Dart 给的是非 const 隐式构造，子类的 const 构造编译不过。
  const CodeRunner();

  /// 这个平台当前能不能用。false 时相关工具不会被注册。
  ///
  /// 必须是**同步**的：唯一决定它的是 [warmUp] 那次异步探测（解释器在哪儿、
  /// WebView 建好没有），而 `newSession` 是同步方法，没法在那儿 await。
  /// 驱动内部持一个标志，由 [warmUp] 写、这里读。
  bool get isAvailable;

  /// 不可用时的原因，直接说给模型听。可用时是 null。
  String? get unavailableReason => null;

  /// 这个平台**真的能跑**哪些语言。
  ///
  /// 不是"理论上支持"，是探测结果：桌面上要 `where python` 找得到、且
  /// `python --version` 真能跑起来才算数。⚠️ Windows 上 `python` 可能是个
  /// 应用商店的跳转 stub，`where` 找得到它、跑起来却没输出——所以探测必须
  /// 真跑一次，不能只看 `where`。
  Set<CodeLanguage> get supportedLanguages;

  /// 这个平台能不能跑命令行。安卓上不能（没有 shell），所以
  /// `run_command` 在那边压根不注册。
  bool get supportsCommand => false;

  /// 脚本能不能碰到文件系统。
  ///
  /// 桌面：能（脚本读写的就是用户电脑上的文件），所以 `working_directory`
  /// 那一栏有意义。安卓：不能（WebView 里的 JS 摸不到文件），那一栏就没意义。
  /// 工具层靠这个决定要不要把参数写进 schema——
  /// **一个永远不起作用的参数是 schema 在撒谎**，比少一个参数糟得多。
  bool get scriptHasFileSystem => true;

  /// 脚本跑在哪儿，一句话，直接拼进工具描述给模型看。
  ///
  /// 桌面返回 null：那边"跑在读电脑的文件系统里"是默认预期，不用特意说。
  /// 安卓必须说，因为**和电脑上不一样的地方太多**——不说的话模型会按电脑的
  /// 预期写代码（读文件、`await` 一个请求），然后拿到一堆看不懂的失败。
  String? get scriptEnvironmentNote => null;

  /// 异步就绪：探测解释器、建 WebView。完成后 [isAvailable] 才会变。
  ///
  /// **刻意是带默认实现的具体方法，不是抽象方法**：这样
  /// [UnavailableCodeRunner] 和测试里的假驱动一行都不用改。
  ///
  /// 幂等，不抛——预热失败只表现为 [isAvailable] 还是 false。
  Future<void> warmUp() async {}

  /// 跑一条命令行。
  Future<CodeResult> runCommand(CommandRequest request);

  /// 跑一段脚本。
  Future<CodeResult> run(CodeRequest request);

  Future<void> dispose();
}

/// 平台不支持时的空实现。
///
/// **不注册进工具表**才是常态（见 `codeTools`），这个类存在的意义是让
/// `N1Runtime` 手上永远有个非空对象可用，不用到处判 null。
///
/// **`extends` 不是 `implements`**：基类里 `warmUp` / `unavailableReason` /
/// `supportsCommand` 是带默认实现的具体成员，`implements` 会把它们当成
/// 待实现的接口成员，逼每个子类抄一遍空实现。
class UnavailableCodeRunner extends CodeRunner {
  const UnavailableCodeRunner(this.reason);

  final String reason;

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason => reason;

  @override
  Set<CodeLanguage> get supportedLanguages => const {};

  Never _fail() => throw CodeException(reason);

  @override
  Future<CodeResult> runCommand(CommandRequest request) async => _fail();

  @override
  Future<CodeResult> run(CodeRequest request) async => _fail();

  @override
  Future<void> dispose() async {}
}
