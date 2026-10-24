import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// 牛蛙标志的几何参数。
///
/// 全部以"标志边长"为单位（0..1），跟实际像素无关，所以放到多大都一致。
/// 抽成数据而不是写死在 painter 里，是为了能一次渲染多个变体做对比——
/// 每改一个数就重新编译一遍跑一张图，Windows 上要五分钟，太慢。
@immutable
class FrogShape {
  const FrogShape({
    required this.headTop,
    required this.headLeft,
    required this.headW,
    required this.headH,
    required this.headR,
    required this.eyeR,
    required this.eyeY,
    required this.eyeGap,
    required this.pupilR,
  });

  /// 脸的上边缘。**纵向是光学居中**：眼睛往上凸，如果按包围盒居中，
  /// 视觉重心会往下坠。标准造型里眼睛顶端 0.135、下巴底端 0.865，
  /// 中点正好 0.500。改任何一个数都要回头验一遍这个中点。
  final double headTop;

  final double headLeft;
  final double headW;
  final double headH;

  /// 脸的圆角。给到接近半高就是"方圆形"，太方正会像箱子，太圆会像馒头。
  final double headR;

  final double eyeR;

  /// 眼睛中心的纵坐标。要小于 [headTop] 才会凸出头顶。
  final double eyeY;

  /// 两眼中心的间距（横向距离，以边长为单位）。
  final double eyeGap;

  /// 瞳孔半径。跟眼睛的比例约 0.42——太小显得"瞪"，太大就显得呆。
  final double pupilR;

  double get eyeLeftX => 0.5 - eyeGap / 2;
  double get eyeRightX => 0.5 + eyeGap / 2;

  /// 加值相等，让 `shouldRepaint` 能正确判断。
  ///
  /// 现在所有实例都是 `const`，Dart 会做规范化，`!=` 比的就是值。但那只在
  /// 全 const 时成立；哪天有人在运行时算出一个形状，身份比较就会失效——
  /// 表现是"参数变了但画面不重绘"，很难查。所以显式写上。
  @override
  bool operator ==(Object other) =>
      other is FrogShape &&
      other.headTop == headTop &&
      other.headLeft == headLeft &&
      other.headW == headW &&
      other.headH == headH &&
      other.headR == headR &&
      other.eyeR == eyeR &&
      other.eyeY == eyeY &&
      other.eyeGap == eyeGap &&
      other.pupilR == pupilR;

  @override
  int get hashCode => Object.hash(
    headTop,
    headLeft,
    headW,
    headH,
    headR,
    eyeR,
    eyeY,
    eyeGap,
    pupilR,
  );

  /// 出厂造型。
  ///
  /// 是**量出来的，不是调出来的**：用 `tool/icon_sheet.dart` 一次渲染多个变体
  /// 横向对比后选的（每改一个数重新编译跑一张图，在 Windows 上要五分钟，
  /// 一个来回就废掉十分钟）。
  ///
  /// 选它的理由，跟落选的那几版对照着看：
  /// - 脸要**又宽又扁**（0.96 × 0.46，接近 2:1）。这是牛蛙跟熊最直接的区别——
  ///   熊的脸接近正圆，耳朵是贴在圆上的两个小三角。
  /// - 眼睛要**清楚地坐在头顶上**，跟脸之间有颈缩。眼睛跟脸糊成一坨的话，
  ///   那两个凸起立刻被读成"耳朵"。这一条是整张图最关键的地方。
  /// - 瞳孔**宁小勿大**（占眼睛 0.44）。瞳孔一大就变成"瞪"，神态是惊的；
  ///   小一点反而像在安静地看着你——这也是这个 App 该有的表情。
  ///
  /// `headLeft` = (1 - headW) / 2：眼睛永远对称分布在 0.5 两侧，脸必须跟着居中。
  /// 给固定值的话宽脸会整体右偏，而且 headW 超过 0.88 时会直接画到画布外面
  /// （CustomPaint 默认不裁剪，不报错，只是静静地缺一块）。
  static const standard = FrogShape(
    headTop: 0.405,
    headLeft: 0.02,
    headW: 0.96,
    headH: 0.46,
    headR: 0.225,
    eyeR: 0.165,
    eyeY: 0.30,
    eyeGap: 0.36,
    pupilR: 0.072,
  );
}

/// N1 的牛蛙标志。
///
/// 骨相学的是 Claude Code 那一路：**单色、几何、一眼认得出，但不描细节**。
/// 不用插画、不加立体、不描高光——细节越多，缩到 20px 越糊。
///
/// 造型要点（也是牛蛙区别于熊/猫头鹰的地方）：
/// - 脸**宽而低**，接近半个圆角方
/// - 两只眼睛**大且凸出头顶**，间距近
/// - 瞳孔**挖空**——不挖空的话在深色底上眼睛会跟脸糊成一片
///
/// 画成矢量而不是切图：同一个定义既能在界面里当图标，也能导出成 App 图标
/// （导出走 `tool/generate_icons.dart`），不会出现"图标跟界面对不上"。
class N1Mark extends StatelessWidget {
  const N1Mark({
    super.key,
    this.size = 32,
    this.color,
    this.shape = FrogShape.standard,
  });

