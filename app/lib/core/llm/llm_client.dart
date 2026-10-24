import '../models/chat_message.dart';

/// 喂给模型的工具声明（JSON Schema）。
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  Map<String, Object?> toWire() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// 流式响应的一段。用 sealed + pattern matching 收，别写成 Map 到处 if。
sealed class LlmChunk {
  const LlmChunk();
}

/// 正文增量。
final class TextChunk extends LlmChunk {
  const TextChunk(this.text);
  final String text;
}

/// 思考过程增量。各家字段名不一样（`reasoning_content` / `reasoning`），
/// 由客户端负责归一到这里。
///
/// 只给界面看，不要拼进 content——模型自己也不接受这个字段回传。
final class ReasoningChunk extends LlmChunk {
  const ReasoningChunk(this.text);
  final String text;
}

/// 工具调用增量。
///
/// 协议事实（已实测）：首块带 [id] 和 [name]，后续块只有 [index] 加 [argumentsFragment]
/// 的字符串碎片。调用方必须按 [index] 把碎片按顺序拼起来，拼完才是合法 JSON。
final class ToolCallChunk extends LlmChunk {
  const ToolCallChunk({
    required this.index,
    this.id,
    this.name,
    this.argumentsFragment,
  });

  final int index;
  final String? id;
  final String? name;
  final String? argumentsFragment;
}

final class UsageChunk extends LlmChunk {
  const UsageChunk({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedTokens = 0,
  });

  final int promptTokens;
  final int completionTokens;

  /// 命中提示缓存的 token 数。system prompt 稳定就有这个>0，能省钱。
  final int cachedTokens;
}

/// 本轮结束。[finishReason] 常见值：`stop` / `tool_calls` / `length`。
final class DoneChunk extends LlmChunk {
  const DoneChunk(this.finishReason);
  final String? finishReason;
}

/// 调用模型失败。界面要拿 [message] 直接给人看，所以别塞英文堆栈。
class LlmException implements Exception {
  const LlmException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() => 'LlmException($statusCode): $message';
}

/// 模型客户端。
///
/// 只有一个实现 [OpenAiCompatClient]（见 `openai_compat_client.dart`），
/// 因为要接的几家走的是同一套协议。留着这层接口是为了测试能塞假客户端，
/// 以及哪天真碰上一家不兼容的，加实现时不用动上层。
abstract class LlmClient {
  String get model;

  /// 流式对话。取消订阅即中止请求（实现里靠 `finally` 关连接）。
  Stream<LlmChunk> stream(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
  });
}
