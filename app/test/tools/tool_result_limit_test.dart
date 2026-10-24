import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 工具结果回喂给模型时的截断（工作强度里省 token 的那一项）。
///
/// 它值钱的地方不是"少发几个字"，是**agent 任务的输入是平方级涨的**：
/// 一条工具结果进了上下文，后面每一轮都要跟着重发。一条 5 万字的结果，
/// 在 20 回合的会话里就是 100 万字的输入。
void main() {
  group('ToolResult.limitedTo', () {
    test('没超就原样返回**同一个对象**，一个字都不动', () {
      const r = ToolResult.ok('短短的');
      expect(identical(r.limitedTo(100), r), isTrue);
    });

    test('刚好等于上限：不截', () {
      final r = ToolResult.ok('x' * 100);
      expect(identical(r.limitedTo(100), r), isTrue);
    });

    test('超了：留下前一段，并且**明说**截了', () {
      final r = ToolResult.ok('x' * 500);
      final capped = r.limitedTo(100);

      expect(capped.content, startsWith('x' * 100));
      expect(capped.content, contains('只回喂了前 100 字'));
      // 一共多少字也要报出来：模型据此才知道差多远，是该缩小范围还是
      // 干脆换个查法。
      expect(capped.content, contains('500 字'));
      expect(capped.content, contains('别原样重试'), reason: '得告诉它怎么拿全');
    });

    test('ok / meta 原样带过去，截断不改判定', () {
      // 截断只动正文。把 ok 弄丢了的话，一条成功的读文件会被重建历史认成
      // 失败（`ToolResult.fromModelText` 靠前缀认），痕迹上就一直是红的。
      final r = ToolResult(
        ok: false,
        content: '错误信息很长很长' * 30,
        meta: const {'exit_code': 2},
      );
      final capped = r.limitedTo(50);

      expect(capped.ok, isFalse);
      expect(capped.meta?['exit_code'], 2);
    });

    test('不从半个代理对中间切开', () {
      // emoji 在星平面，一个字符两个 UTF-16 码元。切出个落单的代理项，
      // 序列化成 JSON 时是非法字符，有些家直接回 400——而报错里一个字
      // 都不会提"是你截断截坏了"。
      final r = ToolResult.ok('👍' * 50); // 每个占 2 个码元
      final capped = r.limitedTo(11); // 正好落在第 6 个 emoji 的中间

      expect(capped.content, startsWith('👍' * 5));
      expect(capped.content, contains('只回喂了前 10 字'));
      // 正文里不该出现落单的代理码元。
      final body = capped.content.split('\n\n').first;
      for (var i = 0; i < body.length; i++) {
        final u = body.codeUnitAt(i);
        if (u >= 0xD800 && u <= 0xDBFF) {
          expect(i + 1 < body.length, isTrue, reason: '高位代理在末尾，落单了');
          final next = body.codeUnitAt(i + 1);
          expect(next >= 0xDC00 && next <= 0xDFFF, isTrue, reason: '高位代理后面不是低位');
        }
      }
    });

    test('limit 是 0 或者负数：当成"不限"，不是"清空"', () {
      // 一个配置项写成 0 只可能是写错了。按字面执行的话，模型收到的每条
      // 工具结果都是空的，而它会以为工具坏了。
      final r = ToolResult.ok('内容');
      expect(identical(r.limitedTo(0), r), isTrue);
      expect(identical(r.limitedTo(-5), r), isTrue);
    });
  });

  group('注册表那个收口处', () {
    test('默认不限——不设 resultChars 就是老行为', () async {
      final registry = ToolRegistry()..register(_BigTool());
      final inv = await registry.invoke(
        ToolCall(id: 'c1', name: 'big', arguments: const {}),
        testContext(),
      );

      expect(inv.result.content.length, 5000);
      expect(inv.result.content, isNot(contains('只回喂了')));
    });

    test('设了上限：所有工具的结果都从这儿过一道', () async {
      // 这一条钉的是"截断只写在一个地方"——放进各个工具里各截各的话，
      // 以后新加的工具有一个忘了截，症状只是账单悄悄涨。
      final registry = ToolRegistry()
        ..resultChars = 200
        ..register(_BigTool());

      final inv = await registry.invoke(
        ToolCall(id: 'c1', name: 'big', arguments: const {}),
        testContext(),
      );

      expect(inv.result.content, startsWith('x' * 200));
      expect(inv.result.content, contains('只回喂了前 200 字'));
    });

    test('失败结果也一样过——它也可能是长的', () async {
      final registry = ToolRegistry()
        ..resultChars = 50
        ..register(_BigTool(fail: true));

      final inv = await registry.invoke(
        ToolCall(id: 'c1', name: 'big', arguments: const {}),
        testContext(),
      );

      expect(inv.result.ok, isFalse);
      expect(inv.result.toModelText(), startsWith(ToolResult.failurePrefix));
      expect(inv.result.content, contains('只回喂了前 50 字'));
    });

    test('短结果不受影响：设了上限也不会平白多一句话', () async {
      final registry = ToolRegistry()
        ..resultChars = 200
        ..register(ProbeTool('echo'));

      final inv = await registry.invoke(
        ToolCall(id: 'c1', name: 'echo', arguments: const {}),
        testContext(),
      );

      expect(inv.result.content, isNot(contains('只回喂了')));
    });
  });
}

/// 回一大段内容。长度写死在 5000，方便断言"没截的时候是完整的"。
class _BigTool extends N1Tool {
  const _BigTool({this.fail = false});

  final bool fail;

  @override
  String get name => 'big';

  @override
  String get description => '回一大段内容';

  @override
  Map<String, Object?> get inputSchema => const {'type': 'object'};

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final content = 'x' * 5000;
    return fail ? ToolResult.fail(content) : ToolResult.ok(content);
  }
}
