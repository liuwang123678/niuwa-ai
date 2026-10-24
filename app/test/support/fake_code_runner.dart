import 'package:niuwa_ai/core/n1_core.dart';

/// 假的代码执行器：**记录收到了什么**，按剧本回什么。
///
/// 存在的理由跟 `FakeBrowserDriver` 一样：真正要验的是"工具把参数原样传下去了
/// 没有""驱动说不可用时工具是失败还是抛异常"这类接线问题，这些拿真进程验
/// 会又慢又吵（真跑一次 `python` 要几十毫秒，还要看这台机器装了什么）。
///
/// **真的起进程那条路另有其人**：`test/services/process_code_runner_test.dart`
/// 用的是真 `Process`，因为那一层的验证点（超时杀没杀干净、管子堵没堵住）
/// 用假的只会验出"我写的假实现按我写的调用了"。
class FakeCodeRunner extends CodeRunner {
  FakeCodeRunner({
    this.available = true,
    this.commandSupported = true,
    this.unavailableReason,
    this.scriptHasFileSystem = true,
    this.scriptEnvironmentNote,
    Set<CodeLanguage>? languages,
    this.result,
    this.failWith,
  }) : supportedLanguages = languages ?? const {CodeLanguage.python};

  /// 可以中途改——模拟"预热刚结束"。
  bool available;
  bool commandSupported;

  @override
  String? unavailableReason;

  /// 手机那一路（JS）是 false，桌面默认 true。工具描述和 schema 都跟着它变。
  @override
  final bool scriptHasFileSystem;

  @override
  final String? scriptEnvironmentNote;

  @override
  final Set<CodeLanguage> supportedLanguages;

  /// 非 null 时每个方法都抛它。用来测"执行器活着但这一次跑挂了"。
  /// 可变，测试里可以跑几条正常的再把闸门关上。
  CodeException? failWith;

  /// 回什么结果。默认一个干净的 0。
  CodeResult? result;

  // ── 收到的调用 ──────────────────────────────────────────────
  final List<CommandRequest> commandRequests = [];
  final List<CodeRequest> codeRequests = [];
  int warmUpCount = 0;
  int disposeCount = 0;

  @override
  bool get isAvailable => available;

  @override
  bool get supportsCommand => commandSupported;

  @override
  Future<void> warmUp() async {
    warmUpCount++;
  }

  @override
  Future<CodeResult> runCommand(CommandRequest request) async {
    _guard();
    commandRequests.add(request);
    return result ?? const CodeResult(exitCode: 0, stdout: 'ok');
  }

  @override
  Future<CodeResult> run(CodeRequest request) async {
    _guard();
    codeRequests.add(request);
    return result ?? const CodeResult(exitCode: 0, stdout: 'ok');
  }

  void _guard() {
    final boom = failWith;
    if (boom != null) throw boom;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}
