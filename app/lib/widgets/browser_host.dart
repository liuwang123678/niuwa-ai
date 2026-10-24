import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/browser/browser_driver.dart';
import '../services/browser/webview_browser_driver.dart';

/// 安卓上那个浏览器的**挂载点**。
///
/// ## 为什么需要这个东西
///
/// 直觉上"后台跑个 WebView"应该就是造个 controller、调 `runJavaScript`，
/// 跟界面无关。**在安卓上不是这样。**
///
/// WebView 是个真的 `android.webkit.WebView`，它必须被 attach 进窗口、被量过
/// 尺寸，才能正常干活。不挂的话：
///
/// - `element.getClientRects()` 全空 → **快照读到零个元素**
/// - `window.innerHeight` 是 0 → 滚动脚本 `scrollBy(0, 0)` 原地踏步
/// - 懒加载不触发 → 页面永远只有骨架
///
/// 最坏的地方在于这些**都不报错**。模型拿到一张空快照，会以为是自己选择器
/// 写错了，换着花样重试，直到回合数烧完。所以"挂一块移出屏幕的 WebView"
/// 不是可选的优化，是这个功能能不能用的前提。
///
/// ## 为什么要真实尺寸
///
/// 不能用 `Offstage`（不 paint，可能整个跳过量尺寸）、不能用 `SizedBox(1x1)`
/// （视口太小，`innerHeight` 也就 1）。要的是**跟一台真手机一样大的视口**，
/// 只是画在屏幕外面。
///
/// ## 这个挂法还没在真机上验过
///
/// 到写这段为止手上没有能连的安卓设备，所以"移出屏幕 + Clip.none 的 WebView
/// 在 HyperOS 上是不是照常有布局"这句话**没有实测支撑**。真机验收的第一个
/// 检查点就是它：读 `window.innerHeight`，是 0 就说明这个挂法不成立，得换
/// `flutter_inappwebview`（它有官方的不挂 UI 也能跑的路子）。
class BrowserHost extends StatefulWidget {
  const BrowserHost({super.key, required this.driver, required this.child});

  /// 当前的浏览器驱动。不是 [WebViewBrowserDriver] 时这个组件是透明的
  /// （Windows 走 CDP，那边自己拉 Edge，不需要挂任何东西）。
  final BrowserDriver driver;

  /// 被包住的真实界面。
  final Widget child;

  /// 虚拟视口的大小。取的是常见手机的逻辑分辨率——关键不是这个数值本身，
  /// 是它**别是 0 也别太窄**（窄了会命中站点的移动版布局，那是另一套 DOM）。
  static const Size viewport = Size(390, 844);

  @override
  State<BrowserHost> createState() => _BrowserHostState();
}

class _BrowserHostState extends State<BrowserHost> {
  WebViewController? _controller;
  WebViewBrowserDriver? _driver;

  @override
  void initState() {
    super.initState();

    final driver = widget.driver;
    if (driver is! WebViewBrowserDriver) return;
    _driver = driver;

    // 先报"挂上了"，再等预热。顺序不能反：预热是 boot 阶段就发出去的，
    // 有可能已经跑完了，而 [WebViewBrowserDriver.isAvailable] 要两个条件都满足。
    driver.markHostMounted();

    // `warmUp()` 幂等（驱动里 `_warming ??=`），所以这里跟 boot 那次是同一个
    // future，不会拉起第二个 WebView。它承诺不抛。
    unawaited(
      driver.warmUp().then((_) {
        if (!mounted) return;
        // 预热失败时 controller 是 null，那就什么都不挂——驱动那边会给出
        // 不可用的原因，工具层据此不注册 browser_*。
        setState(() => _controller = driver.controller);
      }),
    );
  }

  @override
  void dispose() {
    _driver?.markHostUnmounted();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    // 非安卓平台：原样透传。`StackFit.expand` 是为了让 child 拿到的约束跟
    // 以前一模一样（tight 满屏），不然 Scaffold 的尺寸语义会变。
    return Stack(
      fit: StackFit.expand,
      // `Clip.none` 是刻意的。用默认的 `Clip.hardEdge` 时，这块平台视图会落在
      // 裁剪区外面——而"被裁掉的平台视图"在安卓上是出过布局异常的一类情况，
      // 我不想在这儿踩一个没法在本机测的坑。它本来就在屏幕外，不裁也看不见。
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (controller != null)
          Positioned(
            // 往左推一个视口的宽度再多一点，确保整块都在屏幕外。
            left: -(BrowserHost.viewport.width + 64),
            top: 0,
            child: SizedBox.fromSize(
              size: BrowserHost.viewport,
              child: WebViewWidget(controller: controller),
            ),
          ),
      ],
    );
  }
}
