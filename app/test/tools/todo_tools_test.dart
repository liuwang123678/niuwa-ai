import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

Future<ToolResult> write(Map<String, Object?> input, {ToolContext? ctx}) =>
    const TodoWriteTool().call(input, ctx ?? testContext());

List<Map<String, Object?>> _list(List<(String, String)> items) => [
  for (final (content, status) in items) {'content': content, 'status': status},
];

void main() {
  test('写一份清单，回显进度和当前做的那条', () async {
    final ctx = testContext();

    final result = await write(
      {
        'todos': _list([
          ('读一下现有代码', 'completed'),
          ('改 agent loop', 'in_progress'),
          ('跑测试', 'pending'),
        ]),
      },
      ctx: ctx,
    );

    expect(result.ok, isTrue);
    expect(result.content, contains('1/3 完成'));
    expect(result.content, contains('▶ 改 agent loop'));
    expect(result.content, contains('正在做'));
    expect(ctx.todos.items.length, 3);
  });

  test('再发一次是整份覆盖，不是往里追加', () async {
    final ctx = testContext();

    await write(
      {
        'todos': _list([('旧的一步', 'pending'), ('旧的二步', 'pending')]),
      },
      ctx: ctx,
    );
    await write(
      {
        'todos': _list([('新的一步', 'in_progress')]),
      },
      ctx: ctx,
    );

    expect(ctx.todos.items.map((i) => i.content), ['新的一步']);
  });

  test('空数组等于清空', () async {
    final ctx = testContext();
    await write(
      {'todos': _list([('a', 'pending')])},
      ctx: ctx,
    );

    final result = await write({'todos': <Object?>[]}, ctx: ctx);

    expect(result.content, contains('清空'));
    expect(ctx.todos.isEmpty, isTrue);
  });

  group('拒绝坏清单，而且原样不动', () {
    test('两条 in_progress', () async {
      final ctx = testContext();
      await write(
        {'todos': _list([('保住这条', 'pending')])},
        ctx: ctx,
      );

      final result = await write(
        {
          'todos': _list([('a', 'in_progress'), ('b', 'in_progress')]),
        },
        ctx: ctx,
      );

      expect(result.ok, isFalse);
      expect(result.content, contains('同时只能有 1 条'));
      expect(ctx.todos.items.single.content, '保住这条');
    });

    test('超过上限', () async {
      final result = await write({
        'todos': [
          for (var i = 0; i < 31; i++) {'content': '第 $i 步', 'status': 'pending'},
        ],
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('最多 30 条'));
    });

    test('认不出的状态，把原话指出来', () async {
      final result = await write({
        'todos': _list([('a', 'doing')]),
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('doing'));
    });

    test('空内容', () async {
      final result = await write({
        'todos': _list([('   ', 'pending')]),
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('content 是空的'));
    });

    test('todos 根本不是数组', () async {
      final result = await write({'todos': '做三件事'});

      expect(result.ok, isFalse);
      expect(result.content, contains('数组'));
    });
  });

  test('清单跟着会话走：新 context 从空开始', () async {
    final a = testContext();
    await write(
      {'todos': _list([('a', 'pending')])},
      ctx: a,
    );

    final b = testContext();
    expect(b.todos.isEmpty, isTrue);
  });
}
