import 'package:flutter/material.dart';

/// N1 的设计令牌。**所有颜色、间距、圆角、阴影、动效曲线只从这里取。**
///
/// 颜色值是 `tool/palette.dart` 用 OKLCH 算出来、逐对验过对比度之后写死的。
/// `test/design/tokens_test.dart` 拿这些 hex 反推 OKLCH，验证还是同一套色阶，
/// 也验对比度没掉到门槛以下——手工改 hex 会让测试红，这是故意的。
///
/// 对比度门槛（WCAG AA）：正文 4.5，大字和 UI 控件 3.0。

// ══════════════════════════════════════════════════════════════════
// 颜色
// ══════════════════════════════════════════════════════════════════

/// 主色：H=149 的草叶绿。
///
/// 为什么是这一档：白字压上去 4.58，刚好过 AA 的 4.5。再亮一档（#328D4A）
/// 就掉到 4.16 了——按钮上的字是 15px，不算 WCAG 意义的大字，不能将就。
/// 再暗一档又闷。这个值是算出来的，不是挑出来的。
///
/// 色相 149 而不是 138：138 偏橄榄黄，154 又滑向青绿，会跟 A1（牛蛙音乐）
/// 的水色撞脸。149 是干净的中段绿。
const Color kAccent = Color(0xFF298643);

/// 主色当**文字/图标**用时（而不是当底）。
///
/// 亮底上要压深，否则 4.58 的对比度是用白字算的，反过来绿字压纸底只有 3 点几。
const Color kAccentInkLight = Color(0xFF0F6D2F); // 压纸底 6.06

/// 暗底上反过来要提亮。绿色在白底和暗底上的观感差异比中性色大得多。
const Color kAccentInkDark = Color(0xFF4AA55F); // 压暗底 5.76

/// 主色的极浅洗色：用户气泡底、选中态填充。
const Color kAccentWashLight = Color(0xFFE8F4EA);
const Color kAccentWashDark = Color(0xFF1D3527);

// ── 暖中性 ──────────────────────────────────────────────────────
// 色相 70、色度 0.008。纯粹为了让灰"带一点温度"——死灰配绿色会显得脏。

const Color kNeutral50 = Color(0xFFFBF7F2); // 纸底
const Color kNeutral100 = Color(0xFFFFFEF9); // 卡片（比纸底更亮一点）
const Color kNeutral300 = Color(0xFFCAC5C1); // 强分隔线 / 输入框描边
const Color kNeutral200 = Color(0xFFDBD7D2); // 发丝分隔线
const Color kNeutral600 = Color(0xFF5D5A56); // 次要文字（压纸底 6.43）
const Color kNeutral700 = Color(0xFF7B7773); // 更淡（时间戳、计数）
const Color kNeutral800 = Color(0xFF494542);
const Color kNeutral900 = Color(0xFF1B1814); // 正文 / 暗色模式的页底

const Color kDarkBg = Color(0xFF1B1814); // 暖近黑，不是 #000
const Color kDarkCard = Color(0xFF262320); // 比页底亮一档（暗色靠亮度表达层级）
const Color kDarkRaised = Color(0xFF302C29); // 弹层 / 输入框
const Color kDarkLine = Color(0xFF3A3633);
const Color kDarkInk = Color(0xFFEDE9E4); // 压暗底 14.63
const Color kDarkDim = Color(0xFF928E89); // 压暗底 5.43

// ── 语义色 ──────────────────────────────────────────────────────
// 没有"成功绿"——见 tokens 顶部说明，成功直接用主色，避免两个绿打架。

const Color kDangerLight = Color(0xFFBD4238); // 压纸底 4.92
const Color kDangerDark = Color(0xFFE66E68); // 压暗底 5.72

/// 机器痕迹（工具调用、思考过程、时间戳）用这个色。刻意比正文淡：
/// 用户此刻关心的是结果不是过程。过程要看得见，但不该抢戏。
const Color kTraceLight = Color(0xFF8A8580);
const Color kTraceDark = Color(0xFF7D766F);

// ══════════════════════════════════════════════════════════════════
// 间距
// ══════════════════════════════════════════════════════════════════

/// 4px 基准、8pt 节奏。所有 margin / padding / gap 从这取，不许写魔法数字。
///
/// 为什么要成体系：间距靠手感会累积成"哪里都不太对但说不上来"，
/// 这是廉价感的主要来源之一。
abstract final class S {
  static const double x1 = 2;
  static const double x2 = 4;
  static const double x3 = 8;
  static const double x4 = 12;
  static const double x5 = 16;
  static const double x6 = 20;
  static const double x7 = 24;
  static const double x8 = 32;
  static const double x9 = 40;
  static const double x10 = 56;
  static const double x11 = 72;

  /// 页面左右边距。
  static const double page = x6;

  /// 卡片内边距。低于 20 会显挤。
  static const double card = x6;
}

// ══════════════════════════════════════════════════════════════════
// 圆角
// ══════════════════════════════════════════════════════════════════

/// 一档到底，不混用。混用圆角是廉价感最明显的信号。
abstract final class R {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;

  /// 气泡：贴着屏幕边缘的那两角收窄，视觉上"长"在边上。
  static const double bubble = 18;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
}

