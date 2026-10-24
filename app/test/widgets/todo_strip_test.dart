import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/theme.dart';
import 'package:niuwa_ai/widgets/todo_strip.dart';

Future<void> pumpStrip(WidgetTester tester, List<TodoItem> items) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: Center(child: TodoStrip(items: items)),
        ),
      ),
    );

const _items = [
  TodoItem(content: '读现有代码', status: TodoStatus.completed),
  TodoItem(content: '改 agent loop', status: TodoStatus.inProgress),
  TodoItem(content: '跑测试', status: TodoStatus.pending),
];

void main() {
  testWidgets('没有清单时什么都不占', (tester) async {
    await pumpStrip(tester, const []);

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('收起时显示进度和当前那一步', (tester) async {
    await pumpStrip(tester, _items);

    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('改 agent loop'), findsOneWidget);
    // 其它步骤还没展开，不该出现。
    expect(find.text('跑测试'), findsNothing);
  });

  testWidgets('点一下展开全部步骤', (tester) async {
    await pumpStrip(tester, _items);
    await tester.tap(find.text('改 agent loop'));
    await tester.pumpAndSettle();

    expect(find.text('读现有代码'), findsOneWidget);
    expect(find.text('跑测试'), findsOneWidget);
  });

  testWidgets('全部做完时说的是"全部做完了"，不是卡在最后一条', (tester) async {
    await pumpStrip(tester, const [
      TodoItem(content: 'a', status: TodoStatus.completed),
      TodoItem(content: 'b', status: TodoStatus.completed),
    ]);

    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('全部做完了'), findsOneWidget);
  });
}
