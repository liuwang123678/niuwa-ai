import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/n1_runtime.dart';

import '../support/fake_llm.dart';

/// 走一遍真流程：模型决定调 reminder_create → 工具执行 → 提醒落库。
///
/// 这里证的是「提醒工具跟 agent 循环接得上」——工具表注册、参数从 JSON 碎片
/// 拼出来、结果回填给模型、模型接着说话，整条链没有断的地方。
/// （「`N1Runtime.newSession` 里真的注册了这两个工具」是另一回事，
/// 那个要靠真跑一遍，见计划 Task 7 Step 5。）
void main() {
  final now = DateTime(2026, 9, 25, 20, 30);

  test('newSession 真的会注册提醒工具', () {
    // 上面两个用例证的是「工具跟循环接得上」，但工具表是测试自己搭的——
    // 就算 newSession 里漏了注册，它们照样绿，而用户那边的症状是
    // 「N1 说它设好了，其实没设」。所以这条直接问生产代码要清单。
    final names = N1Runtime.alwaysOnTools().map((t) => t.name).toList();

    expect(names, contains('reminder_create'));
    expect(names, contains('reminder_list'));

    // 顺带钉一下原来就有的六个没被这次改动挤掉。
    expect(
      names,
      containsAll(<String>[
        'get_time',
        'http_fetch',
        'memory_save',
        'memory_search',
        'skill_list',
        'skill_read',
      ]),
    );

    // 名字不能重——重了后注册的会盖掉先注册的，而且不报错。
    expect(names.toSet(), hasLength(names.length));
  });

  test('模型调 reminder_create 之后，提醒真的在库里', () async {
    final store = InMemoryReminderStore();

    final tools = ToolRegistry()
      ..register(ReminderCreateTool(clock: () => now))
      ..register(const ReminderListTool());

    final llm = FakeLlmClient([
      [
        const ToolCallChunk(
          index: 0,
          id: 'call_1',
          name: 'reminder_create',
          argumentsFragment:
              '{"fire_at":"2026-09-26 15:00","say":"三点了，作业交了没？"}',
        ),
        const DoneChunk('tool_calls'),
      ],
      [const TextChunk('好，明天三点叫你。'), const DoneChunk('stop')],
    ]);

    final loop = AgentLoop(
      llm: llm,
      tools: tools,
      context: testContext(reminders: store),
      promptBuilder: testPromptBuilder(),
    );

    final events = await loop
        .run(history: const [], input: ChatMessage.user('明天下午三点提醒我交作业'))
        .toList();

    // 走到了「用工具 → 再回答」两轮
    expect(events.whereType<RunComplete>().single.stopReason, 'stop');

    final saved = await store.pending();
    expect(saved, hasLength(1));
    expect(saved.single.fireAt, DateTime(2026, 9, 26, 15, 0));
    expect(saved.single.message, '三点了，作业交了没？');

    // 工具真的被注册进发给模型的工具表了
    expect(
      llm.lastTools.map((t) => t.name),
      containsAll(<String>['reminder_create', 'reminder_list']),
    );
  });

  test('工具报错时模型能拿到失败原因，不是整个循环崩掉', () async {
    final store = InMemoryReminderStore();

    final tools = ToolRegistry()
      ..register(ReminderCreateTool(clock: () => now));

    // 模型给了个过去的时间——这是它最容易犯的错（把"明天"算错）。
    final llm = FakeLlmClient([
      [
        const ToolCallChunk(
          index: 0,
          id: 'call_1',
          name: 'reminder_create',
          argumentsFragment:
              '{"fire_at":"2026-09-25 10:00","say":"该走了"}',
        ),
        const DoneChunk('tool_calls'),
      ],
      [const TextChunk('那个时间已经过了，你是指明天吗？'), const DoneChunk('stop')],
    ]);

    final loop = AgentLoop(
      llm: llm,
      tools: tools,
      context: testContext(reminders: store),
      promptBuilder: testPromptBuilder(),
    );

    final events = await loop
        .run(history: const [], input: ChatMessage.user('提醒我交作业'))
        .toList();

    expect(events.whereType<RunComplete>().single.stopReason, 'stop');
    // 没设进去——失败就是失败，不许假装成功
    expect(await store.count(), 0);

    // 失败原因真的回给模型了，它才有机会追问
    final toolMsg = llm.lastMessages.lastWhere((m) => m.role == Role.tool);
    expect(toolMsg.content, contains('过去'));
  });
}
