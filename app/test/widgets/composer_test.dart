import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/theme.dart';
import 'package:niuwa_ai/widgets/composer.dart';

/// 输入条的测试。
///
/// 重点只有一个：**回车在两种平台上必须是两种行为**。桌面端回车 = 发送，
/// 触屏端回车 = 换行。这条不是"顺手加的便利"，写反了的后果是用户在手机上
/// 打字时手一抖碰到回车，半句话就发出去了。
///
/// ⚠️ flutter_test 里 `defaultTargetPlatform` **默认是 android**，
/// 所以桌面那条分支不写 override 就永远测不到——它会一直"绿"，但是空绿。
void main() {
  /// 挂一个 Composer，返回收集到的发送内容。
  ///
  /// 文字、图片、文件分开收：`sent` 保持是 `List<String>`，这样下面那些
  /// `expect(sent, ['在吗'])` 一个字都不用动。
  Future<List<String>> pump(
    WidgetTester tester, {
    bool running = false,
    bool enabled = true,
    List<String>? stopCalls,
    List<List<ImagePart>>? sentImages,
    List<List<Attachment>>? sentFiles,
    Future<ImagePart?> Function()? onPickImage,
    Future<Attachment?> Function()? onPickFile,
    WorkLevel? workLevel,
    ValueChanged<WorkLevel>? onWorkLevelChanged,
    bool autoApprove = false,
    ValueChanged<bool>? onAutoApproveChanged,
  }) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: Composer(
            onSend: (text, images, attachments) {
              sent.add(text);
              sentImages?.add(images);
              sentFiles?.add(attachments);
            },
            onStop: () => stopCalls?.add('stop'),
            running: running,
            enabled: enabled,
            onPickImage: onPickImage,
            onPickFile: onPickFile,
            workLevel: workLevel,
            onWorkLevelChanged: onWorkLevelChanged,
            autoApprove: autoApprove,
            onAutoApproveChanged: onAutoApproveChanged,
          ),
        ),
      ),
    );
    return sent;
  }

  /// 在"假装自己是 Windows"的前提下跑 [body]。
  ///
  /// ⚠️ 还原必须用 try/finally 写在**测试体内部**，不能挂 `addTearDown`。
  /// flutter_test 在测试体结束的那一刻就会校验"没有任何 foundation 调试变量
  /// 被改过"（`debugAssertAllFoundationVarsUnset`），而 `addTearDown` 的回调
  /// 跑在那之后——用它还原的话，四个用例会齐刷刷报
  /// "The value of a foundation debug variable was changed by the test"，
  /// 而且这句报错完全不提是哪个变量、也不提还原晚了。
  Future<void> asDesktop(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('桌面端', () {
    testWidgets('回车发送', (tester) async {
      await asDesktop(() async {
        final sent = await pump(tester);

        await tester.enterText(find.byType(TextField), '在吗');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(sent, ['在吗']);
      });
    });

    testWidgets('Shift+回车不发送', (tester) async {
      await asDesktop(() async {
        final sent = await pump(tester);

        await tester.enterText(find.byType(TextField), '在吗');
        // SingleActivator 默认要求那几个修饰键**都没按**，所以 Shift 一按
        // 就不匹配这个快捷键，事件会落到输入框自己身上变成换行。
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
        await tester.pump();

        expect(sent, isEmpty);
      });
    });

    testWidgets('发完清空输入框、并且焦点还在', (tester) async {
      await asDesktop(() async {
        final sent = await pump(tester);

        await tester.enterText(find.byType(TextField), '在吗');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        // 连着说下一句时不该还要再点一次输入框。
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        expect(sent, ['在吗']);
      });
    });

    testWidgets('空白串不发', (tester) async {
      await asDesktop(() async {
        final sent = await pump(tester);

        await tester.enterText(find.byType(TextField), '   ');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(sent, isEmpty);
      });
    });
  });

  group('触屏端', () {
    testWidgets('回车不发送（默认平台就是 android）', (tester) async {
      // 刻意不 override：要测的正是"默认那个平台"下的行为，
      // 手动设成 android 反而会掩盖"默认值被改过"这类问题。
      expect(defaultTargetPlatform, TargetPlatform.android);

      final sent = await pump(tester);
      await tester.enterText(find.byType(TextField), '在吗');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, isEmpty);
    });
  });

  group('发送按钮', () {
    testWidgets('没字的时候点了没反应', (tester) async {
      final sent = await pump(tester);
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('有字就能发', (tester) async {
      final sent = await pump(tester);
      await tester.enterText(find.byType(TextField), '在吗');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, ['在吗']);
    });

    testWidgets('跑着的时候按钮变成"停"，而且空输入也能按', (tester) async {
      final stops = <String>[];
      await pump(tester, running: true, stopCalls: stops);

      // 正在跑 = 用户想打断它。这时候按钮不该因为输入框是空的就变灰。
      expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
      // "停"不是图标，是一个画出来的方块（`_ActionButton` 里那个 Container），
      // 只能按 key 找。
      await tester.tap(find.byKey(const ValueKey('stop')));
      await tester.pump();
      expect(stops, ['stop']);
    });

    testWidgets('禁用时发不出去', (tester) async {
      final sent = await pump(tester, enabled: false);
      await tester.enterText(find.byType(TextField), '在吗');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, isEmpty);
    });
  });

  group('加图', () {
    ImagePart fakePart() =>
        const ImagePart(base64Data: 'AAAA', mimeType: 'image/jpeg');

    testWidgets('没给 onPickImage 就不显示加号', (tester) async {
      await pump(tester);
      expect(find.byIcon(Icons.add_rounded), findsNothing);
    });

    testWidgets('有图没字也能发，而且带上那张图', (tester) async {
      final images = <List<ImagePart>>[];
      await pump(tester, sentImages: images, onPickImage: () async => fakePart());

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();

      expect(images, hasLength(1));
      expect(images.single, hasLength(1));
      expect(images.single.single.base64Data, 'AAAA');
    });

    testWidgets('取消选图（回调返回 null）不进待发区', (tester) async {
      final sent = await pump(tester, onPickImage: () async => null);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      // 还是发不出去：没有图也没有字。
      //
      // 要断言的是 `sent`，不是"找不到那个 key"。回调返回 null 时 `_image`
      // 就是 null，待发区整行都不渲染，`findsNothing` 于是**永远绿**——就算
      // `_pick` 的 `finally` 坏了、`_picking` 卡在 true，它照样绿（转圈的
      // 那条分支也不渲染这个 key）。`sent` 才是有牙的那条：真把 null 当成了
      // 选图成功的话，这里就会发出一个空文本配一张图。
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, isEmpty);
      expect(find.byKey(const ValueKey('remove-image')), findsNothing);
    });

    testWidgets('去掉图之后，没字就发不出去', (tester) async {
      final sent = await pump(
        tester,
        sentImages: <List<ImagePart>>[],
        onPickImage: () async => fakePart(),
      );

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('remove-image')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('remove-image')));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('跑着的时候不显示加号', (tester) async {
      await pump(tester, running: true, onPickImage: () async => fakePart());
      expect(find.byIcon(Icons.add_rounded), findsNothing);
    });

    testWidgets('加号的圆里、图标之外也能点到（命中区不是只有字形那么大）', (tester) async {
      var picked = 0;
      await pump(tester, onPickImage: () async {
        picked++;
        return null;
      });

      // 命中区靠的是那个圆的装饰，不是字形：`BoxDecoration(shape: circle)`
      // 的 `hitTest` 判的是"点在圆内即命中"（SDK `box_decoration.dart:384-388`，
      // 由 `RenderDecoratedBox.hitTestSelf` 委托过去，`proxy_box.dart:2468`）。
      // 所以整块 36 的圆面都点得动，而字形只有中间那 20×20。
      //
      // 这条守的是：一旦有人把这个圆装饰去掉或换成不判形状的东西，命中区就缩回
      // 字形那 20×20，这里会红。**别把它读成"圆里原本点不动"**——没这回事，
      // 初版注释就是这么写错的（当时连测试自己都没有先红一次）。
      final center = tester.getCenter(find.byIcon(Icons.add_rounded));
      await tester.tapAt(center + const Offset(14, 0));
      await tester.pumpAndSettle();

      expect(picked, 1);
    });

    testWidgets('发完图就清掉，不会连发两次', (tester) async {
      final images = <List<ImagePart>>[];
      await pump(tester, sentImages: images, onPickImage: () async => fakePart());

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();

      expect(find.byKey(const ValueKey('remove-image')), findsNothing);

      // 再点一次发送：没图没字，什么都不该发生。
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(images, hasLength(1));
    });

    testWidgets('选图回调抛异常时输入条不崩', (tester) async {
      await pump(
        tester,
        onPickImage: () async => throw StateError('插件炸了'),
      );

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      // `_pick` 把回调的异常 `FlutterError.reportError` 出来了，所以这里拿得到。
      //
      // ⚠️ 别把这行当成随手一断言。实现退化成**不 catch** 时，这条用例**不是**变红，
      // 而是整个测试被 flutter_test 直接判失败（异常无人接），而这里读到 null——
      // 两种红法不一样，但都说明实现退化了。这行守的是"异常没被吞掉"。
      expect(tester.takeException(), isA<StateError>());
      // 这行守的是"界面还在、加号还能按"，也就是"输入条不崩"本身。
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    });
  });

  group('文件附件', () {
    Attachment fakeFile(String name) =>
        Attachment(name: name, text: '日志正文', sizeBytes: 2048);

    testWidgets('只接文件入口时，点加号直接选，不弹菜单', (tester) async {
      var picks = 0;
      await pump(
        tester,
        onPickFile: () async {
          picks++;
          return fakeFile('app.log');
        },
      );

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      expect(picks, 1);
      // 没弹那个"照片 / 文件"的菜单。
      expect(find.text('照片'), findsNothing);
      expect(find.text('app.log'), findsOneWidget);
    });

    testWidgets('没有文字，只挂一个文件也能发，而且带上文件', (tester) async {
      final files = <List<Attachment>>[];
      final images = <List<ImagePart>>[];
      await pump(
        tester,
        sentFiles: files,
        sentImages: images,
        onPickFile: () async => fakeFile('app.log'),
      );

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();

      expect(files, hasLength(1));
      expect(files.single.single.name, 'app.log');
      // 文件不能混到图片那条路上去。
      expect(images.single, isEmpty);
    });

    testWidgets('去掉文件之后，没字就发不出去', (tester) async {
      final sent = await pump(
        tester,
        onPickFile: () async => fakeFile('app.log'),
      );

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(find.text('app.log'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('去掉 app.log'));
      await tester.pump();
      expect(find.text('app.log'), findsNothing);

      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('同一个文件选两次只留一份（不白烧 token）', (tester) async {
      final files = <List<Attachment>>[];
      await pump(
        tester,
        sentFiles: files,
        onPickFile: () async => fakeFile('app.log'),
      );

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byIcon(Icons.add_rounded));
        await tester.pumpAndSettle();
      }
      expect(find.text('app.log'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(files.single, hasLength(1));
    });

    testWidgets('两个入口都在时，先弹菜单；选文件走文件回调', (tester) async {
      var imagePicks = 0;
      var filePicks = 0;
      final files = <List<Attachment>>[];
      await pump(
        tester,
        sentFiles: files,
        onPickImage: () async {
          imagePicks++;
          return null;
        },
        onPickFile: () async {
          filePicks++;
          return fakeFile('notes.txt');
        },
      );

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      // 菜单出来了，而且还没碰任何一个回调。
      expect(find.text('照片'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(imagePicks, 0);
      expect(filePicks, 0);

      await tester.tap(find.text('文件'));
      await tester.pumpAndSettle();

      expect(filePicks, 1);
      expect(imagePicks, 0);
      expect(find.text('notes.txt'), findsOneWidget);
    });
  });

  group('工作强度', () {
    testWidgets('没人给档位时整行都不显示', (tester) async {
      await pump(tester);
      expect(find.byIcon(Icons.bolt_rounded), findsNothing);
    });

    testWidgets('显示当前档位', (tester) async {
      await pump(tester, workLevel: WorkLevel.frugal, onWorkLevelChanged: (_) {});
      expect(find.text('省着用'), findsOneWidget);
      expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    });

    testWidgets('点开能看到三档，选另一档会回调', (tester) async {
      final picked = <WorkLevel>[];
      await pump(
        tester,
        workLevel: WorkLevel.standard,
        onWorkLevelChanged: picked.add,
      );

      await tester.tap(find.byIcon(Icons.bolt_rounded));
      await tester.pumpAndSettle();

      // 三档都在，而且每一档的代价都写出来了——省 token 不能瞒着用户省。
      for (final level in WorkLevel.values) {
        expect(find.text(level.label), findsWidgets);
        expect(find.text(level.summary), findsOneWidget);
      }

      // 点「放开干」那一档。
      await tester.tap(find.text(WorkLevel.thorough.summary));
      await tester.pumpAndSettle();

      expect(picked, [WorkLevel.thorough]);
    });

    testWidgets('点中的就是当前档位时不做任何事', (tester) async {
      final picked = <WorkLevel>[];
      await pump(
        tester,
        workLevel: WorkLevel.standard,
        onWorkLevelChanged: picked.add,
      );

      await tester.tap(find.byIcon(Icons.bolt_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(WorkLevel.standard.summary));
      await tester.pumpAndSettle();

      // 不重建会话：换档是有代价的（重置会话），同档不该付这个代价。
      expect(picked, isEmpty);
    });
  });

  group('自动模式', () {
    testWidgets('没人给回调就不显示——不接线的宿主看不见这颗胶囊', (tester) async {
      await pump(tester, workLevel: WorkLevel.standard, onWorkLevelChanged: (_) {});
      expect(find.text('自动'), findsNothing);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    });

    testWidgets('关着的时候点一下，回调要 true（宿主负责弹确认框）', (tester) async {
      final calls = <bool>[];
      await pump(tester, onAutoApproveChanged: calls.add);

      await tester.tap(find.text('自动'));
      await tester.pump();

      expect(calls, [true]);
    });

    testWidgets('开着的时候是另一行字，点一下回调 false——跑着也能关', (tester) async {
      final calls = <bool>[];
      await pump(
        tester,
        autoApprove: true,
        onAutoApproveChanged: calls.add,
        // 故意让它正在跑：叫停自动模式不该被"忙"挡住。
        running: true,
      );

      expect(find.text('自动·已开'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_rounded), findsOneWidget);

      await tester.tap(find.text('自动·已开'));
      await tester.pump();

      expect(calls, [false]);
    });
  });
}
