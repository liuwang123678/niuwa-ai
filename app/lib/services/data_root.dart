/// 桌面端的数据放哪。
///
/// Windows 上默认全都会落在 C 盘：
///
///     C:\Users\<你>\AppData\Roaming\com.niuwa\niuwa_ai\
///         n1.db                       聊天记录 + 记忆
///         skills\                     技能文件
///         shared_preferences.json     设置
///         flutter_secure_storage.dat  API Key
///
/// 这里把它改成**跟着程序走**：`<exe 所在目录>\userdata\`。
/// 好处有三个：不占 C 盘；整个文件夹拷到别的盘或 U 盘，聊天记录和 Key
/// 一起跟着走；跟盘符无关，插到别的电脑上换成了 E: 也照样能开
/// （和用户 U 盘那套「盘符无关」的做法是同一个思路）。
///
/// ## 为什么是换 `PathProviderPlatform.instance`
///
/// 那四个文件分别由四方写：我们自己的代码、shared_preferences_windows、
/// flutter_secure_storage_windows、以及 sqflite。它们**全都**通过
/// `path_provider` 要目录，而那两个插件都没给自定义路径的口子。所以与其
/// 挨个改，不如在 `path_provider` 这一层换掉——一处生效，四处跟着走。
///
/// 这也不是 hack：`PathProviderPlatform.instance` 本来就是官方留的替换点
/// （测试里 mock 用的就是它）。
///
/// ## 为什么要探测可写
///
/// 如果程序被装在 `C:\Program Files\`，exe 旁边是写不了的（要管理员）。
/// 那种情况下不能硬用便携目录，得退回系统默认，否则 App 会以一个
/// 完全看不出原因的错误起不来。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'prefs_store.dart';

/// 便携数据目录的名字。放在 exe 旁边。
///
/// ⚠️ **不能叫 `data`**。Flutter 的 Windows 产物里本来就有一个 `data\` 目录，
/// 里面装 `flutter_assets\` 和 `icudtl.dat`——那是**程序资源**。
/// 同名的话用户数据会跟程序资源挤在一起，往后重新打包/更新覆盖 `data\`
/// 就可能顺手把聊天记录抹掉。起个不会撞的名字。
const String portableDataDirName = 'userdata';

/// 探针文件名。写完立刻删，只用来回答"这里到底能不能写"。
const String _probeName = '.n1-write-probe';

/// 试着在 [exeDir] 下准备便携数据目录。
///
/// 返回 null 表示**这里不能写**，调用方应该保持系统默认。
/// 返回的目录保证已经存在。
Future<Directory?> tryPreparePortableRoot(Directory exeDir) async {
  final target = Directory(p.join(exeDir.path, portableDataDirName));
  try {
    if (!await target.exists()) await target.create(recursive: true);
    // 光 exists 不够：目录可能存在但只读。真写一个文件才算数。
    final probe = File(p.join(target.path, _probeName));
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return target;
  } catch (e) {
    debugPrint('便携数据目录不可用（$target）：$e');
    return null;
  }
}

/// 装上便携数据目录。返回是否生效。
///
/// 只对 Windows 生效。别的平台没有"exe 旁边"这个概念：
/// 安卓的 app support 目录本来就是对的，动它只会把新用户和老用户的
/// 数据劈成两半。
///
/// **必须在 `WidgetsFlutterBinding.ensureInitialized()` 之后、
/// 以及任何一次读路径之前调用**——ensureInitialized 那一步才会把
/// 平台实现（path_provider_windows）注册进来，我们要包住的是它。
Future<bool> installPortableDataRoot() async {
  if (kIsWeb || !Platform.isWindows) return false;

  final exeDir = File(Platform.resolvedExecutable).parent;
  final root = await tryPreparePortableRoot(exeDir);
  if (root == null) return false;

  PathProviderPlatform.instance = PortablePathProvider(
    inner: PathProviderPlatform.instance,
    root: root.path,
  );

  // 光换 path_provider **不够**。`shared_preferences_windows` 在读路径那一步
  // 自己 new 了一个 `PathProviderWindows()`（具体类，不是 instance），绕开了
  // 上面这个替换点，于是设置会单独落在 C 盘：文件夹拷到别的电脑上，聊天记录、
  // 技能、API Key 都在，只有设置悄悄重置。所以它的存储层也得一起换。
  // 详见 lib/services/prefs_store.dart。
  SharedPreferencesStorePlatform.instance = await FileSharedPreferencesStore.open(
    root,
  );

  debugPrint('数据目录：${root.path}');
  return true;
}

/// 把 [PathProviderPlatform] 包一层，只改 app support 那一个方法。
///
/// 只有 [getApplicationSupportPath] 被改；其余八个原样转发给 [inner]。
/// 那些是"下载""文档""临时文件"这类目录，本来就该由系统决定，
/// 跟着 exe 走反而不对（比如临时文件应该进系统 temp，能自动清理）。
class PortablePathProvider extends PathProviderPlatform {
  /// 参数名看着是 `inner` / `root`，但下划线会被 Dart 自动剥掉，
  /// 调用方写的是 `inner:` 和 `root:`（和 provider 那几个一样的写法）。
  PortablePathProvider({required this._inner, required this._root});

  final PathProviderPlatform _inner;
  final String _root;

  /// 数据根目录。测试和排查用。
  String get root => _root;

  @override
  Future<String?> getApplicationSupportPath() async => _root;

  @override
  Future<String?> getTemporaryPath() => _inner.getTemporaryPath();

  @override
  Future<String?> getLibraryPath() => _inner.getLibraryPath();

  @override
  Future<String?> getApplicationDocumentsPath() =>
      _inner.getApplicationDocumentsPath();

  @override
  Future<String?> getApplicationCachePath() => _inner.getApplicationCachePath();

  @override
  Future<String?> getExternalStoragePath() => _inner.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() =>
      _inner.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _inner.getExternalStoragePaths(type: type);

  @override
  Future<String?> getDownloadsPath() => _inner.getDownloadsPath();
}
