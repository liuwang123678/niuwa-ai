import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../shell/app_shell.dart';
import 'n1_mark.dart';

/// 启动动画，以及它和真正界面之间的那道门。
///
/// 时序（`animationEnabled` 打开时）：
///
/// ```
///   0–300ms    牛蛙淡入，从下方浮起 6px
///   300–450ms  眨一下眼
///   450–600ms  停住
///   …          内核还没装好？轻轻呼吸着等（不转圈，不转菊花）
///   600–1020ms 飞向左上角，缩到侧栏标志那个大小
///   780–1020ms 界面在它下面显现：淡入 + 上浮 8px
/// ```
///
/// 为什么要它：`N1Runtime.boot()` 以前是在 `runApp` **前面** await 的，
/// 那段时间屏幕上什么都没有——安卓是一块死白（深色下是死黑），
/// Windows 是一个空窗口。现在先把这层画出来，让 boot 在动画背后跑，
/// 两个时间重叠掉。
///
/// **它不能拖慢启动**。动画最迟 [totalDuration] 结束；boot 更快就等动画
/// 自然走完（不到一秒），boot 更慢就停在最后一个姿势等，不会让用户对着
/// 一个凭空消失的闪屏发呆。
///
/// 落到哪里不是拍脑袋：宽屏落点取 [AppShell.railMarkCenter]，就是侧栏
/// 顶部那只真实的蛙。两边共用一个常量，将来侧栏改了，蛙也不会飞到空气里。
class SplashGate<T> extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.boot,
    required this.builder,
    required this.errorBuilder,
    this.animationEnabled = true,
  });

  /// 启动任务。它的完成时间决定动画什么时候可以收尾。
  final Future<T> boot;

  /// boot 成功后要显示的界面。
  final Widget Function(T value) builder;

  /// boot 失败时显示什么。
  final Widget Function(Object error) errorBuilder;

  /// 测试里关掉：动画走真实时钟，widget 测试不想为它 pump 一整秒。
  final bool animationEnabled;

  static const Duration intro = Duration(milliseconds: 600);
  static const Duration fly = Duration(milliseconds: 420);
  static const Duration reveal = Duration(milliseconds: 300);

  /// boot 很快时，从第一帧到界面完全显现的最长时长。
  static const Duration totalDuration = Duration(milliseconds: 1020);

  @override
  State<SplashGate<T>> createState() => _SplashGateState<T>();
}

