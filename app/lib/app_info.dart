/// App 的身份信息。
library;

/// 版本号。**以后更新就改这一个数**，界面上的名字跟着变（v1、v2、v3……）。
///
/// 名字是拼出来的而不是写死的，就是为了让"改版本"只发生在一处。
/// 原生那边拼不了 Dart 常量，所以改名时下面这几处要一起跟：
///
///   - `windows/runner/main.cpp`          窗口标题
///   - `windows/runner/Runner.rc`         ProductName / FileDescription
///                                        （任务管理器、exe 右键属性里看得到）
///   - `android/app/src/main/AndroidManifest.xml` 的 `android:label`
///                                        （桌面图标下面那行字）
///   - `pubspec.yaml` 的 `version`        安卓的 versionName/versionCode。
///                                        用户在系统设置里看"应用版本"看的是它，
///                                        跟 [appVersionNumber] 对不上会显得很怪。
///
/// **这几处都是手工跟的，没有自动校验**——改完 `flutter build apk` 之后
/// `aapt dump badging` 读一遍 `application-label` 和 `versionName` 对一下，最省事。
///
/// Dart 包名 `niuwa_ai`、exe 文件名 `niuwa_ai.exe`、文件夹名都是**标识**不是
/// 名字，不跟着改——改了要动一长串 import 和打包脚本，换不来任何用户可见的好处。
const int appVersionNumber = 14;

/// 显示名。
const String appName = 'niuwa v$appVersionNumber';

/// 开发者署名。关于页里挂着，网站落地页也用同一个。
const String appAuthor = '刘汪承睿';
