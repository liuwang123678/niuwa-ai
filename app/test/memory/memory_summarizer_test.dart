import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 只回一段固定文本的假客户端。
class _ScriptedLlm implements LlmClient {
  _ScriptedLlm(this.reply, {this.throwOnStream = false});

  final String reply;
  final bool throwOnStream;
  final List<List<ChatMessage>> calls = [];

  @override
  String get model => 'fake';

  @override
  Stream<LlmChunk> stream(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
  }) async* {
    calls.add(messages);
    if (throwOnStream) throw StateError('网络断了');
    // 切成几段发，模拟真的流式，顺便验证拼接
    for (var i = 0; i < reply.length; i += 7) {
      yield TextChunk(
        reply.substring(i, i + 7 > reply.length ? reply.length : i + 7),
      );
    }
    yield const DoneChunk('stop');
  }
}

MemorySummarizer _summarizer(LlmClient llm, MemoryStore memory) =>
    MemorySummarizer(llm: llm, memory: memory);

List<ChatMessage> _chat(List<(Role, String)> pairs) => [
  for (final (role, text) in pairs)
    role == Role.user ? ChatMessage.user(text) : ChatMessage.assistant(text),
];

void main() {
  group('解析模型输出', () {
    test('正常的 JSON 数组', () {
      final items = MemorySummarizer.parseSummary(
        '[{"content":"用户养了一只猫叫团子","kind":"fact",'
        '"subject":"用户的猫","importance":4}]',
      );
      expect(items.single.content, '用户养了一只猫叫团子');
      expect(items.single.kind, 'fact');
      expect(items.single.importance, 4);
    });

    test('外面包了 ```json 围栏、前面还说了句废话，也能认', () {
      final items = MemorySummarizer.parseSummary(
        '好的，我整理如下：\n```json\n'
        '[{"content":"用户在准备考研","kind":"event"}]\n```',
      );
      expect(items.single.content, '用户在准备考研');
    });

    test('模型胡说八道时返回空，不往记忆里灌垃圾', () {
      expect(MemorySummarizer.parseSummary('我觉得这段对话没啥好记的。'), isEmpty);
      expect(MemorySummarizer.parseSummary('{"content":"不是数组"}'), isEmpty);
      expect(MemorySummarizer.parseSummary(''), isEmpty);
    });

    test('一次给太多只取前三条', () {
      final items = MemorySummarizer.parseSummary(
        '[{"content":"a","kind":"fact"},{"content":"b","kind":"fact"},'
        '{"content":"c","kind":"fact"},{"content":"d","kind":"fact"}]',
      );
      expect(items.map((e) => e.content), ['a', 'b', 'c']);
    });

    test('类别不认识、内容空的整条丢掉', () {
      final items = MemorySummarizer.parseSummary(
        '[{"content":"正常的一条","kind":"fact"},'
        '{"content":"类别瞎写","kind":"乱写的"},'
        '{"content":"   ","kind":"fact"}]',
      );
      expect(items.single.content, '正常的一条');
    });

    test('严重度越界会被夹回来', () {
      final items = MemorySummarizer.parseSummary(
        '[{"content":"x","kind":"fact","importance":99}]',
      );
      expect(items.single.importance, 5);
    });
  });

  group('整理对话', () {
    test('只留用户和助手说的话，工具结果不进摘要', () {
      final text = MemorySummarizer.buildTranscript([
        ChatMessage.user('我喜欢猫'),
        ChatMessage.assistant('记住了'),
        ChatMessage.toolResult(
          toolCallId: 't1',
          toolName: 'read_file',
          content: '一堆文件内容',
        ),
      ]);
      expect(text, contains('用户：我喜欢猫'));
      expect(text, contains('助手：记住了'));
      expect(text, isNot(contains('一堆文件内容')));
    });

    test('太长时保最近的一段，不是开头', () {
      final messages = <ChatMessage>[
        ChatMessage.user('很早以前说的话${'啊' * 3000}'),
        ChatMessage.user('最近说的话'),
      ];
      final text = MemorySummarizer.buildTranscript(messages);
      expect(text, contains('最近说的话'));
      expect(text.length, lessThanOrEqualTo(MemorySummarizer.maxTranscriptChars));
    });
  });

  group('摘要落库', () {
    test('把模型挑出来的几条存进记忆', () async {
      final memory = InMemoryMemoryStore();
      final llm = _ScriptedLlm(
        '[{"content":"用户养了一只猫叫团子","kind":"fact","subject":"用户的猫","importance":4}]',
      );

      final saved = await _summarizer(llm, memory).summarize(
        _chat([(Role.user, '我养了只猫叫团子'), (Role.assistant, '团子这名字可爱')]),
      );

      expect(saved, 1);
      final entry = (await memory.all()).single;
      expect(entry.content, '用户养了一只猫叫团子');
      expect(entry.subject, '用户的猫');
      expect(entry.importance, 4);
    });

    test('调模型时真的把对话发出去了', () async {
      final llm = _ScriptedLlm('[]');
      await _summarizer(llm, InMemoryMemoryStore()).summarize(
        _chat([(Role.user, '我下个月要去日本')]),
      );
      expect(llm.calls.single.last.content, contains('我下个月要去日本'));
    });

    test('模型挂了：返回 0，不抛', () async {
      final memory = InMemoryMemoryStore();
      final saved = await _summarizer(
        _ScriptedLlm('', throwOnStream: true),
        memory,
      ).summarize(_chat([(Role.user, '随便聊聊')]));

      expect(saved, 0);
      expect(await memory.count(), 0);
    });

    test('模型返回废话：一条都不存', () async {
      final memory = InMemoryMemoryStore();
      final saved = await _summarizer(
        _ScriptedLlm('这段对话没什么值得记的'),
        memory,
      ).summarize(_chat([(Role.user, '你好')]));

      expect(saved, 0);
      expect(await memory.count(), 0);
    });

    test('摘出来的内容和旧记忆重复时会合并，不会攒出第二条', () async {
      final memory = InMemoryMemoryStore();
      await memory.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '用户养了一只猫叫团子',
          subject: '用户的猫',
          now: 1000,
        ),
      );

      await _summarizer(
        _ScriptedLlm('[{"content":"用户养了一只猫叫团子。","kind":"fact",'
            '"subject":"用户的猫"}]'),
        memory,
      ).summarize(_chat([(Role.user, '团子今天又拆家了')]));

      expect(await memory.count(), 1);
    });

    test('没有对话内容时不请求模型', () async {
      final llm = _ScriptedLlm('[]');
      final saved = await _summarizer(llm, InMemoryMemoryStore()).summarize([]);
      expect(saved, 0);
      expect(llm.calls, isEmpty);
    });
  });

  group('什么时候摘要', () {
    /// 一直 tick 下去，返回第几轮做了摘要（从 1 开始数）。
    List<int> runsOver(int turns, [SummarySchedule? schedule]) {
      final s = schedule ?? SummarySchedule();
      return [
        for (var i = 1; i <= turns; i++)
          if (s.tick()) i,
      ];
    }

    test('刚开始聊不摘要——前九轮一次都不动', () {
      expect(runsOver(9), isEmpty);
    });

    test('第十轮做第一次', () {
      expect(runsOver(10), [10]);
    });

    test('之后每八轮一次，到三次封顶', () {
      // 10 → 18 → 26，第四次要到 34，但封顶了。
      expect(runsOver(100), [10, 18, 26]);
    });

    test('换了会话就重新数：聊满五十句后新开一个，不会第一句就摘要', () {
      final s = SummarySchedule();
      expect(runsOver(50, s), [10, 18, 26]);

      s.reset();
      expect(s.turns, 0);
      expect(s.runs, 0);

      for (var i = 0; i < 9; i++) {
        expect(s.tick(), isFalse, reason: '新会话第 ${i + 1} 轮不该摘要');
      }
      expect(s.tick(), isTrue, reason: '新会话的第十轮该摘要了');
    });
  });
}
