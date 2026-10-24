import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

final _system = ChatMessage.system('你是 N1。');

ChatMessage _call(String id) => ChatMessage.assistant(
  '',
  toolCalls: [ToolCall(id: id, name: 'read_file', arguments: const {})],
);

ChatMessage _result(String id, String content) =>
    ChatMessage.toolResult(toolCallId: id, toolName: 'read_file', content: content);

/// 造一段"用户发话 → 调工具 → 拿到一大坨结果"。
List<ChatMessage> _round(int i, {int contentChars = 10000}) => [
  ChatMessage.user('第 $i 件事'),
  _call('call_$i'),
  _result('call_$i', 'x' * contentChars),
];

void main() {
  group('估算', () {
    test('越长越多，空消息也有最小开销', () {
      final short = ChatMessage.user('你好');
      final long = ChatMessage.user('你' * 1000);

      expect(AgentLoop.estimateTokens([long]), greaterThan(AgentLoop.estimateTokens([short])));
      expect(AgentLoop.estimateTokens([short]), greaterThan(0));
    });

    test('图片按张算，不按 base64 长度算', () {
      final noImage = ChatMessage.user('看图');
      final withImage = ChatMessage.user(
        '看图',
        images: const [ImagePart(base64Data: 'AAAA')],
      );

      expect(
        AgentLoop.estimateTokens([withImage]) - AgentLoop.estimateTokens([noImage]),
        greaterThanOrEqualTo(1600),
      );
    });
  });

  group('预算内不动', () {
    test('没超预算时原样返回，连拷贝都不做', () {
      final messages = [_system, ..._round(1, contentChars: 100)];

      final fitted = AgentLoop.fitToBudget(messages, budget: 100000);

      expect(identical(fitted, messages), isTrue);
    });
  });

  group('第一步：压缩老的工具结果', () {
    test('只换正文，一条消息都不删', () {
      final messages = [
        _system,
        ChatMessage.user('帮我读几个文件'),
        for (var i = 0; i < 5; i++) ...[_call('c$i'), _result('c$i', 'x' * 10000)],
      ];

      final fitted = AgentLoop.fitToBudget(messages, budget: 13000, keepRecent: 2);

      expect(fitted.length, messages.length, reason: '结构不能拆');

      // 最近两条（最后那次工具往返）原样留着。
      expect(fitted[fitted.length - 1].content.length, 10000);
      expect(fitted[fitted.length - 2].toolCalls, isNotNull);

      // 老的正文被换成一句说明，但 tool_call_id 还在——协议要求它必须能对上爸爸。
      // 下标 3：0=system、1=user，之后每两条是一组 assistant+tool。
      final old = fitted[3];
      expect(old.role, Role.tool);
      expect(old.content, contains('略去'));
      expect(old.content.length, lessThan(200));
      expect(old.toolCallId, 'c0');
    });

    test('压缩后总量真的降下来了', () {
      final messages = [
        _system,
        ChatMessage.user('读文件'),
        for (var i = 0; i < 5; i++) ...[_call('c$i'), _result('c$i', 'x' * 10000)],
      ];
      final before = AgentLoop.estimateTokens(messages);

      final fitted = AgentLoop.fitToBudget(messages, budget: 13000, keepRecent: 2);

      expect(AgentLoop.estimateTokens(fitted), lessThan(before ~/ 2));
    });
  });

  group('第二步：整段丢', () {
    test('从最老的丢，system 永远留着，剩下的第一句是用户发言', () {
      final messages = [
        _system,
        for (var i = 0; i < 6; i++)
          ...[
            ChatMessage.user('第 $i 件事'),
            ChatMessage.assistant('答 $i：${'很长的回答' * 500}'),
          ],
        ChatMessage.user('最后一句'),
      ];

      final fitted = AgentLoop.fitToBudget(messages, budget: 2000, keepRecent: 0);

      expect(fitted.first.role, Role.system);
      expect(fitted[1].role, Role.user, reason: '切点必须落在用户发言上');
      expect(fitted.last.content, '最后一句');
      expect(fitted.length, lessThan(messages.length));
    });

    test('再小也不会把最后一段（用户这次说的话）丢掉', () {
      final messages = [
        _system,
        ChatMessage.user('很早以前'),
        ChatMessage.assistant('x' * 100000),
        ChatMessage.user('现在这句'),
      ];

      final fitted = AgentLoop.fitToBudget(messages, budget: 10, keepRecent: 0);

      expect(fitted.last.content, '现在这句');
      expect(fitted.first.role, Role.system);
    });

    test('丢完仍然没有孤儿工具结果', () {
      final messages = [
        _system,
        for (var i = 0; i < 8; i++) ..._round(i, contentChars: 5000),
      ];

      final fitted = AgentLoop.fitToBudget(messages, budget: 3000, keepRecent: 0);
      final sanitized = AgentLoop.sanitizeHistory(fitted);

      // sanitize 一条都不该再丢：说明 fitToBudget 切出来的历史本身就是合法的。
      expect(sanitized.length, fitted.length);
    });
  });

  group('接进 AgentLoop', () {
    test('真正发出去的上下文比历史小，而且 system 和这次的话都在', () async {
      final llm = FakeLlmClient([
        [const TextChunk('好'), const DoneChunk('stop')],
      ]);

      final history = <ChatMessage>[
        for (var i = 0; i < 24; i++) ..._round(i, contentChars: 4000),
      ];

      final events = await AgentLoop(
        llm: llm,
        tools: ToolRegistry(),
        context: testContext(),
        promptBuilder: testPromptBuilder(),
        maxInputTokens: 6000,
      ).run(history: history, input: ChatMessage.user('这次的问题')).toList();

      final sent = llm.lastMessages;
      expect(sent.length, lessThan(history.length + 2));
      expect(sent.first.role, Role.system);
      // 末尾会拼一行"现在"（见 `AgentLoop._withClock`），用户原话在它后面。
      expect(sent.last.content, endsWith('\n这次的问题'));

      // 裁了就说一声。不然模型"不记得了"看起来像 bug。
      final trimmed = events.whereType<ContextTrimmed>().single;
      expect(trimmed.droppedMessages, greaterThan(0));
      expect(trimmed.approxTokens, lessThanOrEqualTo(6000));
    });

    test('预算宽裕时一个字节都不动', () async {
      final llm = FakeLlmClient([
        [const TextChunk('好'), const DoneChunk('stop')],
      ]);
      final history = _round(1, contentChars: 100);

      final events = await AgentLoop(
        llm: llm,
        tools: ToolRegistry(),
        context: testContext(),
        promptBuilder: testPromptBuilder(),
        maxInputTokens: 100000,
      ).run(history: history, input: ChatMessage.user('这次的问题')).toList();

      // system + 3 条历史 + 这次输入
      expect(llm.lastMessages.length, 5);
      expect(events.whereType<ContextTrimmed>(), isEmpty);
    });
  });
}
