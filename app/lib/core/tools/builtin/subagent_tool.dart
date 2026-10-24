import '../../agent/agent_event.dart';
import '../../agent/agent_loop.dart';
import '../../agent/prompt_builder.dart';
import '../../llm/llm_client.dart';
import '../../models/chat_message.dart';
import '../n1_tool.dart';
import '../tool_approval.dart';
import '../tool_context.dart';
import '../tool_registry.dart';

/// 让模型把一个"查资料"的活外包出去，拿回一段结论。
///
/// 立这个工具的理由是**上下文**：主对话要陪用户，不该被二十个文件的正文
/// 塞满。子代理在自己的上下文里翻完，只把结论交回来，主对话里只多出这一段。
///
/// ## 为什么只给只读工具
///
/// 子代理是**背对着用户跑的**：它的工具调用不弹审批、不进界面，用户看不见
/// 它在干什么。这种情况下再给它写文件、跑命令的能力，等于绕过了主对话那套
/// "危险操作先问用户"的闸门。所以这里只挑 [N1Tool.runsInParallel] 为真的
/// 工具——那个标记的语义正好就是"只读、不共享可变状态、不用审批"。
///
/// 这不是保守，是**审批通道的接线问题**：真要让它写东西，得先把子代理的
/// 工具痕迹和审批弹窗接回主界面，那是另一件事。
class RunSubagentTool extends N1Tool {
  RunSubagentTool({
    required this.llm,
    required this.parentTools,
    this.maxTurns = 8,
    this.maxInputTokens = 48000,
  });

  /// 跟主对话用同一个客户端：模型、Key、温度都一样，只是上下文另起一份。
  final LlmClient llm;

  /// 主会话的工具表。**调用时现取**，因为它是会变的（会话建好之后还会补
  /// 浏览器、代码、MCP 工具），建工具那一刻的快照会漏掉后补进来的那些。
  final ToolRegistry parentTools;

  final int maxTurns;
  final int maxInputTokens;

  static const String toolName = 'run_subagent';

  @override
  String get name => toolName;

  @override
  String get description =>
      '把一个独立的调研任务交给子代理去做。它有自己的上下文，'
      '可以读文件、列目录、搜索、抓网页，最后只把一段结论交回来——'
      '中间翻过的那些内容不会占你的上下文。'
      '适合「把这个目录里所有配置文件的用途整理一下」'
      '「查一下这几个网页里分别怎么写的」这种范围大、过程繁琐的活。'
      '它不能写文件、不能跑命令、不能操作浏览器。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'task': {
        'type': 'string',
        'description':
            '交代清楚要查什么、在哪个范围查、最后要什么样的结论（比如"列成表"'
            '或"一段话概括"）。范围写得越具体，它跑得越快。',
      },
    },
    'required': ['task'],
  };

  /// 子代理自己会烧钱，两个子代理同时跑更容易撞上游限流。串行。
  @override
  bool get runsInParallel => false;

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final task = N1Tool.requireString(input, 'task');

    final allowed = [
      for (final tool in parentTools.all)
        if (tool.name != toolName && tool.runsInParallel) tool,
    ];
    if (allowed.isEmpty) {
      return ToolResult.fail(
        '现在没有可以交给子代理的只读工具（读文件、搜索、抓网页这些都不可用），'
        '这个活没法外包，你自己做或者让用户把权限打开。',
      );
    }

    final registry = ToolRegistry();
    // 子代理里的工具结果也得按同样的上限截，不然一个 grep 就能把它的
    // 上下文吃光——那正是开子代理要避免的事。
    registry.resultChars = parentTools.resultChars;
    for (final tool in allowed) {
      registry.register(tool, timeout: parentTools.timeoutFor(tool.name));
    }

    // 另开一份审批通道，**一律拒绝**。实际上只读工具不会触发审批；这一层
    // 防的是以后某个新工具把 runsInParallel 标错了，那时候宁可失败，也不能
    // 在用户看不见的地方弹窗或者悄悄执行。
    final subContext = ctx.fork(
      approver: (_) async =>
          const ToolApprovalDecision.denied('子代理只能读，不能改。'),
    );

    final loop = AgentLoop(
      llm: llm,
      tools: registry,
      context: subContext,
      maxTurns: maxTurns,
      maxInputTokens: maxInputTokens,
      promptBuilder: _SubagentPromptBuilder(
        // PromptBuilder 要 memory/skills 两个参数是为了拼默认人设；这里
        // build 被整个覆盖了，它们只是占位，但仍然用真的——以后哪天想给
        // 子代理加记忆索引，改的是这里而不是造一堆假对象。
        '你是一个只做调研的子代理，替主助手跑腿。',
        persona: '',
        skills: ctx.skills,
        memory: ctx.memory,
      ),
    );

    final report = StringBuffer();
    var failure = '';
    var stopReason = 'stop';

    // 只收正文和失败。**工具痕迹故意不转出去**：那些是子代理自己的过程，
    // 转给用户看会让主对话里凭空多出一串他没要求过的操作。
    await for (final event in loop.run(
      history: const [],
      input: ChatMessage.user(task),
    )) {
      switch (event) {
        case TextDelta(:final text):
          report.write(text);
        case AgentFailed(:final message):
          failure = message;
        case RunComplete(stopReason: final reason):
          stopReason = reason ?? 'stop';
        default:
          // TurnStarted / ReasoningDelta / ToolCall* / Usage / Trimmed：
          // 都是子代理自己的事，不往外抛。
          break;
      }
    }

    if (failure.isNotEmpty) return ToolResult.fail('子代理失败了：$failure');

    final text = report.toString().trim();
    if (text.isEmpty) {
      return ToolResult.fail(
        '子代理跑完了（$stopReason），但一个字都没写回来。'
        '换个更具体的任务描述再试一次。',
      );
    }

    // 撞上回合上限要如实说：结论可能只查了一半，接手的模型得知道。
    final note = stopReason == 'max_turns'
        ? '\n\n（子代理用完了 $maxTurns 轮的工具调用上限就停了，'
              '上面的结论可能不完整。）'
        : '';

    return ToolResult.ok('$text$note', meta: {'stop_reason': stopReason});
  }
}

/// 固定人设的 PromptBuilder。
///
/// `AgentLoop` 只认 PromptBuilder；这里要的恰恰是"别拼用户的人设、技能索引、
/// 记忆索引"，一段写死的规矩就够了。
class _SubagentPromptBuilder extends PromptBuilder {
  _SubagentPromptBuilder(
    this.instructions, {
    required super.persona,
    required super.skills,
    required super.memory,
  });

  final String instructions;

  @override
  Future<String> build({Iterable<String> toolNames = const []}) async => '''
$instructions

规矩：
- 你手上只有只读工具（读文件、列目录、搜索、抓网页、看技能）。写文件、跑命令、
  操作浏览器这些工具根本不在你手里，别试着调。
- 不要问问题。没人能回答你，问了只会白费一轮。缺什么就直接在结论里说明。
- 先查清楚再说结论。能读文件就别猜。
- 结论带上依据：文件路径、行号、网址。控制在 800 字以内。
- 不要复述你调用过哪些工具，直接给结果。
''';
}
