import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 盯「聊久了别忘前半场」的节拍与边界。
///
/// 这条链没有界面：压早了白花钱、压晚了前半场已经被丢掉、切点不对会让
/// 一段 tool 结果变成孤儿（`sanitizeHistory` 丢掉它，而摘要说"这段我收下了"）。
/// 三种错法都只会表现为"它好像记性不太好"，所以规则得单独钉住。
void main() {
  /// 造一段"用户一句、助手一句"的对话。偶数下标是用户。
  List<ChatMessage> convo(int pairs) => [
    for (var i = 0; i < pairs; i++) ...[
      ChatMessage.user('用户第 $i 句'),
      ChatMessage.assistant('助手第 $i 句'),
    ],
  ];

  group('什么时候压', () {
    const schedule = DigestSchedule(keepRecent: 16, minNew: 12, maxRuns: 8);

    test('太短不压——28 条以下一次模型都不多打', () {
      expect(
        schedule.plan(convo(13), covered: 0, runs: 0),
        isNull,
        reason: '13 对 = 26 条，还没到"16 条保留 + 12 条起压"',
      );
    });

    test('够长了就压，而且最近的 16 条一条不动', () {
      final messages = convo(25); // 50 条
      final plan = schedule.plan(messages, covered: 0, runs: 0);
      expect(plan, isNotNull);
      final (start, end) = plan!;
      expect(start, 0);
      expect(end, 34, reason: '留最近 16 条；34 是偶数，正好是一句用户发言');
      expect(messages.length - end, 16);
    });

    test('压过的部分不重复压——从 covered 接着来', () {
      final messages = convo(30); // 60 条
      final plan = schedule.plan(messages, covered: 24, runs: 1)!;
      expect(plan.$1, 24);
      expect(plan.$2, 44);
      expect(plan.$2 - plan.$1, 20);
    });

    test('剩得不够 12 条就不再压', () {
      // 60 条、已经压到 44：到 60 之间只剩 16 条保留量，没有新东西可压。
      expect(schedule.plan(convo(30), covered: 44, runs: 2), isNull);
    });

    test('切点永远落在一句用户发言上，必要时往前退', () {
      // 每个用户回合后面跟两条助手消息，好让"长度 - 16"正落在助手那句上。
      final messages = <ChatMessage>[
        for (var i = 0; i < 30; i++) ...[
          ChatMessage.user('用户 $i'),
          ChatMessage.assistant('助手 $i'),
          ChatMessage.assistant('助手 $i 补充'),
        ],
      ];
      final plan = schedule.plan(messages, covered: 0, runs: 0)!;
      expect(messages[plan.$2].role, Role.user);
      expect(plan.$2, lessThan(messages.length - 16), reason: '应该往前退过');
    });

    test('到次数上限就停', () {
      expect(
        schedule.plan(convo(40), covered: 0, runs: 8),
        isNull,
      );
    });

    test('covered 越界时不动手，而不是崩', () {
      expect(schedule.plan(convo(20), covered: 99, runs: 0), isNull);
    });
  });

  group('压出来的是什么', () {
    test('剥掉模型自作主张包的代码块', () {
      expect(ConversationDigester.clean('```\n摘要正文\n```'), '摘要正文');
      expect(ConversationDigester.clean('```text\n摘要正文'), '摘要正文');
      expect(ConversationDigester.clean('   '), isNull);
    });

    test('超长截断——它每轮都挂在 system prompt 里', () {
      final long = '啊' * (ConversationDigester.maxChars + 300);
      final out = ConversationDigester.clean(long)!;
      expect(out.length, ConversationDigester.maxChars + 1);
      expect(out, endsWith('…'));
    });

    test('正文超长时两头都留，中间省略', () {
      final messages = [
        for (var i = 0; i < 40; i++)
          ChatMessage.user('第 $i 条：${'长' * 300}'),
      ];
      final transcript = ConversationDigester.buildTranscript(messages);
      expect(transcript.length, lessThan(ConversationDigester.transcriptChars + 40));
      expect(transcript, contains('第 0 条'), reason: '开头是"这事一开始怎么说的"');
      expect(transcript, contains('第 39 条'), reason: '结尾是"最近做到哪了"');
      expect(transcript, contains('中间略'));
    });
  });

  group('真调模型那一下', () {
    test('把旧摘要和新对话一起给，拿回来的直接能用', () async {
      final llm = FakeLlmClient([
        [const TextChunk('用户在做一个统计脚本；'), const TextChunk('已写完读取部分。')],
      ]);
      final digester = ConversationDigester(llm: llm);

      final text = await digester.digest(
        previous: '用户在做一个统计脚本。',
        chunk: [ChatMessage.user('现在写导出部分')],
      );

      expect(text, '用户在做一个统计脚本；已写完读取部分。');
      final prompt = llm.lastMessages.last.content;
      expect(prompt, contains('已有摘要'));
      expect(prompt, contains('用户在做一个统计脚本。'));
      expect(prompt, contains('现在写导出部分'));
    });

    test('模型挂了返回 null——调用方保留旧摘要，不出错给用户看', () async {
      final digester = ConversationDigester(
        llm: FailingLlmClient('网络断了'),
      );
      final text = await digester.digest(
        previous: '旧摘要',
        chunk: [ChatMessage.user('新的一句')],
      );
      expect(text, isNull);
    });

    test('模型返回空也算失败', () async {
      final digester = ConversationDigester(
        llm: FakeLlmClient([
          [const DoneChunk('stop')],
        ]),
      );
      expect(
        await digester.digest(chunk: [ChatMessage.user('新的一句')]),
        isNull,
      );
    });
  });
}
