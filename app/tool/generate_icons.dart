// 生成 App 图标素材。
//
// 这是开发者工具，**打印就是它的输出**（跑一次看生成了哪几张、多大），
// 不是漏在生产代码里的调试语句，所以整个文件关掉 avoid_print。
// ignore_for_file: avoid_print
//
// 跑法（**不是** `flutter test` 的一部分，它有副作用，不该混进验收关卡）：
//   cd app && "D:/tools/flutter/bin/flutter" test tool/generate_icons.dart
//
// 为什么用测试框架生成图标：Flutter 的 `RepaintBoundary.toImage()` 需要在
// 活着的渲染树里才能用，而 widget test 正好提供了一个。好处是导出的图标和
// 界面里显示的牛蛙**是同一份绘制代码**——不存在"图标是另切的一张图，
// 改了界面忘了改图标"这种漂移。
//
// 生成完再跑 `dart run flutter_launcher_icons` 铺到各平台。
//
// 覆盖式生成：每次跑都重写，所以图标永远是代码的当前状态。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/design/tokens.dart';
import 'package:niuwa_ai/widgets/n1_mark.dart';

/// 图标边长。1024 是各家图标工具链的通用上限，再大没意义。
const int _px = 1024;

void main() {
  testWidgets('生成图标素材', (tester) async {
    final dir = Directory('assets/icon');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // ① 完整图标：绿底圆角方块 + 白牛蛙。给 Android 传统图标、
    //    iOS、Windows .ico 用。
    await _export(
      tester,
      N1AppIcon(size: 200),
      'assets/icon/app_icon.png',
    );

    // ② 自适应图标的前景层：透明底，只有牛蛙。
    //
    //    Android 的自适应图标会把图裁成各种形状（圆的、方的、水滴的），
    //    安全区只有中间约 66%。所以牛蛙得画小一点、居中，四周留透明，
    //    否则在圆形裁切下耳朵（眼睛）会被切掉。
    await _export(
      tester,
      ColoredBox(
        color: const Color(0x00000000),
        child: Center(child: N1Mark(size: 92, color: Colors.white)),
      ),
      'assets/icon/app_icon_foreground.png',
      transparent: true,
    );

    // ③ 单色牛蛙，给深色主题的通知栏小图标、以及网页 favicon 兜底用。
    await _export(
      tester,
      ColoredBox(
        color: const Color(0x00000000),
        child: Center(child: N1Mark(size: 150, color: kAccent)),
      ),
      'assets/icon/mark.png',
      transparent: true,
    );

    print('图标已生成到 assets/icon/');
  });
}

/// 把 [widget] 渲染成 [_px] × [_px] 的 PNG 写到 [path]。
///
/// [transparent] 为 true 时清成透明底；否则填主色（避免出现半透明边缘
/// 在一部分设备上被渲染成黑色）。
Future<void> _export(
  WidgetTester tester,
  Widget widget,
  String path, {
  bool transparent = false,
}) async {
  const logical = 200.0; // 布局用的逻辑尺寸，跟导出像素无关
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
            child: SizedBox(
              width: logical,
              height: logical,
              child: SizedBox.expand(child: widget),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;

  // ⚠️ `toImage` 和 `toByteData` **必须包在 `runAsync` 里**，否则这个测试会
  // 在主体跑完之后永远不结束：函数体一路跑到最后一行、PNG 也真的编出来了，
  // 但测试框架的收尾卡死，10 分钟后被判定 "did not complete" 超时。
  //
  // 表现特别能骗人——日志里三张图的第一张正常打印出来（那是同步的
  // `writeAsBytesSync` 打的），后面的全无音讯，看着像"第二张渲染挂了"，
  // 其实根本不是渲染的问题。`runAsync` 会把这些活儿放回真正的
  // event loop 上跑（见 flutter_test 的说明：编码图片这类真异步操作必须在
  // runAsync 里做），于是收尾就能正常完成。
  final image = await tester.runAsync(
    () => boundary.toImage(pixelRatio: _px / logical),
  );
  if (image == null) {
    throw StateError('$path：toImage 返回了 null（runAsync 被中断？）');
  }

  final bytes = await _encode(tester, image, transparent: transparent);
  File(path).writeAsBytesSync(bytes);

  final kb = (bytes.length / 1024).toStringAsFixed(1);
  print('  $path  ($_px×$_px, $kb KB)');

  image.dispose();
}

/// `toImage()` 出来的是原始像素。要带透明通道就自己编 PNG——
/// `ImageByteFormat.png` 会保留 alpha，但边缘抗锯齿的半透明像素在
/// 部分安卓启动器上会被合成到黑底，所以不透明的那两张下面垫一层实色。
///
/// [tester] 是用来开 `runAsync` 的：这里每一个 `await` 都是引擎侧的真异步活儿，
/// 放在测试的假时钟里跑不完（理由见上面 `_export` 里的长注释）。
Future<Uint8List> _encode(
  WidgetTester tester,
  ui.Image image, {
  required bool transparent,
}) async {
  if (transparent) {
    final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    );
    return data!.buffer.asUint8List();
  }

  // 不透明：垫一层实色底再把图压上去。
  //
  // ⚠️ 垫底的形状由 `flattenOntoRoundedBacking` 决定，**必须是圆角矩形**。
  // 这里原来写的是 `drawRect`（方矩形），把图标自己的圆角填成了实心绿——
  // 导出的 PNG 就是个尖角方块，圆角只在玻璃上看着圆，装到手机上才发现。
  //
  // 逻辑放在 lib 里而不是留在本文件，就是为了让测试够得着（见
  // test/widgets/n1_mark_test.dart）。别为了"就近好读"把它挪回来。
  final flat = await tester.runAsync(
    () => flattenOntoRoundedBacking(image, backing: kAccent),
  );
  if (flat == null) throw StateError('垫底合成失败：runAsync 被中断？');

  final data = await tester.runAsync(
    () => flat.toByteData(format: ui.ImageByteFormat.png),
  );
  flat.dispose();
  return data!.buffer.asUint8List();
}
