# 这是上游包的一份本地副本，动过两处

上游：`flutter_secure_storage_windows` 4.2.2（BSD 3-Clause，见同目录 `LICENSE`）。
由 `pubspec.yaml` 里的 `dependency_overrides` 挂进来。

## 为什么

上游的 pubspec 在 windows 平台上**同时**声明了两个东西：

```yaml
windows:
  pluginClass: FlutterSecureStorageWindowsPlugin   # C++ 插件
  dartPluginClass: FlutterSecureStorageWindows     # 纯 Dart
```

Flutter 会编译依赖图里**每一个**声明了原生 `pluginClass` 的插件。哪怕我们一次都不调它，
`flutter build windows` 也会去编那个 C++ 文件。

而那个 C++ 文件第 6 行是 `#include <atlstr.h>`，并且真的用了 ATL 的字符集转换宏
（`CA2T` / `CT2A` 等 5 处）。ATL 不在随 VS 生成工具默认安装的组件里，本机就没装，于是：

```
error C1083: 无法打开包括文件: "atlstr.h"
Build process failed.
```

**试过但没用**：把 `flutter_secure_storage` 从 9.2.4 升到 11.2.0。
11.x 拉的 Windows 后端是 4.x，虽然多了一份纯 Dart 的 FFI 实现，但 `pluginClass` 那行一直没删，
C++ 照样编，照样死在同一行上。这条是实测证伪的，不是推测。

## 改了什么

只有两处，都在这个副本里：

1. `pubspec.yaml` — 删掉 `pluginClass: FlutterSecureStorageWindowsPlugin` 一行，
   保留 `dartPluginClass: FlutterSecureStorageWindows`。
2. 删掉整个 `windows/` 目录（C++ 源码 + CMakeLists）。

保留的 Dart 类 `lib/src/flutter_secure_storage_windows_ffi.dart` 是真的实现：
`extends FlutterSecureStoragePlatform`，自带 `registerWith()`，
底层用 `ffi` + `win32` 直接调 `CryptProtectData` / `CryptUnprotectData`（Windows DPAPI）。

## ⚠️ 这意味着什么

我们跑的**不是**上游 C++ 那条路径，是 Dart FFI 那条。两条路径都叫"Windows DPAPI"，
但实现不同、写的存储位置可能也不同。

**后果**：如果以后要卸载这份 override 改回上游，用户已经存好的 API Key
有可能读不出来（换了后端）。这个 App 只存一个 Key，重填一次就行，
但要知道会有这么一下。

## 怎么升级

```bash
# 1. 看上游出了什么新版本
curl -s https://pub.dev/api/packages/flutter_secure_storage_windows | \
  python -c "import sys,json; print(json.load(sys.stdin)['latest']['version'])"

# 2. 覆盖副本（注意排除我们自己加的这个 README）
rm -rf third_party/flutter_secure_storage_windows
cp -r "$PUB_CACHE/hosted/pub.dev/flutter_secure_storage_windows-<新版本>" \
      third_party/flutter_secure_storage_windows
chmod -R u+w third_party/flutter_secure_storage_windows

# 3. 重新施加那两处改动：删 pluginClass 行、删 windows/ 目录
#    （抄上面"改了什么"一节）

# 4. 验证
flutter pub get
flutter build windows --debug
```

顺带确认新版本的 pubspec 里 `dartPluginClass` 还在。哪天上游把它也删了，
这份 override 就没意义了——那时候应该反过来去装 ATL 组件。

## 另一条路：装 ATL

如果不想维护 fork，装 VS 的 ATL 组件也能解决，一次装好、永久有效，
而且对所有需要 ATL 的 Flutter 插件都管用：

```powershell
# 需要管理员权限
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe" modify `
  --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
  --add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart
```

两条路都走通的话，装 ATL 更省心（不用跟上游版本）。当前选 fork 是因为不想让用户提权。
