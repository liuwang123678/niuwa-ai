import 'dart:math' as math;

/// OKLCH 色空间 + WCAG 对比度。**纯 Dart，不依赖 Flutter。**
///
/// 刻意不 import `dart:ui`：这样挑色阶的脚本能用 `dart run` 直接跑，
/// 色彩数学也能脱离界面单独测。Flutter 那边在 `tokens.dart` 里把算出来的
/// ARGB 整数包成 `Color`。
///
/// 为什么不用 HSL 挑色阶：HSL 的"亮度"不是人眼感知的亮度。`hsl(60 100% 50%)`
/// （黄）和 `hsl(220 100% 50%)`（蓝）标着同一个 L，看着一明一暗。后果是手工
/// 拉一条色阶，中间几档会莫名其妙地跳；想调深一点色相还会自己跑偏（蓝变紫、
/// 绿变墨）。
///
/// OKLCH 里 L 就是感知亮度，色相 H 全程不漂。所以"锁 L 和 H、只调 C"能稳定
/// 生成整条色阶，深浅两端都不发脏。
///
/// 公式来自 Björn Ottosson 2020 年对 OKLab 的定义。
abstract final class Oklch {
  /// 转成 `0xAARRGGBB`。
  ///
  /// [l] 0..1，[c] 色度（0 是灰，0.37 左右到 sRGB 边界），[h] 色相 0..360。
  ///
  /// 超出 sRGB 色域的颜色逐通道夹回边界，不报错——挑色阶时偶尔会踩出去，
  /// 能看见夹完什么样，比直接崩掉有用。
  static int toArgb(double l, double c, double h, {double alpha = 1}) {
    final hRad = h * math.pi / 180;
    final a = c * math.cos(hRad);
    final b = c * math.sin(hRad);

    // OKLab → 锥体响应（LMS 的立方根空间）
    final lp = l + 0.3963377774 * a + 0.2158037573 * b;
    final mp = l - 0.1055613458 * a - 0.0638541728 * b;
    final sp = l - 0.0894841775 * a - 1.2914855480 * b;

    // 立方回去，得到真正的 LMS
    final lc = lp * lp * lp;
    final mc = mp * mp * mp;
    final sc = sp * sp * sp;

    // LMS → 线性 sRGB
    final rLin = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc;
    final gLin = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc;
    final bLin = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc;

    return (_byte(alpha) << 24) |
        (_byte(_gamma(rLin)) << 16) |
        (_byte(_gamma(gLin)) << 8) |
        _byte(_gamma(bLin));
  }

  /// 线性光 → sRGB 传输曲线。分段：暗部走线性段，否则近黑处会出现断层。
  static double _gamma(double x) {
    if (x <= 0.0031308) return 12.92 * x;
    return 1.055 * math.pow(x, 1 / 2.4) - 0.055;
  }

  static int _byte(double unit) =>
      (unit.clamp(0.0, 1.0) * 255).round().clamp(0, 255);
}

/// WCAG 对比度。挑颜色时**实测**，不凭感觉。
abstract final class Contrast {
  /// 前色压在后色上的对比度，1..21。
  ///
  /// WCAG AA 门槛：正文 4.5，大字和 UI 控件 3.0。
  static double ratio(int foreground, int background) {
    final a = luminance(foreground);
    final b = luminance(background);
    final hi = math.max(a, b);
    final lo = math.min(a, b);
    return (hi + 0.05) / (lo + 0.05);
  }

  static double luminance(int argb) {
    double channel(int v) {
      final srgb = v / 255;
      return srgb <= 0.03928
          ? srgb / 12.92
          : math.pow((srgb + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * channel((argb >> 16) & 0xFF) +
        0.7152 * channel((argb >> 8) & 0xFF) +
        0.0722 * channel(argb & 0xFF);
  }

  /// `#RRGGBB`。给调试脚本和测试失败信息用。
  static String hex(int argb) =>
      '#${_two((argb >> 16) & 0xFF)}${_two((argb >> 8) & 0xFF)}${_two(argb & 0xFF)}';

  static String _two(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
}
