// 启动动画的逐帧预览。不是日常测试（文件名不以 `_test` 结尾，全量
// `flutter test` 不会带上它），看效果时才手动跑：
//
//   flutter test tool/splash_preview.dart
//
// 产物在 D:\temp\n1-splash\ 下，用文件资源管理器一张张翻。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/widgets/n1_mark.dart';
import 'package:niuwa_ai/widgets/splash_gate.dart';

const _out = r'D:\temp\n1-splash';

/// 假界面：左侧一条和真实侧栏同宽同色的竖栏，上面放一只真蛙。
/// 闪屏那只落下来时正好对上它——对不上就会被一眼看出来。
Widget fakeShell() {
  return Row(
    children: [
      Container(
        width: 84,
        color: const Color(0xFFF3EDE4),
        child: const Column(
          children: [
            Padding(
              padding: EdgeInsets.only(top: 20, bottom: 20),
              child: N1Mark(size: 30),
            ),
            _Bar(width: 34, height: 8),
            SizedBox(height: 22),
            _Bar(width: 34, height: 8),
            SizedBox(height: 22),
            _Bar(width: 34, height: 8),
          ],
        ),
      ),
      Expanded(
        child: Container(
          color: const Color(0xFFFBF7F2),
          padding: const EdgeInsets.fromLTRB(64, 90, 64, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Bar(width: 220, height: 16),
              const SizedBox(height: 18),
              const _Bar(width: 380, height: 10),
              const SizedBox(height: 10),
              const _Bar(width: 320, height: 10),
              const SizedBox(height: 40),
              Container(
                width: 520,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: const Color(0xFFDFD5C7),
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );
}

void main() {
  testWidgets('逐帧', (tester) async {
    Directory(_out).createSync(recursive: true);

    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: SplashGate<String>(
          boot: Future.value('好了'),
          builder: (_) => fakeShell(),
          errorBuilder: (e) => Text('$e'),
        ),
      ),
    );

    var at = Duration.zero;

    Future<void> snap(String name) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_out${Platform.pathSeparator}$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    Future<void> step(int ms, String name) async {
      await tester.pump(Duration(milliseconds: ms));
      at += Duration(milliseconds: ms);
      await snap('${at.inMilliseconds.toString().padLeft(4, '0')}_$name');
    }

    await snap('0000_start'); // 首帧
    await step(150, 'rise');
    await step(200, 'blink_closing'); // 350ms：闭眼途中
    await step(80, 'blink_shut'); // 430ms：闭着
    await step(220, 'open'); // 650ms：已睁眼，飞行刚起
    await step(90, 'fly_30'); // 740ms
    await step(100, 'fly_60'); // 840ms
    await step(100, 'fly_90'); // 940ms
    await step(80, 'landed'); // 1020ms
    await step(200, 'settled'); // 1220ms

    // 收尾：把还在跑的控制器耗完，别让测试因为 ticker 还活着报警。
    await tester.pump(const Duration(seconds: 2));
  });
}