  final double size;

  /// 不给就用主色。
  final Color? color;

  final FrogShape shape;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _FrogPainter(color: color ?? kAccent, shape: shape),
      size: Size.square(size),
    ),
  );
}

/// App 图标：圆角方块底 + 居中的白色牛蛙。
///
/// 底走一点从亮到暗的绿渐变而不是平涂。平涂在大尺寸下会显得单薄，一点点明暗
/// 就能撑出质感——但幅度要小，大了就成塑料玩具了。
class N1AppIcon extends StatelessWidget {
  const N1AppIcon({
    super.key,
    required this.size,
    this.padding = 0.15,
    this.shape = FrogShape.standard,
  });

  /// 圆角半径占边长的比例。
  ///
  /// **公开是有原因的**：导出图标那一步（`tool/generate_icons.dart`）要在底下垫
  /// 一层不透明的底。垫成方的，导出的 PNG 就是个尖角方块——圆角只剩玻璃上看着圆，
  /// 文件本身是方的，装到安卓上不带自适应图标的场合就是个方块。
  /// 两处各写一个 0.225 迟早会漂，所以这里是唯一来源。
  static const double cornerRadiusRatio = 0.225;

  final double size;

  /// 牛蛙四周留多少边距（占边长的比例）。
  ///
  /// 0.15 是调过的：0.20 留白太多，牛蛙在图标里显得畏缩；再小就会被圆角
  /// 切到下巴。这个尺寸下牛蛙占边长约六成，是 App 图标常见的自信比例。
  final double padding;

  final FrogShape shape;

  @override
  Widget build(BuildContext context) {
    final inset = size * padding;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF35A052), kAccent, Color(0xFF1F7237)],
          stops: [0.0, 0.52, 1.0],
        ),
        borderRadius: BorderRadius.circular(size * cornerRadiusRatio),
      ),
      child: Center(
        child: N1Mark(size: size - inset * 2, color: Colors.white, shape: shape),
      ),
    );
  }
}

/// 把渲染出来的图标压到一层实色圆角底上，返回不透明的结果图。
///
/// **放在 lib 里而不是工具脚本里，是为了能测。** 导出的图标曾经是个尖角方块：
/// 这里垫的是**方**矩形，把 [N1AppIcon] 画好的圆角又填了回去——文件是方的、
/// 玻璃上看着圆，装到手机上才发现。那个 bug 能溜过去，就是因为垫底这段逻辑
/// 只活在 `tool/generate_icons.dart` 里，没有任何测试够得着。
///
/// 垫底本身要解决的是真问题：图标边缘抗锯齿的半透明像素，在部分安卓启动器上
/// 会被合成到黑底，描出一圈黑边。垫一层实色就没这问题——但垫的形状必须和
/// 图标本身一致，所以半径取的是同一个 [N1AppIcon.cornerRadiusRatio]。
///
/// 圆角那一圈仍是正常抗锯齿（跟任何一张圆角图标一样），圆角外面是全透明。
Future<ui.Image> flattenOntoRoundedBacking(ui.Image source, {Color backing = kAccent}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final side = source.width.toDouble();

  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, side, side),
      Radius.circular(side * N1AppIcon.cornerRadiusRatio),
    ),
    Paint()..color = backing,
  );
  canvas.drawImage(source, Offset.zero, Paint());

  return recorder.endRecording().toImage(source.width, source.height);
}

class _FrogPainter extends CustomPainter {
  const _FrogPainter({required this.color, required this.shape});

  final Color color;
  final FrogShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final k = shape;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;

    // ── 脸：宽而低的圆角方 ──
    final head = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(k.headLeft * s, k.headTop * s, k.headW * s, k.headH * s),
          Radius.circular(k.headR * s),
        ),
      );

    // ── 眼睛：凸出头顶 ──
    final left = Offset(k.eyeLeftX * s, k.eyeY * s);
    final right = Offset(k.eyeRightX * s, k.eyeY * s);
    final eyes = Path()
      ..addOval(Rect.fromCircle(center: left, radius: k.eyeR * s))
      ..addOval(Rect.fromCircle(center: right, radius: k.eyeR * s));

    // 眼睛和脸是**并集**。不能用 evenOdd——两者重叠的区域会被判成"偶数层"
    // 而被挖掉，眼睛和脸交界处就会出现一道奇怪的缝。
    final body = Path.combine(PathOperation.union, head, eyes);

    // ── 瞳孔：挖空 ──
    final pupils = Path()
      ..addOval(Rect.fromCircle(center: left, radius: k.pupilR * s))
      ..addOval(Rect.fromCircle(center: right, radius: k.pupilR * s));

    canvas.drawPath(
      Path.combine(PathOperation.difference, body, pupils),
      paint,
    );
  }

  @override
  bool shouldRepaint(_FrogPainter old) =>
      old.color != color || old.shape != shape;
}
