import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/theme.dart';
import 'package:niuwa_ai/widgets/tool_approval_dialog.dart';

/// 「这个操作要不要做」那个弹窗。
///
/// 这里只钉两件事，但两件都是**安全设计的一部分**，不是排版：
///
///   1. 显示的是**原样字符串**，不是摘要。危险命令判定只是一份启发式黑名单，
///      挡不住混淆和拼接；真正拦得住的是人看一眼原文。要是为了"好看"把
///      `del /s /q D:\重要资料` 缩成"删除操作"，唯一有效的那道关就成走过场了。
///   2. **关掉一律当"不要"**。含糊的关闭必须落在安全的那一边。
void main() {
  ToolApprovalRequest req(
    String tool,
    Map<String, Object?> input, {
    String reason = '这条命令会删东西，我先问一下。',
  }) => ToolApprovalRequest(tool: tool, input: input, reason: reason);

  /// 弹出对话框，**保持开着**，把"读结果"的闭包还回来。
  ///
  /// 不能写成一个"弹出来、点掉、返回值"的函数：断言原文的那几条**必须在
  /// 弹窗还开着的时候看**，点掉之后树里就没有那几个控件了。
  Future<Future<bool?> Function()> pumpDialog(
    WidgetTester tester,
    ToolApprovalRequest request,
  ) async {
    bool? result;
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => ToolApprovalDialog(request: request),
                  );
                  closed = true;
                },
                child: const Text('开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();
    expect(find.byType(ToolApprovalDialog), findsOneWidget);

    return () {
      // 不给这个断言的话，一个"点了没反应"的弹窗会让读到的 null 看起来
      // 像"用户把它关了"——两种情况的处置完全不一样，不能混起来。
      expect(closed, isTrue, reason: '点了按钮弹窗没关');
      return Future.value(result);
    };
  }

  group('要显示哪段文本', () {
    test('命令优先——那是最能说明它在干什么的东西', () {
      expect(
        ToolApprovalDialog.previewOf(
          req('run_command', {'command': 'del /s /q D:\\重要资料', 'cwd': r'D:\'}),
        ),
        'del /s /q D:\\重要资料',
      );
    });

    test('没给命令就退到源码', () {
      expect(
        ToolApprovalDialog.previewOf(
          req('run_code', {'source': 'import shutil', 'language': 'python'}),
        ),
        'import shutil',
      );
    });

    test('路径和网址也认', () {
      expect(
        ToolApprovalDialog.previewOf(req('write_file', {'path': r'C:\a\b.py'})),
        r'C:\a\b.py',
      );
      expect(
        ToolApprovalDialog.previewOf(req('http_fetch', {'url': 'https://a.com'})),
        'https://a.com',
      );
    });

    test('全是空串就往下找，不拿一个空串交差', () {
      expect(
        ToolApprovalDialog.previewOf(
          req('run_command', {'command': '   ', 'source': 'print(1)'}),
        ),
        'print(1)',
      );
    });

    test('一个都认不出来：把整张参数表铺出来，绝不给空白', () {
      // 挑不到主字段只说明这是个新工具。弹一个只有"检测到危险操作"几个字的窗
      // 是最坏的选项——用户没有任何判断依据，只能瞎点。
      final shown = ToolApprovalDialog.previewOf(
        req('future_tool', {'weird': 'x', 'n': 3}),
      );

      expect(shown, contains('"weird": "x"'));
      expect(shown, contains('"n": 3'));
    });

    test('参数表一个键都没有也还有东西可看', () {
      expect(ToolApprovalDialog.previewOf(req('run_command', const {})), '{}');
    });
  });

  group('弹窗', () {
    testWidgets('标题是中文工具名问句，正文有理由和原文', (tester) async {
      const command = 'del /s /q D:\\重要资料';
      await pumpDialog(tester, req('run_command', const {'command': command}));

      expect(find.text('要我跑命令吗？'), findsOneWidget);
      expect(find.text('这条命令会删东西，我先问一下。'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        command,
      );
    });

    testWidgets('原文**一字不改**：不 trim、不合并空白、不折行', (tester) async {
      // 这条是本文件存在的理由。"显示原样命令"听着像句废话，但界面上顺手
      // 做点"美观处理"太容易了——而命令里一个字符的差别就是另一回事
      // （`del /s` 和 `del /s /q` 之间差着几十个确认框）。
      const raw = '  del /s /q "D:\\我的 文档"\r\n&& rd /s /q D:\\tmp  ';
      await pumpDialog(tester, req('run_command', const {'command': raw}));

      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        raw,
      );
    });

    testWidgets('说清楚"这是原话"，并且拒绝之后不会被换个说法再问一遍', (tester) async {
      await pumpDialog(tester, req('run_command', const {'command': 'rd /s /q D:\\x'}));

      expect(
        find.text('上面是原话，没有省略。看着不对就点「不要」——它不会换个说法再试。'),
        findsOneWidget,
      );
    });

    testWidgets('点「不要」→ false，「允许」→ true', (tester) async {
      var read = await pumpDialog(
        tester,
        req('run_command', const {'command': 'del a.txt'}),
      );
      await tester.tap(find.text('不要'));
      await tester.pumpAndSettle();
      expect(await read(), isFalse);

      read = await pumpDialog(
        tester,
        req('run_command', const {'command': 'del a.txt'}),
      );
      await tester.tap(find.text('允许'));
      await tester.pumpAndSettle();
      expect(await read(), isTrue);
    });

    testWidgets('认不出的工具名：标题退回原名，照样能点「不要」', (tester) async {
      // 新工具还没来得及往 `ToolTraceTile.labels` 里补中文时的样子。
      // 英文名不像话，但比弹一个看不出是干什么的窗强。
      var read = await pumpDialog(
        tester,
        req('future_tool', const {'path': r'D:\x.txt'}),
      );
      expect(find.text('要我future_tool吗？'), findsOneWidget);

      await tester.tap(find.text('不要'));
      await tester.pumpAndSettle();
      expect(await read(), isFalse);
    });
  });

  // 2026-10-17 真机黑屏的回归测试。
  //
  // 现场：点「允许」之后整个窗口变黑，进程还活着（审计日志里命令照常执行）。
  // errors.log 里是 `Bad state: No element`，栈顶停在
  // `chat_page.dart:276` 那句自动关窗的 pop 上。
  //
  // 原因不是引擎，是**多 pop 了一次**：点按钮时弹窗自己已经在退场动画里
  // （不再是栈顶、也不再是 present），此时"等待已空"的重建又安排了一次 pop，
  // 弹掉的是底下的聊天页。导航栈空了，窗口就只剩一片黑。
  group('等待被别处收掉时的自动关窗', () {
    Future<void> pumpApprovalWithAutoClose(
      WidgetTester tester,
      ValueNotifier<bool> resolved, {
      required bool buttonAlsoPops,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('聊天页还在'),
                    TextButton(
                      onPressed: () async {
                        await showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder: (ctx) => ValueListenableBuilder<bool>(
                            valueListenable: resolved,
                            builder: (ctx, done, _) {
                              if (done) {
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => closeApprovalDialogIfCurrent(ctx),
                                );
                              }
                              return AlertDialog(
                                content: const Text('要我跑命令吗？'),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      if (buttonAlsoPops) Navigator.pop(ctx);
                                      resolved.value = true;
                                    },
                                    child: const Text('允许'),
                                  ),
                                ],
                              );
                            },
                          ),
                        );
                      },
                      child: const Text('开'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('开'));
      await tester.pumpAndSettle();
    }

    testWidgets('用户点了「允许」之后，自动关窗不能再 pop 一次', (tester) async {
      final resolved = ValueNotifier<bool>(false);
      await pumpApprovalWithAutoClose(tester, resolved, buttonAlsoPops: true);

      await tester.tap(find.text('允许'));
      await tester.pumpAndSettle();

      expect(find.text('聊天页还在'), findsOneWidget,
          reason: '底下的页面被弹掉了——真机上这就是一块黑窗口');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      resolved.dispose();
    });

    testWidgets('等待被超时收掉时，弹窗还开着，自动关窗要真的关上', (tester) async {
      final resolved = ValueNotifier<bool>(false);
      await pumpApprovalWithAutoClose(tester, resolved, buttonAlsoPops: false);
      expect(find.text('要我跑命令吗？'), findsOneWidget);

      // 等价于 provider 那边超时把 pendingApproval 清空。
      resolved.value = true;
      await tester.pumpAndSettle();

      expect(find.text('要我跑命令吗？'), findsNothing);
      expect(find.text('聊天页还在'), findsOneWidget, reason: '关弹窗不该伤到下面的页面');

      await tester.pumpWidget(const SizedBox());
      resolved.dispose();
    });
  });
}
