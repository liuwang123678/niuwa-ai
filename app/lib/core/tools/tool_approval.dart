/// 工具审批门。
///
/// ## 为什么要有这东西
///
/// `run_command` 这类工具能在用户电脑上**执行任意命令**。有些操作必须先让用户
/// 看一眼再决定，但"危不危险"**看参数才知道**——`python 算个数` 和 `del /s /q`
/// 走的是同一个工具，一个静态的 `bool` 表达不了这件事。
///
/// 所以形状是：**工具自己按参数回答**"这次要不要问"（[N1Tool.approvalReason]），
/// **判定和等待放在 [ToolRegistry.invoke] 里**，界面侧只提供"怎么问"
/// （[ToolApprover]）。
///
/// ## 为什么判定不在 AgentLoop
///
/// 在 `AgentLoop` 里拦的话，拒绝路径就得手工再拼一遍，而**拒绝必须照样产出
/// `ToolCallFinished` 和一条 tool 消息**，否则：
///
///   1. `ToolTrace.running` 的定义就是 `result == null`，界面上那个转圈会**永远转**；
///   2. assistant 带 `tool_calls` 却没有对应的 tool 结果 → 历史协议非法 →
///      **下一轮请求直接 400**（`AgentLoop.sanitizeHistory` 和它头部的注释都在防这个）。
///
/// 放进 `ToolRegistry.invoke`，拒绝就自动变成一次普通的 [ToolResult.fail]，
/// 上面两个问题都不存在。
library;

/// 一次审批要问什么。
class ToolApprovalRequest {
  const ToolApprovalRequest({
    required this.tool,
    required this.input,
    required this.reason,
  });

  final String tool;

  /// 原始参数，原样给界面。
  ///
  /// **弹窗要显示原样命令，不是"检测到危险操作"四个字。** 用户判断依赖原文——
  /// 一份启发式黑名单抓不住的变体太多了，而人一眼就能看出来。这是整个安全设计里
  /// 最有效的一环，别把它降级成一句摘要。
  final Map<String, Object?> input;

  /// 为什么要问。人话，一两句。
  final String reason;
}

/// 审批的结局。
enum ApprovalOutcome {
  approved,
  denied,

  /// 等超时了。
  ///
  /// **这一种不能省。** 审批等待挂在 `async*` 生成器的 `await` 上：没有时限的话，
  /// `ChatProvider.stop()` 里的 `_sub.cancel()` 驱动不到下一个 `yield`，
  /// 生成器永远清理不掉（`finally` 不执行、`Completer` 泄漏）。
  timedOut,

  /// 这个环境压根没有确认通道（`ToolContext.approver` 是 null）。
  ///
  /// **按拒绝处理，不是放行。** 忘了接审批界面必须当场暴露，不能静默变成
  /// "审批失效"——跟 `BrowserDriver.unavailableReason` 那条"宁可说不能用"是同一个取舍。
  unavailable,
}

class ToolApprovalDecision {
  const ToolApprovalDecision(this.outcome, {this.note, this.auto = false});

  const ToolApprovalDecision.approved() : this(ApprovalOutcome.approved);

  /// 自动模式放行的。
  ///
  /// 跟 [ToolApprovalDecision.approved] 走向完全一样，区别**只在审计日志里**：
  /// 用户点过同意的记 `ran`，自动模式免掉那一下的记 `auto-ran`。事后翻日志
  /// 时这两件事必须分得开——"我点的"和"它自己放行的"是两种责任。
  const ToolApprovalDecision.autoApproved()
    : this(ApprovalOutcome.approved, auto: true);

  const ToolApprovalDecision.denied([String? note])
    : this(ApprovalOutcome.denied, note: note);

  const ToolApprovalDecision.timedOut()
    : this(ApprovalOutcome.timedOut);

  const ToolApprovalDecision.unavailable()
    : this(ApprovalOutcome.unavailable);

  final ApprovalOutcome outcome;

  /// 用户附带的说明（如果界面允许他打字）。
  final String? note;

  /// 这一次是自动模式免掉弹窗放行的，不是用户点的。
  final bool auto;

  bool get isApproved => outcome == ApprovalOutcome.approved;
}

/// 界面侧提供的确认实现。`ChatProvider` 负责造一个。
typedef ToolApprover =
    Future<ToolApprovalDecision> Function(ToolApprovalRequest request);

/// 审批没通过时**回给模型**的那句话。
///
/// ## 为什么必须写"别重试同一个"
///
/// 模型看不见弹窗。它只知道"这个工具返回了失败"，最自然的反应是换个写法再试一次
/// ——而人已经明确拒了。不说这句话，它会拿同一件事反复撞，把轮数烧光，
/// 用户看到的是"说了不要它还一直试"。
String approvalRefusalText(ToolApprovalDecision decision) {
  switch (decision.outcome) {
    case ApprovalOutcome.approved:
      // 调用方只在没通过时才叫这个函数。真走到这儿是接线错了，但没必要为它抛异常
      // ——那会把一轮对话带崩，而不是留个能看懂的东西。
      return '';
    case ApprovalOutcome.denied:
      final note = decision.note?.trim() ?? '';
      final suffix = note.isEmpty ? '' : '用户说：$note。';
      return '用户拒绝了这次操作，没有执行。$suffix'
          '不要重试同一个操作——换个做法，或者直接问用户想怎么办。';
    case ApprovalOutcome.timedOut:
      return '等用户确认超时了，这次操作没有执行。'
          '不要重试同一个操作，先跟用户说一声。';
    case ApprovalOutcome.unavailable:
      return '这个操作需要用户确认，但现在没有确认的界面，所以没有执行。'
          '如实告诉用户：这个操作他这会儿确认不了。';
  }
}
