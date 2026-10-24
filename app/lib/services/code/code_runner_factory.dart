import 'package:flutter/foundation.dart';

import '../../core/code/code_runner.dart';
import 'process_code_runner.dart';
import 'webview_js_runner.dart';

/// 按平台造一个代码执行器。造出来是"未预热"状态，还要调 `warmUp()`。
///
/// 形状跟 `createBrowserDriver` 一致，两个注入点的理由也一样：
///
/// - `platform`：`flutter_test` 里 `defaultTargetPlatform` **默认是 android**。
///   不能注入的话，桌面那分支永远跑不到——测试全绿，但是**空绿**。
/// - `desktopRunner` / `androidRunner`：让上层测试塞假的，不用真起进程。
///
/// ## 安卓那一路是 JS，不是"没有"
///
/// 安卓上没有 shell、没有 Python 和 Node，能跑的是 WebView 里的 JavaScript——
/// 那也是一个完整的代码执行能力，只是语言只有一门、没有文件系统。
/// 所以这里给的是真实现，不是"假装能用的空壳"（空壳的表现是模型调 `run_code`
/// 拿到空结果然后反复重试到撞回合上限，比"看不见这个工具"糟得多）。
///
/// ⚠️ 造出来是**未预热**状态，`isAvailable` 还是 false——这是对的，
/// 第一个回合里 `installCodeTools` 会按"还没探到"把这工具放着，
/// 预热完之后的回合再补上。见 `N1Session.installCodeTools` 里的按名字记账。
CodeRunner createCodeRunner({
  TargetPlatform? platform,
  CodeRunner? windowsRunner,
  CodeRunner? androidRunner,
}) {
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.windows:
      return windowsRunner ?? ProcessCodeRunner();

    case TargetPlatform.android:
      return androidRunner ?? WebViewJsRunner();

    case TargetPlatform.iOS:
      return const UnavailableCodeRunner('这个平台上还不能跑代码。');

    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      // ⚠️ 底层是能跨平台的（`Process.start` 哪都有），但这个实现里有两处
      // Windows 专有：杀进程用的 `taskkill /F /T`、以及路径里那些反斜杠。
      // 这台机器上只有 Windows 能验，**宁可如实说没有，也不要给一个在 mac
      // 上默默杀不掉进程、每次超时留一个死循环脚本的实现**。
      return const UnavailableCodeRunner('桌面端目前只有 Windows 做了跑代码。');

    case TargetPlatform.fuchsia:
      return const UnavailableCodeRunner('这个平台上还不能跑代码。');
  }
}
