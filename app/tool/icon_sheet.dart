// 开发者工具：打印就是它的输出，不是漏在生产代码里的调试语句。
// ignore_for_file: avoid_print
//
// 牛蛙造型对比表。一次渲染多个变体，避免"改一个数 → 编译五分钟 → 看一眼 →
// 再改"这种来回。
//
// 跑法：
//   cd app && "D:/tools/flutter/bin/flutter" test tool/icon_sheet.dart
// 产物：assets/icon/_sheet.png（**别提交**，挑完造型就删）
//
// 两个已知的坑，都踩过了：
//   ① 标签一律用 ASCII。`flutter test` 的字体环境没有中文字形，写中文会渲染
//      成一排豆腐块，等于没标。
//   ② **不要手算画布尺寸**。算错就是一条刺眼的黄黑溢出条纹，白等一次渲染。
//      改成把测试窗口开大、让内容自己撑开，就再也不会溢出。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/design/tokens.dart';
import 'package:niuwa_ai/widgets/n1_mark.dart';

/// 造一个形状，**横竖都自动居中**。
///
/// 手动算这两个数错一次就白等一次渲染，所以写成函数：
/// - 纵向：反解出让"眼睛顶端 → 下巴底端"中点落在 0.5 的 `headTop`。
///   眼睛往上凸，按包围盒居中的话视觉重心会往下坠，标志看起来像没放正。
/// - 横向：`headLeft` 由 `headW` 反推。**不能给固定值**——眼睛永远是对称
///   分布在 0.5 两侧的，脸一旦不跟着居中，宽脸就会整体右偏；`headW` 超过
///   0.88 时还会直接画到画布外面（CustomPaint 默认不裁剪，不会报错，
///   只是静静地缺一块）。
FrogShape _shape({
  required double headH,
  required double headW,
  required double headR,
  required double eyeR,
  required double eyeY,
  required double eyeGap,
  required double pupilR,
}) => FrogShape(
  headTop: 1.0 - (eyeY - eyeR) - headH,
  headLeft: (1.0 - headW) / 2,
  headW: headW,
  headH: headH,
  headR: headR,
  eyeR: eyeR,
  eyeY: eyeY,
  eyeGap: eyeGap,
  pupilR: pupilR,
);

/// 出厂造型（对照组）。这一版的问题是**读起来像熊不像牛蛙**——
/// 眼睛偏小、偏开、凸出不够，那三条正好是"耳朵"而不是"蛙眼"的特征。
final _variants = <String, FrogShape>{
  // 对照组：确认"改动到底有没有效果"。眼睛偏小偏开，读起来像熊耳朵。
  'S std': FrogShape.standard,

  // 上一轮的赢家：脸极宽极扁，眼睛清楚地"坐"在头顶上、跟脸之间有颈缩。
  // 其余三版都在它附近微调。
  'Q1 base': _shape(
    headH: 0.460,
    headW: 0.960,
    headR: 0.225,
    eyeR: 0.165,
    eyeY: 0.300,
    eyeGap: 0.360,
    pupilR: 0.072,
  ),

  // 眼睛再大一点、再靠拢一点。想看看是不是更有神。
  'Q2 bigeye': _shape(
    headH: 0.460,
    headW: 0.960,
    headR: 0.225,
    eyeR: 0.174,
    eyeY: 0.294,
    eyeGap: 0.348,
    pupilR: 0.076,
  ),

  // 脸再扁一档。扁到哪儿开始显得"压扁了"。
  'Q3 flatter': _shape(
    headH: 0.428,
    headW: 0.975,
    headR: 0.212,
    eyeR: 0.168,
    eyeY: 0.300,
    eyeGap: 0.355,
    pupilR: 0.074,
  ),

  // 瞳孔加大。瞳孔占眼睛的比例决定神态：小了显得"瞪"，大了显得呆，
  // 中间偏小一点最像在看着你。
  'Q4 pupil': _shape(
    headH: 0.460,
    headW: 0.960,
    headR: 0.225,
    eyeR: 0.165,
    eyeY: 0.300,
    eyeGap: 0.360,
    pupilR: 0.082,
  ),
};

void main() {
  testWidgets('渲染造型对比表', (tester) async {
    // 窗口开得比内容大得多，内容是"自己撑开"的——这样就不用手算画布尺寸，
    // 也就不可能算错。
    tester.view.physicalSize = const Size(2600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const cell = 220.0;
    const gap = 24.0;
    const silo = 72.0;
    const strip = 84.0;
    final names = _variants.keys.toList();

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
              child: ColoredBox(
                color: kNeutral50,
                child: Padding(
                  padding: const EdgeInsets.all(gap),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── ① 正常渲染：看造型本身 ──
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < names.length; i++) ...[
                            if (i > 0) const SizedBox(width: gap),
                            _labelled(
                              names[i],
                              cell,
                              N1AppIcon(size: cell, shape: _variants[names[i]]!),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: gap),

                      // ── ② 剪影：把瞳孔填死，只看外轮廓 ──
                      //
                      // 决定一个标志缩到 16px 还认不认得出的，是轮廓不是内部
                      // 细节。所以这一行比上面那行更值得盯。
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < names.length; i++) ...[
                            if (i > 0) const SizedBox(width: gap),
                            SizedBox(
                              width: cell,
                              // 必须套一层 Align：光有 SizedBox 的话宽度是紧
                              // 约束，N1AppIcon 里那个 Container 会被拉成
                              // 220 宽的长条，剪影就没法看了。
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: N1AppIcon(
                                  size: silo,
                                  // pupilR 给个极小值就等于实心。省得为了一个
                                  // 工具去给 N1Mark 加一个只有这里用的参数。
                                  shape: _holeless(_variants[names[i]]!),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: gap),

                      // ── ③ 真实小尺寸：通知栏 / 标题栏那个量级 ──
                      SizedBox(
                        height: strip,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final px in [16.0, 20.0, 24.0, 32.0, 40.0, 56.0])
                              Padding(
                                padding: const EdgeInsets.only(right: 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    N1AppIcon(size: px),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${px.toInt()}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: kNeutral600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('assets/icon/_sheet.png').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();

    final size = boundary.size;
    print('对比表已写到 assets/icon/_sheet.png （${size.width.toInt()}×'
        '${size.height.toInt()} 逻辑像素）');
  });
}

Widget _labelled(String label, double width, Widget child) => SizedBox(
  width: width,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      child,
      const SizedBox(height: 6),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: kNeutral900),
      ),
    ],
  ),
);

/// 把瞳孔缩到看不见，得到实心剪影。
FrogShape _holeless(FrogShape s) => FrogShape(
  headTop: s.headTop,
  headLeft: s.headLeft,
  headW: s.headW,
  headH: s.headH,
  headR: s.headR,
  eyeR: s.eyeR,
  eyeY: s.eyeY,
  eyeGap: s.eyeGap,
  pupilR: 0.0001,
);
