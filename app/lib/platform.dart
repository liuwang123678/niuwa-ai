import 'package:flutter/foundation.dart';

/// 是不是桌面端。
///
/// 用 `defaultTargetPlatform` 而不是 `dart:io` 的 `Platform.isWindows`：
/// 后者在安卓 AOT 编译时整个分支会被消掉（包体里连字符串都找不到），
/// 是 A1 项目上踩过的坑。
///
/// 判断"要不要弹选择来源的菜单""要不要拦回车"这类行为时用它。
/// ⚠️ flutter_test 里 `defaultTargetPlatform` **默认是 android**，
/// 所以桌面的分支不 override 就永远测不到——它会一直绿，但是空绿。
bool get isDesktopPlatform {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}
