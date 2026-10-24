import 'package:flutter/foundation.dart';

import '../../core/browser/browser_driver.dart';
import 'cdp_browser_driver.dart';
import 'webview_browser_driver.dart';

/// 按平台造一个浏览器驱动。造出来是"未预热"状态，还要调 `warmUp()`。
///
/// ## 两个注入点都是必需的，不是留口子玩
///
/// - `platform`：`flutter_test` 里 `defaultTargetPlatform` **默认是 android**。
///   不能注入的话，桌面分支那句 `return CdpBrowserDriver()` 永远跑不到——
///   测试会一直绿，但是**空绿**，等于没测。
/// - `desktopDriver` / `androidDriver`：让上层测试能塞一个假的，不用真起浏览器。
///
/// ## 为什么只有 Windows 走 CDP
///
/// CDP 本身是跨平台的（Chrome 在 mac/Linux 上也说这套），但这个实现里有两处
/// 是 Windows 专有：找 exe 的那串路径、以及杀进程用的 `taskkill /F /T`。
/// 这台机器上只有 Windows 能验，**宁可如实报"这个平台还没有"，也不要给一个
/// 在 mac 上默默杀不掉进程、每次泄漏一个 profile 的实现**。
BrowserDriver createBrowserDriver({
  TargetPlatform? platform,
  BrowserDriver? windowsDriver,
  BrowserDriver? androidDriver,
}) {
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.windows:
      return windowsDriver ?? CdpBrowserDriver();

    case TargetPlatform.android:
      // 驱动是 App 自己那个 WebView。⚠️ 它比 Windows 那边多一个前置条件：
      // 视图得先被 `BrowserHost` 挂进 widget 树，否则没有布局、快照读不到东西
      // （见 `BrowserHost` 的说明）。那个条件由驱动内部的 `_hostMounted` 盯着：
      // 没挂上时 [BrowserDriver.isAvailable] 是 false，工具照样注册
      // （`supportsWarmUp`），但真正调用时会被 `withDriver` 挡下并给出原因，
      // 模型不会拿着空快照瞎试。
      return androidDriver ?? WebViewBrowserDriver();

    case TargetPlatform.iOS:
      return const UnavailableBrowserDriver('这个平台上还没有浏览器功能。');

    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return const UnavailableBrowserDriver(
        '桌面端目前只有 Windows 做了浏览器功能。',
      );

    case TargetPlatform.fuchsia:
      return const UnavailableBrowserDriver('这个平台上还没有浏览器功能。');
  }
}