class _SplashGateState<T> extends State<SplashGate<T>>
    with TickerProviderStateMixin {
  /// 蛙的画布边长。实际显示大小由缩放决定——这样飞到侧栏时是
  /// "缩小"，不是"换一张小图"，线条粗细连续变化。
  static const double _markSize = 96;

  /// 入场时从下方浮起多少。
  static const double _lift = 6;

  /// 页面显现时从下方浮起多少。
  static const double _pageRise = 8;

  late final AnimationController _intro;
  late final AnimationController _exit;
  late final AnimationController _reveal;
  late final AnimationController _breath;

  T? _value;
  Object? _error;

  /// 界面树只在第一次显现时构建一次，之后一直复用。
  /// 每帧重建 `N1App` 会把 provider 的 `create` 重新跑一遍，状态全丢。
  Widget? _page;

  bool _exiting = false;
  bool _revealed = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(vsync: this, duration: SplashGate.intro);
    _exit = AnimationController(vsync: this, duration: SplashGate.fly);
    _reveal = AnimationController(vsync: this, duration: SplashGate.reveal);
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    _intro.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // 内核还没装好就先轻轻呼吸着等。比一张静止的图好；也比转圈诚实，
      // 它确实是在等，不是在转。
      if (_value == null && _error == null && !_exiting) {
        _breath.repeat(reverse: true);
      }
      _maybeFinish();
    });

    _exit.addListener(() {
      // 飞行到三成时页面开始显现。再早，页面会抢在蛙落位之前出现；
      // 再晚，蛙已经到了角上而页面还没出来，中间空一拍。
      if (!_revealed && _exit.value > 0.28) {
        _page = widget.builder(_value as T);
        setState(() => _revealed = true);
        _reveal.forward();
      }
    });

    _exit.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _finished = true);
      }
    });

    if (widget.animationEnabled) {
      _intro.forward();
    } else {
      _intro.value = 1;
    }

    _load();
  }

  @override
  void dispose() {
    _intro.dispose();
    _exit.dispose();
    _reveal.dispose();
    _breath.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final value = await widget.boot;
      if (!mounted) return;
      setState(() => _value = value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
    _maybeFinish();
  }

  /// 两个条件都满足才能收尾：**动画走完了**，**内核装好了**。
  void _maybeFinish() {
    if (!mounted || _exiting || _finished || _error != null) return;
    if (_value == null || !_intro.isCompleted) return;

    _exiting = true;
    _breath.stop();
    _breath.value = 0;

    if (!widget.animationEnabled) {
      _page = widget.builder(_value as T);
      setState(() {
        _revealed = true;
        _finished = true;
      });
      return;
    }

    _exit.forward();
  }

  @override
  Widget build(BuildContext context) {
    // 裸 runApp 的根上没人建 MediaQuery 和 Directionality（那是 WidgetsApp
    // 的活），而下面要读屏幕尺寸、深浅色，错误页里还会有文字。这里补一份。
    //
    // 错误页也包在里面：真实的 `_BootFailure` 自带 MaterialApp，包一层没影响；
    // 但换个不带 MaterialApp 的 errorBuilder 就会因为找不到 Directionality
    // 而再炸一次——那时候屏幕上就是真的一片空白了。
    return MediaQuery.fromView(
      view: View.of(context),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            // 起不来就直接把原因摊给用户，不再演动画。
            if (_error != null) return widget.errorBuilder(_error!);
            return _buildBody(context);
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final background = dark ? kDarkBg : kNeutral50;

    final wide = size.width >= AppShell.wideBreakpoint;
    final rest = Offset(size.width / 2, size.height / 2);

    // 窄屏没有侧栏，也就没有那只真实的蛙可以落。仍然往左上角去——
    // 那是"收起"的方向，比原地淡出更像一次落地。
    final target = wide
        ? AppShell.railMarkCenter
        : const Offset(
            S.x5 + AppShell.railMarkSize / 2,
            S.x5 + AppShell.railMarkSize / 2,
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_page != null) _buildPage(),
        if (!_finished)
          AnimatedBuilder(
            animation: Listenable.merge([_intro, _exit, _breath, _reveal]),
            builder: (context, _) {
              final intro = _intro.value;
              final appear = Curves.easeOutCubic.transform(
                (intro / 0.5).clamp(0.0, 1.0),
              );
              final blink = _blinkAt(intro);
              final fly = Curves.easeInOutCubic.transform(_exit.value);

              // 等一下的时候轻轻呼吸，幅度 1.2%——只够看出"还活着"。
              final breath =
                  1 + 0.012 * Curves.easeInOut.transform(_breath.value);

              final center = Offset.lerp(rest, target, fly)!;
              final scale =
                  lerpDouble(0.96, 1, appear)! *
                  lerpDouble(1, AppShell.railMarkSize / _markSize, fly)! *
                  breath;

              return Stack(
                children: [
                  // 底色跟页面显现同步淡出。蛙这时还在飞，
                  // 看起来就是在正在出现的界面上方落到左上角。
                  Positioned.fill(
                    child: Opacity(
                      opacity:
                          1 - Curves.easeOutCubic.transform(_reveal.value),
                      child: ColoredBox(color: background),
                    ),
                  ),
                  Positioned(
                    left: center.dx - _markSize / 2,
                    top: center.dy - _markSize / 2 + _lift * (1 - appear),
                    width: _markSize,
                    height: _markSize,
                    child: Opacity(
                      opacity: appear,
                      child: Transform.scale(
                        scale: scale,
                        child: _buildFrog(blink),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildPage() {
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_reveal.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, _pageRise * (1 - t)),
            child: child,
          ),
        );
      },
      child: _page,
    );
  }

  /// 眨眼进度：0 = 睁着，1 = 完全闭上。
  ///
  /// 闭得比睁得快（闭占 40%，睁占 60%）。两边一样快的话会显得像机械开关。
  double _blinkAt(double t) {
    const start = 0.50;
    const end = 0.75;
    if (t <= start || t >= end) return 0;

    final k = (t - start) / (end - start);
    if (k < 0.4) return _smooth(k / 0.4);
    return 1 - _smooth((k - 0.4) / 0.6);
  }

  double _smooth(double x) => Curves.easeInOut.transform(x.clamp(0.0, 1.0));

  /// 蛙本体 + 眼皮。
  ///
  /// 为什么眼皮是叠上去的实心圆而不是改 painter：瞳孔是**挖空**的，
  /// 用和蛙同色的圆从瞳孔顶部往下盖，盖满时瞳孔就"消失"了——在单色
  /// 几何造型里，这读起来就是闭眼。改 painter 要动 [FrogShape] 的形状
  /// 定义，会把图标导出那条链也牵连进来。
  Widget _buildFrog(double blink) {
    const shape = FrogShape.standard;
    final pupil = shape.pupilR * _markSize * 2;

    Widget lid(double eyeX) => Positioned(
      left: eyeX * _markSize - pupil / 2,
      top: shape.eyeY * _markSize - pupil / 2,
      width: pupil,
      height: pupil,
      child: ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: blink.clamp(0.0, 1.0),
          child: SizedBox(
            width: pupil,
            height: pupil,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                // 必须和 [N1Mark] 的默认色是同一个：侧栏那只没有传 color。
                // 用主题色的话，深色下落地会跳一下色。
                color: kAccent,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );

    return SizedBox(
      width: _markSize,
      height: _markSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const N1Mark(size: _markSize),
          if (blink > 0) ...[
            lid(shape.eyeLeftX),
            lid(shape.eyeRightX),
          ],
        ],
      ),
    );
  }
}
