import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 只读探针：`runsInParallel` 是子代理挑工具的唯一标准。
class _ParallelTool extends ProbeTool {
  _ParallelTool(super.name, {super.result});

  @override
  bool get runsInParallel => true;
}

void main() {
  test('子代理只拿到只读工具，自己也拿不到 run_subagent', () async {
    final tools = ToolRegistry()
      ..register(_ParallelTool('read_like'))
      ..register(ProbeTool('write_like'));

    final llm = FakeLlmClient([
      [const TextChunk('完事了'), const DoneChunk('stop')],
    ]);
    final subagent = RunSubagentTool(llm: llm, parentTools: tools);
    tools.register(subagent);

    final result = await subagent.call({
      'task': '看看这个项目',
    }, testContext());

    expect(result.ok, isTrue);
    final names = llm.lastTools.map((t) => t.name);
    expect(names, contains('read_like'));
    expect(names, isNot(contains('write_like')));
    expect(names, isNot(contains(RunSubagentTool.toolName)));
  });

  test('子代理可以调工具，最后只把正文交回来', () async {
    final tools = ToolRegistry()..register(GetTimeTool());
    final llm = FakeLlmClient([
      [
        const ToolCallChunk(
          index: 0,
          id: 'c1',
          name: 'get_time',
          argumentsFragment: '{}',
        ),
        const DoneChunk('tool_calls'),
      ],
      [const TextChunk('查到了，现在是下午。'), const DoneChunk('stop')],
    ]);

    final result = await RunSubagentTool(
      llm: llm,
      parentTools: tools,
    ).call({'task': '现在几点'}, testContext());

    expect(result.ok, isTrue);
    expect(result.content, '查到了，现在是下午。');
    expect(result.meta?['stop_reason'], 'stop');
  });

  test('它的人设是写死的那套，不会把用户人设和聊天记忆带进去', () async {
    final tools = ToolRegistry()..register(GetTimeTool());
    final llm = FakeLlmClient([
      [const TextChunk('好'), const DoneChunk('stop')],
    ]);

    await RunSubagentTool(
      llm: llm,
      parentTools: tools,
    ).call({'task': '随便看看'}, testContext());

    final system = llm.lastMessages.first;
    expect(system.role, Role.system);
    expect(system.content, contains('只做调研的子代理'));
    expect(system.content, contains('不要问问题'));
    expect(system.content, isNot(contains('你是测试人设')));
  });

  test('模型挂了如实转成失败，不是抛异常也不是假装成功', () async {
    final tools = ToolRegistry()..register(GetTimeTool());
    final result = await RunSubagentTool(
      llm: FailingLlmClient('服务器炸了'),
      parentTools: tools,
    ).call({'task': '随便看看'}, testContext());

    expect(result.ok, isFalse);
    expect(result.content, contains('服务器炸了'));
  });

  test('撞上回合上限会明说，免得父代理把半截结论当真', () async {
    final tools = ToolRegistry()..register(GetTimeTool());
    // 每一轮都调工具，永远不结束——直到 maxTurns 用完。最后一轮也写了正文，
    // 这样验的是"结论 + 上限说明"，而不是"没写正文"那条失败路径。
    final llm = FakeLlmClient([
      for (var i = 0; i < 2; i++)
        [
          TextChunk('第 ${i + 1} 轮的结论。'),
          ToolCallChunk(
            index: 0,
            id: 'c$i',
            name: 'get_time',
            argumentsFragment: '{}',
          ),
          const DoneChunk('tool_calls'),
        ],
    ]);

    final result = await RunSubagentTool(
      llm: llm,
      parentTools: tools,
      maxTurns: 2,
    ).call({'task': '一直查'}, testContext());

    expect(result.ok, isTrue);
    expect(result.content, contains('工具调用上限'));
  });

  test('子代理里也按父会话的上限截工具结果', () async {
    final tools = ToolRegistry()
      ..register(_ParallelTool('long', result: ToolResult.ok('x' * 500)))
      ..resultChars = 100;

    final llm = FakeLlmClient([
      [
        const ToolCallChunk(
          index: 0,
          id: 'c1',
          name: 'long',
          argumentsFragment: '{}',
        ),
        const DoneChunk('tool_calls'),
      ],
      [const TextChunk('好'), const DoneChunk('stop')],
    ]);

    await RunSubagentTool(
      llm: llm,
      parentTools: tools,
    ).call({'task': '读一大段'}, testContext());

    final toolMessage = llm.lastMessages.lastWhere((m) => m.role == Role.tool);
    expect(toolMessage.content.length, lessThan(500));
    expect(toolMessage.content, contains('只回喂了前'));
  });

  test('一个只读工具都没有时直接说做不了，不去空跑一轮', () async {
    final tools = ToolRegistry()..register(ProbeTool('write_like'));
    final llm = FakeLlmClient(const []);

    final result = await RunSubagentTool(
      llm: llm,
      parentTools: tools,
    ).call({'task': '看看'}, testContext());

    expect(result.ok, isFalse);
    expect(result.content, contains('没有可以交给子代理的只读工具'));
    expect(llm.calls, 0);
  });

  test('任务描述是必填的', () async {
    final tools = ToolRegistry()..register(GetTimeTool());
    tools.register(
      RunSubagentTool(llm: FakeLlmClient(const []), parentTools: tools),
    );

    // 走 invoke 才对得上真实路径：工具里抛的 ToolInputException 会在那里
    // 变成一句能回给模型的失败说明。
    final invocation = await tools.invoke(
      const ToolCall(id: 'c1', name: RunSubagentTool.toolName, arguments: {}),
      testContext(),
    );

    expect(invocation.result.ok, isFalse);
    expect(invocation.result.content, contains('task'));
  });
}
