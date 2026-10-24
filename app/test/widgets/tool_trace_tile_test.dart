import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/models/chat_item.dart';
import 'package:niuwa_ai/services/fs/file_access.dart';
import 'package:niuwa_ai/services/fs/local_file_backups.dart';
import 'package:niuwa_ai/services/n1_runtime.dart';
import 'package:niuwa_ai/theme.dart';
import 'package:niuwa_ai/widgets/tool_trace_tile.dart';

import '../support/fake_code_runner.dart';

/// 一次已经跑完的工具调用。
ToolTrace doneTrace(
  String name,
  Map<String, Object?> args, {
  String result = 'ok',
  Duration duration = const Duration(milliseconds: 120),
}) {
  final call = ToolCall(id: 'c1', name: name, arguments: args);
  return ToolTrace(call)
    ..finish(
      ToolInvocation(
        call: call,
        result: ToolResult.ok(result),
        duration: duration,
      ),
    );
}

Future<void> pumpTile(WidgetTester tester, ToolTrace trace) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(body: Center(child: ToolTraceTile(trace: trace))),
  ),
);

void main() {
  group('中英文对账', () {
    /// 这台设备上**可能注册进来**的所有工具名。
    ///
    /// 三个来源合起来才是全集：常驻的、浏览器的、代码的、文件的。
    /// 少算一路的话对账会漏——比如只捞常驻的，忘了 `run_code`，
    /// 而它恰恰是这次新加的那批里最容易漏的一行。
    List<String> allToolNames() {
      final fs = FileAccess(
        paths: PathResolver(home: r'C:\Users\test', isWindows: true),
        policy: FilePolicy.standard(
          environment: const {'SystemRoot': r'C:\Windows'},
          isWindows: true,
        ),
        backups: LocalFileBackupStore(
          dir: Directory('${Directory.systemTemp.path}/n1-tile-label-check'),
        ),
      );

      return [
        ...N1Runtime.alwaysOnTools().map((t) => t.name),
        ...browserTools(available: true).map((t) => t.name),
        ...codeTools(runner: FakeCodeRunner()).map((t) => t.name),
        ...fileTools(
          available: true,
          paths: fs.paths,
          policy: fs.policy,
          backups: fs.backups,
        ).map((t) => t.name),
        // 子代理工具不在上面任何一批里：它要用**当前会话**的模型客户端，
        // 只能在 `N1Runtime.newSession` 建好 llm 之后注册，这里造不出来。
        // 名字是常量，直接拿。
        RunSubagentTool.toolName,
      ];
    }

    test('注册表里每个工具都得有中文名', () {
      final names = allToolNames();
      // 先钉住这一趟真的捞到东西了，否则下面那个循环在空表上永远绿。
      expect(names, contains('run_code'));
      expect(names, contains('write_file'));

      final missing = names
          .where((n) => !ToolTraceTile.labels.containsKey(n))
          .toList();

      expect(
        missing,
        isEmpty,
        reason: '这几个工具在界面上会直接把英文名显示出来：$missing',
      );
    });

    test('表里也不该留着已经不存在的工具', () {
      // 反方向。留着一条死记录不会出错，但它说明有个工具改名了——而改名
      // 那一刻界面上正显示着英文名，只是没人看出来。
      final names = allToolNames().toSet();
      final stale = ToolTraceTile.labels.keys
          .where((n) => !names.contains(n))
          .toList();

      expect(stale, isEmpty, reason: '这些名字已经不对应任何工具了：$stale');
    });

    test('认不出来的名字原样还回去，不显示"未知工具"', () {
      // 英文名虽然不像话，至少能拿去搜；"未知工具"什么信息都没有。
      expect(ToolTraceTile.labelFor('some_future_tool'), 'some_future_tool');
      expect(ToolTraceTile.labelFor('run_code'), '跑代码');
    });
  });

  group('折叠行', () {
    testWidgets('显示中文名和命令预览', (tester) async {
      await pumpTile(
        tester,
        doneTrace('run_command', {'command': 'python sum.py'}),
      );

      expect(find.text('跑命令'), findsOneWidget);
      expect(find.text('python sum.py'), findsOneWidget);
    });

    testWidgets('预览里的换行和连续空格被压平', (tester) async {
      // 折叠行是一行文字，命令里带换行（多行脚本）会把这一行撑成两行，
      // 整条时间线的行距就乱了。
      await pumpTile(
        tester,
        doneTrace('run_command', {'command': 'python -c "\n  print(1)\n\n\nprint(2)"'}),
      );

      expect(
        find.text('python -c " print(1) print(2)"'),
        findsOneWidget,
      );
    });

    testWidgets('跑代码给的是源码预览——不然它和跑命令长得一模一样', (tester) async {
      await pumpTile(tester, doneTrace('run_code', {'source': 'print(1+1)', 'language': 'python'}));

      expect(find.text('跑代码'), findsOneWidget);
      expect(find.text('print(1+1)'), findsOneWidget);
    });

    testWidgets('没有可预览的字段就空着，不显示省略号占位', (tester) async {
      await pumpTile(tester, doneTrace('get_time', const {}));

      expect(find.text('查看时间'), findsOneWidget);
      expect(find.textContaining('…'), findsNothing);
      expect(find.textContaining('...'), findsNothing);
    });

    testWidgets('还在跑：显示"正在…"，点不开', (tester) async {
      final call = ToolCall(
        id: 'c2',
        name: 'run_command',
        arguments: const {'command': 'sleep 1'},
      );
      await pumpTile(tester, ToolTrace(call));

      expect(find.text('正在跑命令'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('展开', () {
    testWidgets('折叠时不显示结果，点一下才出来', (tester) async {
      await pumpTile(
        tester,
        doneTrace('run_command', {'command': 'echo hi'}, result: 'hi\n5050'),
      );

      expect(find.text('hi\n5050'), findsNothing);

      await tester.tap(find.text('跑命令'));
      await tester.pumpAndSettle();

      expect(find.text('hi\n5050'), findsOneWidget);
    });

    testWidgets('结果框会限高并内部滚动，长输出不把对话顶走', (tester) async {
      // 读一个大文件或者跑一段打印很多的代码，这一条消息能比整个屏幕还高，
      // 往上翻对话要滑半天。限高是 320，内部滚动。
      final long = List.generate(200, (i) => 'line $i').join('\n');
      await pumpTile(tester, doneTrace('read_file', {'path': r'C:\a.txt'}, result: long));

      await tester.tap(find.text('读文件'));
      await tester.pumpAndSettle();

      final scroller = find.ancestor(
        of: find.byType(SelectableText),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scroller, findsOneWidget);

      // 关键不是"有个滚动视图"，而是**渲染出来真的被夹住了**。
      // 光断言"存在一个限高 320 的 ConstrainedBox"是不够的——外面少一层
      // 约束，那个盒子在无限高里就照着内容长，测试照样绿。
      // 200 行内容在 800×600 的测试屏上不受限的话远超 320。
      expect(tester.getSize(scroller).height, lessThanOrEqualTo(320));
      expect(
        tester.widget<SingleChildScrollView>(scroller).scrollDirection,
        Axis.vertical,
      );
    });

    testWidgets('结果可选中，并且能一键复制', (tester) async {
      final copied = <String>[];
      // 测试环境里平台通道没接，`Clipboard.setData` 会抛 MissingPluginException。
      // 装一个假的处理器，顺便把"到底复制了什么"记下来——只断言"没报错"
      // 的话，复制成别的东西照样绿。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpTile(
        tester,
        doneTrace('run_command', {'command': 'echo hi'}, result: '5050'),
      );
      await tester.tap(find.text('跑命令'));
      await tester.pumpAndSettle();

      final selectable = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(selectable.data, '5050');

      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();

      expect(copied, ['5050']);
      expect(find.text('复制好了'), findsOneWidget);
    });

    testWidgets('失败的调用：图标变危字色，结果照样能展开', (tester) async {
      final call = ToolCall(
        id: 'c3',
        name: 'run_command',
        arguments: const {'command': 'false'},
      );
      final trace = ToolTrace(call)
        ..finish(
          ToolInvocation(
            call: call,
            result: ToolResult.fail('退出码 1'),
            duration: const Duration(milliseconds: 30),
          ),
        );

      await pumpTile(tester, trace);

      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      await tester.tap(find.text('跑命令'));
      await tester.pumpAndSettle();
      expect(find.text('退出码 1'), findsOneWidget);
    });

    testWidgets('成功但一个字都没输出：说明一句，且不给复制按钮', (tester) async {
      // `mkdir`、`cd` 这类命令成功且不打印任何东西，很常见。
      //
      // 原来的兜底写的是 `t.result?.content ?? '(没有返回内容)'`，那个分支
      // **永远走不到**——能展开的前提是 `done`，而 `done` 的定义就是
      // `result != null`。于是真出现的是一只有「复制」按钮的空框。
      final call = ToolCall(
        id: 'c4',
        name: 'run_command',
        arguments: const {'command': 'mkdir foo'},
      );
      final trace = ToolTrace(call)
        ..finish(
          ToolInvocation(
            call: call,
            result: const ToolResult(ok: true, content: ''),
            duration: const Duration(milliseconds: 5),
          ),
        );

      await pumpTile(tester, trace);
      await tester.tap(find.text('跑命令'));
      await tester.pumpAndSettle();

      expect(find.text('(它没有输出)'), findsOneWidget);
      expect(find.text('复制'), findsNothing, reason: '复制一句"它没有输出"没有用处');
    });

    testWidgets('只有空白的结果也算空——全换行在框里就是一片白', (tester) async {
      final call = ToolCall(
        id: 'c5',
        name: 'run_command',
        arguments: const {'command': 'echo'},
      );
      final trace = ToolTrace(call)
        ..finish(
          ToolInvocation(
            call: call,
            result: const ToolResult(ok: true, content: '  \n\n  '),
            duration: const Duration(milliseconds: 5),
          ),
        );

      await pumpTile(tester, trace);
      await tester.tap(find.text('跑命令'));
      await tester.pumpAndSettle();

      expect(find.text('(它没有输出)'), findsOneWidget);
    });
  });
}
