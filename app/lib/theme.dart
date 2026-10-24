import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design/tokens.dart';

/// N1 的主题。所有取值来自 `design/tokens.dart`，这里只负责把令牌组装成
/// `ThemeData` 和语义色扩展。
///
/// 设计意图：界面往后退，让字说话。所以
/// - 全局只有一个强调色，且只出现在少数几处（发送键、选中 tab、用户气泡）
/// - 大留白，行高给到 1.7（中文比西文"高"，行距不够会糊成一块）
/// - 暗色不用阴影表达层级（暗底上看不见），改用亮一档的表面色 + 描边

/// 语义色。从 context 取：`N1Colors.of(context).dim`。
///
/// 为什么走 ThemeExtension 而不是全局常量：全局常量没法跟着亮暗切换，
/// 而亮暗两套的语义色不是取反关系（绿在白底和暗底上的观感差异比灰大得多）。
@immutable
class N1Colors extends ThemeExtension<N1Colors> {
  const N1Colors({
    required this.bg,
    required this.card,
    required this.raised,
    required this.ink,
    required this.dim,
    required this.faint,
    required this.line,
    required this.lineStrong,
    required this.accentInk,
    required this.accentWash,
    required this.trace,
    required this.danger,
    required this.elevation,
    required this.hasShadow,
  });

  /// 页面底色。
  final Color bg;

  /// 卡片、气泡底。
  final Color card;

  /// 浮起来的表面：弹层、输入条、底部抽屉。
  final Color raised;

  /// 正文。
  final Color ink;

  /// 次要文字：标签、说明。
  final Color dim;

  /// 最淡一档：时间戳、计数、占位符。**不要用来放需要读清的内容。**
  final Color faint;

  /// 发丝分隔线。
  final Color line;

  /// 输入框、卡片描边。比 [line] 重，因为要"看得见是个框"。
  final Color lineStrong;

  /// 主色当文字/图标用时（不是当底）。
  final Color accentInk;

  /// 主色的极浅洗色：选中态、用户气泡底。
  final Color accentWash;

  /// 机器痕迹（工具调用、思考过程）。
  final Color trace;

  final Color danger;

  /// 这个模式下卡片该用几层阴影。暗色模式是空列表。
  final List<BoxShadow> elevation;

  /// 暗色模式靠描边而不是阴影表达层级。
  final bool hasShadow;

  static const light = N1Colors(
    bg: kNeutral50,
    card: kNeutral100,
    raised: kNeutral100,
    ink: kNeutral900,
    dim: kNeutral600,
    faint: kNeutral700,
    line: kNeutral200,
    lineStrong: kNeutral300,
    accentInk: kAccentInkLight,
    accentWash: kAccentWashLight,
    trace: kTraceLight,
    danger: kDangerLight,
    elevation: Elev.e2,
    hasShadow: true,
  );

  static const dark = N1Colors(
    bg: kDarkBg,
    card: kDarkCard,
    raised: kDarkRaised,
    ink: kDarkInk,
    dim: kDarkDim,
    faint: kDarkDim,
    line: kDarkLine,
    lineStrong: kDarkLine,
    accentInk: kAccentInkDark,
    accentWash: kAccentWashDark,
    trace: kTraceDark,
    danger: kDangerDark,
    // 暗底上阴影基本不可见，用表面色差 + 描边代替
    elevation: <BoxShadow>[],
    hasShadow: false,
  );

  static N1Colors of(BuildContext context) =>
      Theme.of(context).extension<N1Colors>() ?? light;

  /// 卡片/浮层的装饰。集中在这里，免得每处手写一遍阴影。
  BoxDecoration surface({
    Color? color,
    double radius = R.md,
    bool outline = false,
    List<BoxShadow>? shadow,
  }) => BoxDecoration(
    color: color ?? card,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: shadow ?? elevation,
    border: (outline || !hasShadow)
        ? Border.all(color: line, width: 1)
        : null,
  );

  @override
  N1Colors copyWith({
    Color? bg,
    Color? card,
    Color? raised,
    Color? ink,
    Color? dim,
    Color? faint,
    Color? line,
    Color? lineStrong,
    Color? accentInk,
    Color? accentWash,
    Color? trace,
    Color? danger,
    List<BoxShadow>? elevation,
    bool? hasShadow,
  }) => N1Colors(
    bg: bg ?? this.bg,
    card: card ?? this.card,
    raised: raised ?? this.raised,
    ink: ink ?? this.ink,
    dim: dim ?? this.dim,
    faint: faint ?? this.faint,
    line: line ?? this.line,
    lineStrong: lineStrong ?? this.lineStrong,
    accentInk: accentInk ?? this.accentInk,
    accentWash: accentWash ?? this.accentWash,
    trace: trace ?? this.trace,
    danger: danger ?? this.danger,
    elevation: elevation ?? this.elevation,
    hasShadow: hasShadow ?? this.hasShadow,
  );

