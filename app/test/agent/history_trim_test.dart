import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 按工作强度砍历史（`WorkLevel.historyMessages`）。
///
/// ⚠️ 这个函数有一个**只按字面实现就会踩的坑**：从中间硬切。切点后面往往紧跟
/// 一条 `tool` 结果，而它的"爸爸"——那条带 `tool_calls` 的 assistant——正好
/// 被切掉了。这种孤儿会被 `sanitizeHistory` 丢掉，于是**实际带的历史比设定的
/// 还少**，而且少得没规律。调旋钮的人会发现"调到 40 条怎么比 30 条记得还少"。
///
/// 所以这一组测试一边钉边界，一边钉"不许切出孤儿"。
ChatMessage u(String t) => ChatMessage.user(t);
ChatMessage a(String t) => ChatMessage.assistant(t);

/// 一轮带工具调用的往返：assistant 声明 + tool 结果。
List<ChatMessage> toolRound(String callId, {String name = 'probe'}) => [
  ChatMessage.assistant(
    '',
    toolCalls: [
      ToolCall(id: callId, name: name, arguments: const {}),
    ],
  ),
  ChatMessage.toolResult(
    toolCallId: callId,
    toolName: name,
    content: '结果',
  ),
];

void main() {
  group('不限', () {
    test('null 原样返回', () {
      final h = [u('1'), a('2'), u('3')];
      expect(identical(AgentLoop.trimHistory(h, null), h), isTrue);
    });

    test('0 和负数当成"不限"，不是"一条都不带"', () {
      // 说"带 0 条"的配置只可能是写错了。照字面执行的话，模型会凭空失忆，
      // 而界面上一切正常——最难查的那种。
      final h = [u('1'), a('2')];
      expect(AgentLoop.trimHistory(h, 0), h);
      expect(AgentLoop.trimHistory(h, -3), h);
    });

    test('不够长就原样返回（而不是切掉一条）', () {
      final h = [u('1'), a('2')];
      expect(AgentLoop.trimHistory(h, 10), h);
      expect(AgentLoop.trimHistory(h, 2), h);
    });
  });

  group('窗口落在用户身上', () {
    test('从切点往前找最近的一句用户输入', () {
      // 索引：0用户 1助手 2工具 3工具 4用户 5助手 6用户 7助手
      final h = [
        u('早'),
        a('早'),
        ...toolRound('c1'),
        u('中'),
        a('中'),
        u('晚'),
        a('晚'),
      ];
      // limit=3 → 起点落在索引 5（助手）。往前退到索引 4（用户"中"）。
      final out = AgentLoop.trimHistory(h, 3);
      expect(out.first.content, '中');
      expect(out.length, 4);
    });

    test('切点正好是用户输入：一步都不用退', () {
      final h = [u('1'), a('1'), u('2'), a('2')];
      final out = AgentLoop.trimHistory(h, 2);
      expect(out.map((m) => m.content), ['2', '2']);
    });

    test('前面一句用户输入都没有（比如历史从助手开始）：那就全带上', () {
      // 往前走找不到边界时，退到 0 是安全方向——多带点远比凭空失忆好。
      final h = [a('1'), a('2'), a('3')];
      expect(AgentLoop.trimHistory(h, 2), h);
    });
  });

  group('不许切出孤儿', () {
    test('切点落在一串工具结果中间时，整串一起带', () {
      // 这是这个函数存在的全部理由。切在工具结果中间 → 它的"爸爸"被切掉 →
      // `sanitizeHistory` 会把它丢掉 → 设定 3 条，实际拿到 1 条。
      //
      // 索引：0用户 1助手(声明c1,c2) 2工具 3工具 4用户 …
      final h = [
        u('帮我改一下'),
        ...toolRound('c1'),
        ...toolRound('c2'),
        u('改成红色的'),
        a('好'),
      ];

      // 从索引 2 切的话，第 2 条 tool 的声明（索引 1）就没了。
      final out = AgentLoop.trimHistory(h, 4);

      expect(out.first.role, Role.user, reason: '窗口必须落在用户输入上');
      // 拿 sanitizeHistory 过一遍，一条都不该被丢掉——真丢掉了就说明
      // 我们切出了孤儿。
      expect(AgentLoop.sanitizeHistory(out).length, out.length);
      expect(out.length, h.length, reason: '只能退到索引 0 那句用户输入');
    });

    test('切出来的东西一定能通过 sanitizeHistory——这是硬约束', () {
      final h = <ChatMessage>[
        u('1'),
        ...toolRound('c1'),
        u('2'),
        ...toolRound('c2'),
        ...toolRound('c3'),
        u('3'),
        a('完事'),
      ];

      for (var limit = 1; limit <= h.length; limit++) {
        final out = AgentLoop.trimHistory(h, limit);
        expect(
          AgentLoop.sanitizeHistory(out).length,
          out.length,
          reason: 'limit=$limit 时切出了孤儿',
        );
        expect(
          out.last.content,
          h.last.content,
          reason: 'limit=$limit 时把最近的弄丢了',
        );
      }
    });
  });

  group('和标准档对得上', () {
    test('标准档那一项是 null，所以这一步整个不做', () {
      // 钉住"标准＝旧行为"。哪天有人把标准档改成"带 200 条"，
      // 所有老用户升级完就开始悄悄忘事了。
      expect(WorkLevel.standard.historyMessages, isNull);

      final h = [for (var i = 0; i < 100; i++) u('$i')];
      expect(
        AgentLoop.trimHistory(h, WorkLevel.standard.historyMessages).length,
        100,
      );
    });

    test('省着用那一档确实会砍', () {
      final h = [for (var i = 0; i < 100; i++) u('$i')];
      final out = AgentLoop.trimHistory(h, WorkLevel.frugal.historyMessages);
      expect(out.length, WorkLevel.frugal.historyMessages);
      expect(out.last.content, '99', reason: '砍的是老的那一头');
    });
  });
}
