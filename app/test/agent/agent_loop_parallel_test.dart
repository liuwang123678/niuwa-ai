import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 记录并发峰值的探针工具。
class _Tracker {
  int active = 0;
  int peak = 0;
  final List<String> entered = [];
}

class _Probe extends N1Tool {
  _Probe(
    this.name,
    this.tracker, {
    this.parallel = true,
    this.approval = false,
    this.delayMs = 30,
  });

  @override
  final String name;

  final _Tracker tracker;
  final bool parallel;
  final bool approval;
  final int delayMs;

  @override
  String get description => '探针';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  bool get runsInParallel => parallel;

  @override
  bool get requiresApproval => approval;

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    tracker.entered.add(name);
    tracker.active++;
    if (tracker.active > tracker.peak) tracker.peak = tracker.active;
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    tracker.active--;
    return ToolResult.ok(name);
  }
}

/// 一轮里发起多个工具调用。
List<LlmChunk> multiToolTurn(List<String> names) {
  final chunks = <LlmChunk>[];
  for (var i = 0; i < names.length; i++) {
    chunks.add(ToolCallChunk(index: i, id: 'call_$i', name: names[i]));
  }
  for (var i = 0; i < names.length; i++) {
    chunks.add(ToolCallChunk(index: i, argumentsFragment: '{}'));
  }
  chunks.add(const DoneChunk('tool_calls'));
  return chunks;
}

void main() {
  late ToolRegistry registry;
  late ToolContext context;

  setUp(() {
    registry = ToolRegistry();
    context = testContext();
  });

  AgentLoop buildLoop(LlmClient llm) => AgentLoop(
    llm: llm,
    tools: registry,
    context: context,
    promptBuilder: testPromptBuilder(),
  );

  test('三个只读工具真正同时跑，峰值并发是 3', () async {
    final tracker = _Tracker();
    for (final name in ['a', 'b', 'c']) {
      registry.register(_Probe(name, tracker));
    }

    final llm = FakeLlmClient([
      multiToolTurn(['a', 'b', 'c']),
      [const TextChunk('好了'), const DoneChunk('stop')],
    ]);

    await buildLoop(llm)
        .run(history: const [], input: ChatMessage.user('同时读三个'))
        .toList();

    expect(tracker.entered, ['a', 'b', 'c']);
    expect(tracker.peak, 3, reason: '只读工具应该并行，不该一个一个来');
  });

  test('中间夹一个有副作用的工具时，整段按原顺序串行', () async {
    final tracker = _Tracker();
    registry.register(_Probe('read1', tracker));
    registry.register(_Probe('write', tracker, parallel: false));
    registry.register(_Probe('read2', tracker));

    final llm = FakeLlmClient([
      multiToolTurn(['read1', 'write', 'read2']),
      [const TextChunk('好了'), const DoneChunk('stop')],
    ]);

    await buildLoop(llm)
        .run(history: const [], input: ChatMessage.user('读改写'))
        .toList();

    expect(tracker.entered, ['read1', 'write', 'read2']);
    expect(tracker.peak, 1, reason: '有副作用的调用不能和别的调用并行');
  });

  test('需要审批的只读工具也不并行', () async {
    final tracker = _Tracker();
    final approvedContext = testContext(
      approver: (_) async => const ToolApprovalDecision.approved(),
    );

    for (final name in ['a', 'b']) {
      registry.register(_Probe(name, tracker, approval: true));
    }

    final llm = FakeLlmClient([
      multiToolTurn(['a', 'b']),
      [const TextChunk('好了'), const DoneChunk('stop')],
    ]);

    await AgentLoop(
      llm: llm,
      tools: registry,
      context: approvedContext,
      promptBuilder: testPromptBuilder(),
    ).run(history: const [], input: ChatMessage.user('都要审批')).toList();

    expect(tracker.entered, ['a', 'b']);
    expect(tracker.peak, 1, reason: '审批弹窗不能同时弹两个');
  });

  test('并行执行后，回给模型的结果仍按调用顺序排列', () async {
    final tracker = _Tracker();
    // 故意让先发的慢、后发的快：完成顺序是 c、b、a，但回填必须是 a、b、c。
    registry.register(_Probe('a', tracker, delayMs: 60));
    registry.register(_Probe('b', tracker, delayMs: 30));
    registry.register(_Probe('c', tracker, delayMs: 5));

    final llm = FakeLlmClient([
      multiToolTurn(['a', 'b', 'c']),
      [const TextChunk('好了'), const DoneChunk('stop')],
    ]);

    final events = await buildLoop(llm)
        .run(history: const [], input: ChatMessage.user('顺序')).toList();

    final finishes = events.whereType<ToolCallFinished>().toList();
    expect(
      finishes.map((e) => e.invocation.call.name).toList(),
      ['a', 'b', 'c'],
      reason: 'tool 消息必须和 assistant 的 tool_calls 一一对应',
    );

    final produced = events.whereType<RunComplete>().single.produced;
    final toolMessages = produced.where((m) => m.role == Role.tool).toList();
    expect(
      toolMessages.map((m) => m.toolName).toList(),
      ['a', 'b', 'c'],
    );
  });

  test('只有一个只读工具时不走并行分支，行为不变', () async {
    final tracker = _Tracker();
    registry.register(_Probe('solo', tracker));

    final llm = FakeLlmClient([
      multiToolTurn(['solo']),
      [const TextChunk('好了'), const DoneChunk('stop')],
    ]);

    await buildLoop(llm)
        .run(history: const [], input: ChatMessage.user('一个')).toList();

    expect(tracker.entered, ['solo']);
    expect(tracker.peak, 1);
  });
}
