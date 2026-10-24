import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 盯「按话题浮出来的旧记忆」和「压缩过的前半场」这两件注入。
///
/// 它们都改了发出去的消息，而**改错了没有任何界面会报错**——模型只是答得
/// 差一点，或者干脆答得挺好但一直在重复你已经说过的事。所以这里钉的是
/// 位置和边界：放哪儿、放几条、没有的时候是不是一个字都不加。
MemoryEntry mem(String content, {String? subject, int importance = 3}) =>
    MemoryEntry.create(
      kind: MemoryKind.fact,
      content: content,
      subject: subject,
      importance: importance,
      now: testNow.millisecondsSinceEpoch,
    );

List<LlmChunk> textTurn(String text) => [
  TextChunk(text),
  const DoneChunk('stop'),
];

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
    clock: () => testNow,
  );

  group('按话题捞到的旧记忆', () {
    test('拼在最后一条用户消息末尾，并保持确定性顺序', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: const [],
            input: ChatMessage.user('我妈下周过生日'),
            recalled: [
              mem('妈妈有糖尿病，不吃甜的', subject: '妈妈'),
              mem('用户住在武汉', subject: '用户'),
            ],
          )
          .toList();

      final sent = llm.lastMessages.last;
      expect(sent.role, Role.user);
      // 用户原话一个字不能少，而且要在前面——注入是"顺带想起"，不是改写。
      expect(sent.content, contains('我妈下周过生日'));
      final mine = sent.content.indexOf('我妈下周过生日');
      final recall = sent.content.indexOf('妈妈有糖尿病');
      expect(mine, lessThan(recall), reason: '旧事要排在用户原话之后');
      expect(sent.content, contains('用户住在武汉'));
      expect(sent.content, contains('不一定都还用得上'));
    });

    test('没有捞到就一个字都不加——老行为原样', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('在吗'))
          .toList();

      expect(
        llm.lastMessages.last.content,
        '${AgentLoop.clockLine(testNow)}\n在吗',
      );
    });

    test('相关记忆不进 system prompt（否则每句话都会让缓存失效）', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: const [],
            input: ChatMessage.user('我今天想吃点好的'),
            recalled: [mem('用户不吃香菜')],
          )
          .toList();

      expect(llm.lastMessages.first.role, Role.system);
      expect(llm.lastMessages.first.content, isNot(contains('不吃香菜')));
    });

    test('recallBlock 最多 8 条，过长的条目截断', () {
      final entries = [
        for (var i = 0; i < 12; i++) mem('第 $i 条'),
      ];
      final block = AgentLoop.recallBlock(entries);
      expect(RegExp('- ').allMatches(block).length, lessThanOrEqualTo(8));
      expect(block, contains('第 0 条'));
      expect(block, isNot(contains('第 11 条')));
    });
  });

  group('压缩过的前半场', () {
    test('挂进 system prompt，历史里不重复', () async {
      final llm = FakeLlmClient([textTurn('接着做')]);

      await buildLoop(llm)
          .run(
            history: [ChatMessage.user('我们要做一个小工具')],
            input: ChatMessage.user('做到哪了'),
            conversationSummary: '用户在做一个统计脚本，已经写好了读取部分。',
          )
          .toList();

      final system = llm.lastMessages.first;
      expect(system.role, Role.system);
      expect(system.content, contains('更早的对话'));
      expect(system.content, contains('已经写好了读取部分'));
      // 摘要只出现一次：进 system 就不要再塞进用户消息。
      final all = llm.lastMessages.map((m) => m.content).join('\n');
      expect('已经写好了读取部分'.allMatches(all).length, 1);
    });

    test('没有摘要时 system prompt 与以前逐字相同', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);
      final loop = buildLoop(llm);

      await loop
          .run(history: const [], input: ChatMessage.user('在吗'))
          .toList();
      final plain = llm.lastMessages.first.content;

      await loop
          .run(
            history: const [],
            input: ChatMessage.user('在吗'),
            conversationSummary: '   ',
          )
          .toList();

      expect(llm.lastMessages.first.content, plain);
    });
  });
}