// ══════════════════════════════════════════════════════════════════
// 阴影
// ══════════════════════════════════════════════════════════════════

/// 阴影**至少两层**：一层贴边的环境遮蔽 + 一层扩散的投影。
/// 单层阴影看起来是"贴纸"，两层才有厚度。
///
/// 颜色用暖近黑 `#1B1814` 的低透明度，不是纯黑——纯黑投影在暖底上会发灰。
/// 暗色模式不用阴影（暗底上根本看不见），改用描边表达层级。
abstract final class Elev {
  /// 1 级：列表行、内嵌小块。
  static const List<BoxShadow> e1 = [
    BoxShadow(color: Color(0x0A1B1814), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F1B1814), blurRadius: 4, offset: Offset(0, 2)),
  ];

  /// 2 级：卡片、气泡、输入条。
  static const List<BoxShadow> e2 = [
    BoxShadow(color: Color(0x081B1814), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x0F1B1814),
      blurRadius: 16,
      spreadRadius: -4,
      offset: Offset(0, 6),
    ),
  ];

  /// 3 级：弹层、底部抽屉、对话框。
  static const List<BoxShadow> e3 = [
    BoxShadow(color: Color(0x0A1B1814), blurRadius: 4, offset: Offset(0, 2)),
    BoxShadow(
      color: Color(0x1A1B1814),
      blurRadius: 40,
      spreadRadius: -8,
      offset: Offset(0, 16),
    ),
  ];
}

// ══════════════════════════════════════════════════════════════════
// 动效
// ══════════════════════════════════════════════════════════════════

/// 曲线和时长。
///
/// Flutter 自带的 `Curves.easeOut` 是 Material 的缓动，收尾偏软，出来的是
/// "系统动画"的味道。这里用的是各家产品打磨过的三条：
/// - [out] 出场：起手快、尾巴长，让元素像"甩"到位的
/// - [spring] 回弹：轻微过冲再收住，给交互一点生命力
/// - [inOut] 位移：两头都缓，适合位置和尺寸变化
///
/// 时长四档，别自己编：反馈要快（120），多数过渡够用（240），
/// 强调才上 400，600 只留给开场。
abstract final class M {
  static const Curve out = Cubic(0.16, 1, 0.3, 1);
  static const Curve spring = Cubic(0.34, 1.56, 0.64, 1);
  static const Curve inOut = Cubic(0.2, 0, 0, 1);

  static const Duration instant = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 400);
  static const Duration hero = Duration(milliseconds: 600);

  /// 逐条错峰出现时每条之间的间隔。太大会显得慢，太小看不出层次。
  static const Duration stagger = Duration(milliseconds: 40);
}

// ══════════════════════════════════════════════════════════════════
// 字体
// ══════════════════════════════════════════════════════════════════

/// Space Grotesk 作为全站主字体，中文自动回落到系统字体。
///
/// 这个组合的好处：拉丁字母和数字拿到一个有个性的几何无衬线（"高级感"很大
/// 一部分就来自这里），中文用系统自带的 Noto Sans CJK / 苹方，**不多占一字节
/// 包体**——中文字体动辄十几 MB，为了那点观感把 APK 撑大一倍不划算。
///
/// ⚠️ 两个都是可变字体，字重要用 `fontVariations` 指定，光设 `fontWeight`
/// 在部分平台上不会真的插值。
const String kFontSans = 'SpaceGrotesk';
const String kFontMono = 'JetBrainsMono';

/// 中文回退链。顺序有讲究：先具体到平台，再退到通用。
const List<String> kFontFallback = [
  'PingFang SC', // iOS / macOS
  'Noto Sans CJK SC', // Android / Linux
  'Source Han Sans SC',
  'Microsoft YaHei UI', // Windows
  'Microsoft YaHei',
  'sans-serif',
];

/// 造一个正文字体样式。
///
/// [tracking] 只在标题上用负值（-0.02em 上下）：大字默认字距会显得散，
/// 收紧一点才有"排过"的感觉。正文千万不要收，中文会挤。
TextStyle n1Text({
  required double size,
  double weight = 400,
  Color? color,
  double height = 1.7,
  double? tracking,
  bool mono = false,
}) => TextStyle(
  fontFamily: mono ? kFontMono : kFontSans,
  fontFamilyFallback: mono ? const ['Consolas', 'monospace'] : kFontFallback,
  fontSize: size,
  height: height,
  color: color,
  letterSpacing: tracking == null ? null : tracking * size,
  fontVariations: [FontVariation('wght', weight)],
  // 中英混排时把行距上下均分。不设的话中文行会整体偏下，看着"坠"。
  leadingDistribution: TextLeadingDistribution.even,
);

/// 改字重。
///
/// ⚠️ 别用 `copyWith(fontWeight:)` 改这个项目的字重。字体是**可变字体**，
/// 字重走的是 `fontVariations` 那条轴；只设 `fontWeight` 在部分平台上
/// 不会真的插值，字还是原来那个粗细，而代码看着像改过了——最坑的那种。
extension N1Weight on TextStyle {
  TextStyle n1W(double weight) =>
      copyWith(fontVariations: [FontVariation('wght', weight)]);
}

