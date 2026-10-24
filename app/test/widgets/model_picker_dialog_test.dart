import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/theme.dart';
import 'package:niuwa_ai/widgets/model_picker_dialog.dart';

/// 盯挑模型那个弹窗。它的价值只有两条：
///
/// 1. 长清单要能**筛**（硅基流动那种几百条，靠眼睛找还不如去官网复制）；
/// 2. 挑完给回来的必须是**那个名字本身**——上层拿它填进可编辑的输入框，
///    所以这里不能自作主张做校验、也不能只回一个下标。
/// 挂一个按钮，点开弹窗，把弹窗的返回值收集出来。
///
/// 用 `showDialog` 而不是直接摆 `ModelPickerDialog`，是因为"挑完回什么、
/// 取消回什么"正是这个组件契约里最容易写错的一半——直接摆成页面的话
/// `Navigator.pop` 那两句根本没被执行到。
Future<String? Function()> openPicker(
  WidgetTester tester, {
  required List<String> models,
  String current = '',
}) async {
  String? picked;

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showDialog<String>(
                context: context,
                builder: (_) =>
                    ModelPickerDialog(models: models, current: current),
              );
            },
            child: const Text('开'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('开'));
  await tester.pumpAndSettle();
  return () => picked;
}

void main() {
  testWidgets('清单原样列出来，几条就是几条', (tester) async {
    final read = await openPicker(
      tester,
      models: const ['kimi-k3', 'kimi-k2.6', 'kimi-k2.7-code'],
    );

    expect(find.text('选一个模型（共 3 个）'), findsOneWidget);
    for (final m in const ['kimi-k3', 'kimi-k2.6', 'kimi-k2.7-code']) {
      expect(find.text(m), findsOneWidget);
    }
    expect(read(), isNull, reason: '还没挑呢');
  });

  testWidgets('点一下回的是那个名字本身', (tester) async {
    final read = await openPicker(
      tester,
      models: const ['kimi-k3', 'glm-5.3'],
      current: 'glm-5.3',
    );

    await tester.tap(find.text('kimi-k3'));
    await tester.pumpAndSettle();

    expect(read(), 'kimi-k3');
    expect(find.text('kimi-k3'), findsNothing, reason: '选完弹窗该关掉了');
  });

  testWidgets('取消回 null，一个都不选', (tester) async {
    final read = await openPicker(tester, models: const ['a']);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(read(), isNull);
  });

  group('筛选', () {
    Future<void> pumpWithFilter(WidgetTester tester, List<String> models) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: ModelPickerDialog(models: models, current: ''),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('打进去几个字就只剩匹配的', (tester) async {
      await pumpWithFilter(tester, const ['kimi-k3', 'glm-5.3', 'qwen3.8-flash']);

      await tester.enterText(find.byType(TextField), 'kimi');
      await tester.pumpAndSettle();

      expect(find.text('kimi-k3'), findsOneWidget);
      expect(find.text('glm-5.3'), findsNothing);
      expect(find.text('qwen3.8-flash'), findsNothing);
    });

    testWidgets('大小写不敏感——用户不会照着原名的大小写敲', (tester) async {
      await pumpWithFilter(tester, const ['Qwen/Qwen3-8B']);

      await tester.enterText(find.byType(TextField), 'qwen/qwen3');
      await tester.pumpAndSettle();

      expect(find.text('Qwen/Qwen3-8B'), findsOneWidget);
    });

    testWidgets('筛不到就说筛不到，不是一片空白', (tester) async {
      // 白屏看起来像"弹窗坏了"。说一句话，用户才知道是筛没了，
      // 把筛选框清掉就回来。
      await pumpWithFilter(tester, const ['kimi-k3']);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();

      expect(find.text('没有匹配的。'), findsOneWidget);
    });

    testWidgets('清掉筛选，整份清单回来', (tester) async {
      await pumpWithFilter(tester, const ['kimi-k3', 'glm-5.3']);

      await tester.enterText(find.byType(TextField), 'kimi');
      await tester.pumpAndSettle();
      expect(find.text('glm-5.3'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();

      expect(find.text('kimi-k3'), findsOneWidget);
      expect(find.text('glm-5.3'), findsOneWidget);
    });

    testWidgets('标题里的总数是**清单**的条数，不跟着筛选变', (tester) async {
      // 标题写的是"共 N 个"，跟着筛选变会让人以为平台只给了这么几个。
      await pumpWithFilter(tester, const ['kimi-k3', 'glm-5.3']);

      await tester.enterText(find.byType(TextField), 'kimi');
      await tester.pumpAndSettle();

      expect(find.text('选一个模型（共 2 个）'), findsOneWidget);
    });
  });

  testWidgets('那句"我们没验证过"必须一直在', (tester) async {
    // 它不是装饰。它是这个弹窗和"锁死的下拉框"之间的区别：
    // 用户看见这句话，才知道清单只是参考、挑完还能自己改。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: ModelPickerDialog(models: const ['a'], current: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('我们没验证过'), findsOneWidget);
  });
}
