import 'dart:async';

import 'package:niuwa_ai/core/n1_core.dart';

/// 按脚本吐 chunk 的假模型。
///
/// 每次 [stream] 调用消费脚本里的一批——这样就能模拟"第一轮调工具、第二轮才回答"
/// 这种多轮场景。
class FakeLlmClient implements LlmClient {
  FakeLlmClient(this.script);

  /// 第 N 次调用吐出 script[N]。
  final List<List<LlmChunk>> script;

  int calls = 0;
  List<ChatMessage> lastMessages = const [];
  List<ToolSpec> lastTools = const [];

  @override
  String get model => 'fake';

  @override
  Stream<LlmChunk> stream(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
  }) async* {
    // 必须拷贝：AgentLoop 会把同一个 list 继续往后追加，
    // 留着引用的话测试读到的就不是"发出去时"的样子了。
    lastMessages = List.of(messages);
    lastTools = tools;

    final turn = calls++;
    if (turn >= script.length) {
      throw StateError('脚本只写了 ${script.length} 轮，但已经被调用第 ${turn + 1} 次了');
    }
    for (final chunk in script[turn]) {
      yield chunk;
    }
  }
}

/// 一个总是抛 [LlmException] 的客户端。
class FailingLlmClient implements LlmClient {
  FailingLlmClient(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String get model => 'fake';

  @override
  Stream<LlmChunk> stream(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
  }) async* {
    throw LlmException(message, statusCode: statusCode);
  }
}

/// 记住每次调用参数的探针工具。
class ProbeTool extends N1Tool {
  ProbeTool(
    this.name, {
    this.description = '探针',
    this.result = const ToolResult.ok('ok'),
    this.throwThis,
    this.delay = Duration.zero,
    this.requiresApproval = false,
    Map<String, Object?>? schema,
  }) : inputSchema = schema ?? const {'type': 'object', 'properties': {}};

  @override
  final String name;

  @override
  final String description;

  @override
  final Map<String, Object?> inputSchema;

  @override
  final bool requiresApproval;

  final ToolResult result;
  final Object? throwThis;
  final Duration delay;

  final List<Map<String, Object?>> receivedInputs = [];

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    receivedInputs.add(input);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (throwThis != null) throw throwThis!;
    return result;
  }
}

/// 组装一个最小可用的 ToolContext。
ToolContext testContext({
  MemoryStore? memory,
  SkillRegistry? skills,
  BrowserDriver? browser,
  ReminderStore? reminders,
  ToolApprover? approver,
}) {
  final store = memory ?? InMemoryMemoryStore();
  final registry = skills ?? SkillRegistry();
  return ToolContext(
    memory: store,
    skills: registry,
    browser: browser ?? const UnavailableBrowserDriver('测试环境不支持浏览器'),
    reminders: reminders ?? InMemoryReminderStore(),
    // ⚠️ 默认**不给** approver。`ToolContext.approver` 为 null 等于"没法问"，
    // 需要审批的工具会直接判拒绝。想在测试里放行就得显式传一个。
    // 反过来说：忘了传的话，测试会看见"操作没执行"而不是"偷偷执行了"，
    // 这正是想要的方向。
    approver: approver,
  );
}

/// 测试里用的固定"现在"。2026-09-25 那天是周五。
final testNow = DateTime(2026, 9, 25, 14, 30);

/// 造一个 PromptBuilder。
///
/// 它**不管时间**了：时间由 `AgentLoop._withClock` 拼进最后一条用户消息，
/// 理由见那个方法的注释（放 system prompt 里会让整段历史的缓存每分钟失效）。
PromptBuilder testPromptBuilder({
  String persona = '你是测试人设。',
  SkillRegistry? skills,
  MemoryStore? memory,
}) => PromptBuilder(
  persona: persona,
  skills: skills ?? SkillRegistry(),
  memory: memory ?? InMemoryMemoryStore(),
);