  @override
  N1Colors lerp(N1Colors? other, double t) {
    if (other == null) return this;
    return N1Colors(
      bg: Color.lerp(bg, other.bg, t)!,
      card: Color.lerp(card, other.card, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      dim: Color.lerp(dim, other.dim, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineStrong: Color.lerp(lineStrong, other.lineStrong, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      accentWash: Color.lerp(accentWash, other.accentWash, t)!,
      trace: Color.lerp(trace, other.trace, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      elevation: t < 0.5 ? elevation : other.elevation,
      hasShadow: t < 0.5 ? hasShadow : other.hasShadow,
    );
  }
}

ThemeData buildAppTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? N1Colors.dark : N1Colors.light;
  final isDark = brightness == Brightness.dark;

  final scheme =
      ColorScheme.fromSeed(seedColor: kAccent, brightness: brightness).copyWith(
        primary: kAccent,
        onPrimary: Colors.white,
        surface: c.bg,
        onSurface: c.ink,
        error: c.danger,
        outline: c.lineStrong,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    // 不用 M3 默认的染色表面：它会把卡片染上一层淡淡的主题色，
    // 跟"界面往后退"的意图相反。
    canvasColor: c.bg,
    splashFactory: InkSparkle.splashFactory,
    // 页面切换用自定义曲线，不要 Material 默认那套。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _N1PageTransition(),
        TargetPlatform.iOS: _N1PageTransition(),
        TargetPlatform.windows: _N1PageTransition(),
        TargetPlatform.macOS: _N1PageTransition(),
        TargetPlatform.linux: _N1PageTransition(),
      },
    ),
  );

  return base.copyWith(
    extensions: [c],
    textTheme: _textTheme(c),

    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: n1Text(size: 17, weight: 600, color: c.ink),
      iconTheme: IconThemeData(color: c.ink, size: 20),
      systemOverlayStyle: isDark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
    ),

    cardTheme: CardThemeData(
      color: c.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: R.mdAll,
        side: c.hasShadow ? BorderSide.none : BorderSide(color: c.line),
      ),
    ),

    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.raised,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: S.x5,
        vertical: S.x4 + 2,
      ),
      hintStyle: n1Text(size: 15, color: c.faint, height: 1.4),
      labelStyle: n1Text(size: 13, weight: 500, color: c.dim, height: 1.3),
      helperStyle: n1Text(size: 12.5, color: c.faint, height: 1.4),
      errorStyle: n1Text(size: 12.5, color: c.danger, height: 1.4),
      border: const OutlineInputBorder(
        borderRadius: R.mdAll,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: R.mdAll,
        borderSide: BorderSide(color: c.lineStrong),
      ),
      // 聚焦 = 主色描边 + 一圈柔和光环。
      // 光环而不是更粗的描边：描边加粗会让整块跳一下，光环不会。
      focusedBorder: const OutlineInputBorder(
        borderRadius: R.mdAll,
        borderSide: BorderSide(color: kAccent, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: R.mdAll,
        borderSide: BorderSide(color: c.danger, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: R.mdAll,
        borderSide: BorderSide(color: c.danger),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: c.line,
        disabledForegroundColor: c.faint,
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: S.x7),
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: R.mdAll),
        textStyle: n1Text(size: 15, weight: 600, height: 1.2),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accentInk,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: S.x4),
        shape: const RoundedRectangleBorder(borderRadius: R.smAll),
        textStyle: n1Text(size: 15, weight: 500, height: 1.2),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        side: BorderSide(color: c.lineStrong),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: S.x6),
        shape: const RoundedRectangleBorder(borderRadius: R.mdAll),
        textStyle: n1Text(size: 15, weight: 500, height: 1.2),
      ),
    ),

    iconTheme: IconThemeData(color: c.dim, size: 20),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : c.bg,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? kAccent : c.lineStrong,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),

    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: kAccent,
      inactiveTrackColor: c.line,
      thumbColor: kAccent,
      overlayColor: kAccent.withValues(alpha: 0.12),
      trackHeight: 4,
    ),

    chipTheme: ChipThemeData(
      backgroundColor: c.card,
      side: BorderSide(color: c.line),
      labelStyle: n1Text(size: 12, color: c.dim, height: 1.2),
      shape: const RoundedRectangleBorder(borderRadius: R.smAll),
      padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 0),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark ? kDarkRaised : kNeutral900,
      contentTextStyle: n1Text(
        size: 14,
        color: isDark ? kDarkInk : kNeutral50,
        height: 1.5,
      ),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: R.smAll),
      insetPadding: const EdgeInsets.all(S.x5),
      elevation: 0,
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: R.lgAll),
      titleTextStyle: n1Text(size: 17, weight: 600, color: c.ink, height: 1.4),
      contentTextStyle: n1Text(size: 15, color: c.ink, height: 1.7),
      insetPadding: const EdgeInsets.symmetric(horizontal: S.x7, vertical: S.x7),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.lg)),
      ),
      showDragHandle: true,
      dragHandleColor: c.lineStrong,
    ),

    listTileTheme: ListTileThemeData(
      iconColor: c.dim,
      textColor: c.ink,
      titleTextStyle: n1Text(size: 15, color: c.ink, height: 1.4),
      subtitleTextStyle: n1Text(size: 13, color: c.dim, height: 1.4),
      shape: const RoundedRectangleBorder(borderRadius: R.smAll),
      contentPadding: const EdgeInsets.symmetric(horizontal: S.x5),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: kAccent,
      strokeWidth: 2.5,
      linearMinHeight: 2.5,
    ),

    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(c.lineStrong),
      radius: const Radius.circular(4),
      thickness: const WidgetStatePropertyAll(6),
      interactive: false,
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: isDark ? kDarkRaised : kNeutral900,
        borderRadius: R.smAll,
      ),
      textStyle: n1Text(
        size: 12.5,
        color: isDark ? kDarkInk : kNeutral50,
        height: 1.4,
      ),
      padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2 + 2),
      waitDuration: const Duration(milliseconds: 500),
    ),
  );
}

