import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/widgets/n1_mark.dart';

/// 图标形状。
///
/// 这一组是补出来的：**导出的 App 图标曾经是个尖角方块**。`N1AppIcon` 画的明明
/// 是圆角矩形，但导出那一步用 `drawRect` 在底下垫了一层**方**的实色底，把圆角
/// 又填成了实心绿。文件是方的、玻璃上看着圆，一路没人发现，直到装到手机上看出来。
///
/// 所以这里测的**不是** `N1AppIcon` 画得圆不圆（它一直是圆的），而是
/// **导出那一步的成品圆不圆**——那正是出问题的环节，也是原来的测试够不着的地方。
void main() {
  /// 把 widget 渲染成一张图。
  Future<ui.Image> render(WidgetTester tester, Widget widget, double side) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: SizedBox(width: side, height: side, child: widget),
            ),
          ),
        ),
      ),
    );

    // ⚠️ `toImage` / `toByteData` 必须包在 `runAsync` 里，否则测试会在主体
    // 跑完之后**永远不结束**（详见 tool/generate_icons.dart 里的长注释）。
    final image = await tester.runAsync(
      () => (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
          .toImage(pixelRatio: 1),
    );
    return image!;
  }

  Future<ByteData> pixels(WidgetTester tester, ui.Image image) async {
    final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return data!;
  }

  /// 取 [x],[y] 那个像素的 alpha。buffer 是 RGBA 四字节一组。
  int alphaAt(ByteData data, int width, int x, int y) =>
      data.getUint8((y * width + x) * 4 + 3);

  const double side = 200;
  const int w = 200;

  testWidgets('导出的成品：四角透明（也就是真的圆角），中间实心', (tester) async {
    // 走的路径跟 tool/generate_icons.dart 一模一样：先渲染，再垫底压平。
    final raw = await render(tester, const N1AppIcon(size: side), side);
    final flat = await tester.runAsync(() => flattenOntoRoundedBacking(raw));
    final data = await pixels(tester, flat!);

    for (final (name, x, y) in [
      ('左上', 0, 0),
      ('右上', w - 1, 0),
      ('左下', 0, w - 1),
      ('右下', w - 1, w - 1),
    ]) {
      expect(
        alphaAt(data, w, x, y),
        0,
        reason: '$name 角必须透明，否则导出的图标是个尖角方块',
      );
    }

    // 中心是牛蛙的白肚子
    expect(alphaAt(data, w, w ~/ 2, w ~/ 2), 255);
    // 上下边中点没被圆角切到，仍然是实心底色——别为了圆角把整个图标削瘪了
    expect(alphaAt(data, w, w ~/ 2, 0), 255);
    expect(alphaAt(data, w, w ~/ 2, w - 1), 255);
    expect(alphaAt(data, w, 0, w ~/ 2), 255);
    expect(alphaAt(data, w, w - 1, w ~/ 2), 255);

    raw.dispose();
  });

  testWidgets('垫底的圆角和界面里画的是同一个数', (tester) async {
    // 防漂：形状参数各写各的，就是上面那个 bug 的成因。
    expect(N1AppIcon.cornerRadiusRatio, 0.225);
  });
}
