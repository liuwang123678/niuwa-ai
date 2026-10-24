import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 发起一次工具调用的一轮。参数按碎片给，模拟真实流式响应。
List<LlmChunk> toolTurn({
  required String id,
  required String name,
  List<String> argFragments = const ['{}'],
}) => [
  ToolCallChunk(index: 0, id: id, name: name),
  ...argFragments.map(
    (f) => ToolCallChunk(index: 0, argumentsFragment: f),
  ),
  const DoneChunk('tool_calls'),
];

List<LlmChunk> textTurn(String text) => [
  TextChunk(text),
  const DoneChunk('stop'),
];

AgentLoop buildLoop(LlmClient llm, ToolRegistry registry, ToolContext ctx) =>
    AgentLoop(
      llm: llm,
      tools: registry,
      context: ctx,
      promptBuilder: testPromptBuilder(),
      maxTurns: 8,
    );

void main() {
  group('审批门 × 主循环', () {
    // 这一组盯的是**拒绝之后流程还立不立得住**。审批门放在 ToolRegistry.invoke
    // 而不是 AgentLoop 里，全部理由就是这两条；它们要是没被钉住，
    // 以后有人"顺手"把判定挪到循环里就会静默坏掉。
    test('被拒之后：痕迹收尾、历史合法、模型还能接着说', () async {
      final tool = ProbeTool('danger', requiresApproval: true);
      final registry = ToolRegistry()..register(tool);
      final ctx = testContext(
        approver: (r) async => const ToolApprovalDecision.denied('别动'),
      );

      final llm = FakeLlmClient([
        toolTurn(id: 't1', name: 'danger'),
        textTurn('那我不删了。'),
      ]);

      final events = await buildLoop(llm, registry, ctx)
          .run(history: const [], input: ChatMessage.user('把那个删了'))
          .toList();

      // ① 界面那条痕迹必须收尾。`ToolTrace.running` 的定义就是 result == null，
      //    少一条 ToolCallFinished 那个转圈会**永远转**。
      final finished = events.whereType<ToolCallFinished>().toList();
      expect(finished, hasLength(1));
      expect(finished.single.invocation.result.ok, isFalse);
      expect(finished.single.invocation.result.content, contains('拒绝'));

      // ② 被拒的调用**一次都没真跑**。
      expect(tool.receivedInputs, isEmpty);

      final produced = events.whereType<RunComplete>().single.produced;

      // ③ 历史必须自洽：assistant 声明过的每个 tool_call_id 都要有对应的
      //    tool 消息。少一条，下一轮请求就是
      //    HTTP 400 "Messages with role 'tool' must be a response to a
      //    preceding message with 'tool_calls'"——整段对话直接废掉。
      final declared = <String>{};
      final answered = <String>{};
      for (final m in produced) {
        if (m.role == Role.assistant && m.toolCalls != null) {
          declared.addAll(m.toolCalls!.map((c) => c.id));
        }
        if (m.role == Role.tool && m.toolCallId != null) {
          answered.add(m.toolCallId!);
        }
      }
      expect(declared, {'t1'});
      expect(
        answered,
        declared,
        reason: '拒绝也要产出一条 tool 消息——它和"工具跑失败了"在协议上是一回事',
      );

      // ④ 模型看到拒绝之后真的换了个做法（说了句话），而不是卡在原地。
      final reply = produced.where(
        (m) => m.role == Role.assistant && m.content.contains('不删'),
      );
      expect(reply, hasLength(1));
    });

    test('同一轮里一个被拒、一个放行，两个都各自收尾', () async {
      final allowed = ProbeTool('danger', requiresApproval: true);
      final registry = ToolRegistry()..register(allowed);
      final ctx = testContext(
        approver: (r) async =>
            r.input['n'] == '1'
                ? const ToolApprovalDecision.approved()
                : const ToolApprovalDecision.denied(),
      );

      final llm = FakeLlmClient([
        [
          ToolCallChunk(index: 0, id: 'a', name: 'danger'),
          ToolCallChunk(index: 0, argumentsFragment: '{"n":"1"}'),
          ToolCallChunk(index: 1, id: 'b', name: 'danger'),
          ToolCallChunk(index: 1, argumentsFragment: '{"n":"2"}'),
          const DoneChunk('tool_calls'),
        ],
        textTurn('一个做了，一个没做。'),
      ]);

      final events = await buildLoop(llm, registry, ctx)
          .run(history: const [], input: ChatMessage.user('两个都做'))
          .toList();

      final finished = events.whereType<ToolCallFinished>().toList();
      expect(finished, hasLength(2), reason: '两个调用都要有结局，不能漏一个');
      expect(finished[0].invocation.result.ok, isTrue);
      expect(finished[1].invocation.result.ok, isFalse);
      expect(allowed.receivedInputs, hasLength(1), reason: '只有放行的那个真跑了');
    });
  });
}
