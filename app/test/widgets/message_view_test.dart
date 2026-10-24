import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/models/chat_item.dart';
import 'package:niuwa_ai/theme.dart';
import 'package:niuwa_ai/widgets/b64_image.dart';
import 'package:niuwa_ai/widgets/message_view.dart';

/// 造一张真 PNG 的 base64。
///
/// 不用随便一串假的 base64：`Image.memory` 拿到解不开的字节会走 errorBuilder，
/// 于是"图渲染出来了"这条断言会变成假的——它在测占位符。
String realImageB64() {
  final image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(200, 100, 50));
  return base64Encode(Uint8List.fromList(img.encodePng(image)));
}

Future<void> pumpItem(WidgetTester tester, ChatItem item) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(child: MessageView(item: item)),
    ),
  ),
);

void main() {
  testWidgets('纯文字的用户消息照旧：有字、没图', (tester) async {
    await pumpItem(tester, const UserItem('u1', text: '在吗'));
    expect(find.text('在吗'), findsOneWidget);
    expect(find.byType(B64Image), findsNothing);
  });

  testWidgets('图文消息：图和字都在', (tester) async {
    await pumpItem(
      tester,
      UserItem(
        'u2',
        text: '这是啥',
        images: [ImagePart(base64Data: realImageB64(), mimeType: 'image/png')],
      ),
    );
    expect(find.text('这是啥'), findsOneWidget);
    expect(find.byType(B64Image), findsOneWidget);
  });

  testWidgets('只有图没有字：不留一行空文字', (tester) async {
    await pumpItem(
      tester,
      UserItem(
        'u3',
        text: '',
        images: [ImagePart(base64Data: realImageB64(), mimeType: 'image/png')],
      ),
    );
    expect(find.byType(B64Image), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('图渲染出来了，不是占位符', (tester) async {
    await pumpItem(
      tester,
      UserItem(
        'u4',
        text: '',
        images: [ImagePart(base64Data: realImageB64(), mimeType: 'image/png')],
      ),
    );
    await tester.pump();
    // 真解码成功才会有 RawImage；解不开会走 errorBuilder 出一个图标。
    expect(find.byType(RawImage), findsWidgets);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
  });

  testWidgets('坏 base64 出占位，不崩', (tester) async {
    await pumpItem(
      tester,
      const UserItem(
        'u5',
        text: '',
        images: [ImagePart(base64Data: '这不是 base64', mimeType: 'image/png')],
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两张图都在', (tester) async {
    await pumpItem(
      tester,
      UserItem(
        'u6',
        text: '',
        images: [
          ImagePart(base64Data: realImageB64(), mimeType: 'image/png'),
          ImagePart(base64Data: realImageB64(), mimeType: 'image/png'),
        ],
      ),
    );
    expect(find.byType(B64Image), findsNWidgets(2));
  });

  group('token 用量', () {
    AssistantItem finished({
      UsageChunk? usage,
      bool streaming = false,
      String text = '答完了',
    }) => AssistantItem('a1', text: text, streaming: streaming, usage: usage);

    testWidgets('流结束后显示输入/输出，缓存命中单独列出来', (tester) async {
      await pumpItem(
        tester,
        finished(
          usage: const UsageChunk(
            promptTokens: 12345,
            completionTokens: 456,
            cachedTokens: 8000,
          ),
        ),
      );

      // 上万取整成 12k；三位数原样；缓存单列。
      expect(find.text('输入 12k · 输出 456 · 缓存 8.0k'), findsOneWidget);
    });

    testWidgets('没有缓存数时不显示"缓存 0"（别给人看没用的零）', (tester) async {
      await pumpItem(
        tester,
        finished(usage: const UsageChunk(promptTokens: 100, completionTokens: 20)),
      );

      expect(find.text('输入 100 · 输出 20'), findsOneWidget);
    });

    testWidgets('还在流式输出时不显示，等它稳定下来', (tester) async {
      await pumpItem(
        tester,
        finished(
          streaming: true,
          usage: const UsageChunk(promptTokens: 100, completionTokens: 20),
        ),
      );

      expect(find.textContaining('输入'), findsNothing);
    });

    testWidgets('这一家不推 usage 时什么都不显示，不留一行空的', (tester) async {
      await pumpItem(tester, finished());

      expect(find.textContaining('输入'), findsNothing);
      expect(find.textContaining('输出'), findsNothing);
    });
  });

  group('上下文裁剪提示', () {
    testWidgets('裁过就说清楚：它可能不记得更早的事', (tester) async {
      await pumpItem(
        tester,
        AssistantItem('a1', text: '好的', streaming: false, contextTrimmed: true),
      );

      expect(find.textContaining('更早的事它可能不记得'), findsOneWidget);
    });

    testWidgets('没裁过不显示这句（别没事吓人）', (tester) async {
      await pumpItem(
        tester,
        AssistantItem('a1', text: '好的', streaming: false),
      );

      expect(find.textContaining('更早的事'), findsNothing);
    });
  });

  group('复制', () {
    /// 拦下平台通道，返回收集到的 `Clipboard.setData` 调用。
    List<MethodCall> captureClipboard(WidgetTester tester) {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      return calls;
    }

    testWidgets('写完给复制入口，点了真进剪贴板', (tester) async {
      final calls = captureClipboard(tester);
      await pumpItem(
        tester,
        AssistantItem('a1', text: '照这个做', streaming: false),
      );

      await tester.tap(find.text('复制'));
      await tester.pump();

      // 断言的是**真的调了通道**，不是"点下去没报错"：按钮做成了空壳
      // 也照样能点。
      expect(calls, hasLength(1));
      expect(calls.single.arguments['text'], '照这个做');
      // 当场给回执，用户不用去别处粘一下才知道成没成。
      expect(find.text('已复制'), findsOneWidget);
      expect(find.text('复制'), findsNothing);
    });

    testWidgets('流式过程中不显示：半个句子复制走没有意义', (tester) async {
      await pumpItem(
        tester,
        AssistantItem('a1', text: '正在写', streaming: true),
      );

      expect(find.text('复制'), findsNothing);
    });

    testWidgets('没有正文时不显示空的复制按钮', (tester) async {
      await pumpItem(
        tester,
        AssistantItem('a1', text: '   ', streaming: false),
      );

      expect(find.text('复制'), findsNothing);
    });
  });

  testWidgets('点图弹全屏，再点一次关掉', (tester) async {
    await pumpItem(
      tester,
      UserItem(
        'u7',
        text: '',
        images: [ImagePart(base64Data: realImageB64(), mimeType: 'image/png')],
      ),
    );

    // 预热：把这张图在**真实事件循环**上解码完。
    //
    // testWidgets 的测试体跑在假异步区里，`Image.memory` 的解码挂在引擎的
    // 真回调上，永远等不到完成；`RenderImage` 拿不到内在尺寸就报 0×0，
    // 整个 B64Image 跟着塌成 0×0。而 0×0 的盒子命中不了任何点击——
    // `tester.tap(find.byType(B64Image))` 会落到气泡的 DecoratedBox 上，
    // `GestureDetector` 根本不触发（日志里那句 "was not hit" 就是这个）。
    //
    // 这里取的是 widget 自己用的那个 provider，不另造一个 `MemoryImage`：
    // `MemoryImage` 的相等性是**字节数组的引用相等**（`other.bytes == bytes`，
    // `package:flutter/src/painting/image_provider.dart`），另造一个实例
    // key 就对不上，缓存里是另一条记录，这一张仍然没被预热。
    final shown = tester.widget<Image>(find.byType(Image)).image;
    await tester.runAsync(
      () => precacheImage(shown, tester.element(find.byType(B64Image))),
    );
    await tester.pump();

    expect(find.byType(InteractiveViewer), findsNothing);

    await tester.tap(find.byType(B64Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // 点任意处关闭。
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
