import '../llm/llm_client.dart';
import '../models/chat_message.dart';
import '../tools/tool_registry.dart';

/// agent 一轮跑下来对外发的事件。界面边收边画。
sealed class AgentEvent {
  const AgentEvent();
}

/// 新的一轮开始了（含工具结果回填后的续跑）。
final class TurnStarted extends AgentEvent {
  const TurnStarted(this.turn, {required this.isContinuation});

  final int turn;

  /// true = 这轮是上一轮工具调用之后接着跑的，不是用户新发的消息。
  final bool isContinuation;
}

/// 正文增量。
final class TextDelta extends AgentEvent {
  const TextDelta(this.text);
  final String text;
}

/// 思考过程增量。界面上应该跟正文分开显示（折叠区/灰色小字）。
final class ReasoningDelta extends AgentEvent {
  const ReasoningDelta(this.text);
  final String text;
}

/// 模型决定调某个工具了，但还没执行。
///
/// 界面收到这个就该把"正在执行 xxx"显示出来——浏览器操作可能要好几秒。
final class ToolCallStarted extends AgentEvent {
  const ToolCallStarted(this.call);
  final ToolCall call;
}

/// 工具执行完了。
final class ToolCallFinished extends AgentEvent {
  const ToolCallFinished(this.invocation);
  final ToolInvocation invocation;
}

/// 一句话说完了。[message] 要落库。
final class TurnComplete extends AgentEvent {
  const TurnComplete(this.message);
  final ChatMessage message;
}

/// 本轮用掉的 token。用于界面上显示用量和成本。
final class UsageReported extends AgentEvent {
  const UsageReported(this.usage);
  final UsageChunk usage;
}

/// 这一步的输入超出了预算，老内容被裁掉了一部分。
///
/// 该让用户知道——否则模型不记得几分钟前说过的话，看起来就像它突然变笨了。
/// 真实原因是上下文装不下，我们选择了"裁掉旧的、让它还能回答"。
final class ContextTrimmed extends AgentEvent {
  const ContextTrimmed({required this.droppedMessages, required this.approxTokens});

  /// 被整段丢掉的消息条数。只压缩正文、没删消息时是 0。
  final int droppedMessages;

  /// 裁剪后这一步大约要发多少 token。
  final int approxTokens;
}

/// 整轮跑完了（不再有工具调用，或者撞上了轮数上限）。
final class RunComplete extends AgentEvent {
  const RunComplete({required this.produced, required this.stopReason});

  /// 这一轮新产生的所有消息（用户输入 + assistant + tool 结果），按顺序。
  /// **调用方拿这个落库**，不要自己去拼。
  final List<ChatMessage> produced;

  /// `stop` / `tool_calls` / `max_turns` / `incomplete` / `length`
  final String? stopReason;
}

/// 出错了。到这里就终止，不会再有后续事件。
final class AgentFailed extends AgentEvent {
  const AgentFailed(this.message, {this.error});

  /// 可以直接显示给人看的中文。
  final String message;

  final Object? error;
}