/// 文字层级。**每一屏最多用三档**（标题 / 正文 / 微字），多了就是没层级。
///
/// 标题带负字距（-0.02em 上下）：大字默认字距会显得散，收紧一点才有"排过"的
/// 感觉。正文一律不收——中文一收就挤成一团。
TextTheme _textTheme(N1Colors c) => TextTheme(
  // 大字：开场的问候语、空态标题
  displaySmall: n1Text(
    size: 26,
    weight: 600,
    color: c.ink,
    height: 1.35,
    tracking: -0.022,
  ),
  headlineSmall: n1Text(
    size: 22,
    weight: 600,
    color: c.ink,
    height: 1.38,
    tracking: -0.02,
  ),
  titleLarge: n1Text(
    size: 18,
    weight: 600,
    color: c.ink,
    height: 1.4,
    tracking: -0.018,
  ),
  titleMedium: n1Text(
    size: 16,
    weight: 600,
    color: c.ink,
    height: 1.45,
    tracking: -0.012,
  ),
  titleSmall: n1Text(size: 14, weight: 600, color: c.ink, height: 1.4),

  // 正文
  bodyLarge: n1Text(size: 15.5, color: c.ink),
  bodyMedium: n1Text(size: 14.5, color: c.ink),
  bodySmall: n1Text(size: 13, color: c.dim, height: 1.6),

  // 标签 / 微字
  labelLarge: n1Text(size: 14.5, weight: 500, color: c.ink, height: 1.3),
  labelMedium: n1Text(size: 12.5, color: c.dim, height: 1.3),
  labelSmall: n1Text(size: 11, color: c.faint, height: 1.3),
);

/// 发丝分隔线。比 Divider 细，用在卡片内部。
class HairLine extends StatelessWidget {
  const HairLine({super.key, this.indent = 0, this.endIndent = 0});

  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 1, indent: indent, endIndent: endIndent,
          color: N1Colors.of(context).line);
}

/// 页面切换：淡入 + 轻微上浮。
///
/// 不用 Material 默认的横向推入——那个"整页平移"的观感很系统化，
/// 而且在桌面宽屏上位移距离会显得夸张。淡入上浮在小屏和宽屏上都成立。
class _N1PageTransition extends PageTransitionsBuilder {
  const _N1PageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 退场走反向曲线，时间也更短：进比出重要。
    final curved = CurvedAnimation(
      parent: animation,
      curve: M.out,
      reverseCurve: M.inOut.flipped,
    );

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
