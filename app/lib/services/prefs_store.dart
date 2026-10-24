/// 设置落在哪个文件里。
///
/// 这个文件的存在理由只有一个：把 `shared_preferences` 的落盘位置从 C 盘
/// 拉回到我们自己控制的目录。原因见 [FileSharedPreferencesStore] 的文档。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// GetAllParameters / ClearParameters / PreferencesFilter 不在上面那个库里
// export，得单独 import 进来。
import 'package:shared_preferences_platform_interface/types.dart';

/// 自己实现一份 `SharedPreferencesStorePlatform`，落到指定目录。
///
/// ## 为什么非做不可
///
/// 这个 App 的数据是靠**换掉 `PathProviderPlatform.instance`** 来做到"跟着 exe
/// 走"的（见 `data_root.dart`）：聊天记录、技能文件、API Key 都吃这一套，
/// 因为它们最终都问 `path_provider` 要 `getApplicationSupportDirectory()`。
///
/// **只有设置不吃。** `shared_preferences_windows` 在读路径那一步写的是：
///
/// ```dart
/// pathProvider = pathProvider ?? PathProviderWindows();
/// ```
///
/// 它 new 的是**具体类**，不是 `PathProviderPlatform.instance`——所以换 instance
/// 那一招对它完全无效，`shared_preferences.json` 永远落在
/// `C:\Users\<用户>\AppData\Roaming\com.niuwa\niuwa_ai\`。
///
/// 发作形态很难看：便携版整个文件夹拷到别的电脑上，聊天记录在、Key 在、技能在，
/// **只有供应商选择、温度、自定义地址悄悄重置了**，而且不报任何错。
///
/// ## 为什么不干脆不用 shared_preferences
///
/// `SettingsStore` 收的就是一个 `SharedPreferences`，测试也是围着它写的。
/// 换掉存储层比换掉 `SettingsStore` 的接口小得多：这里塞一个实现上去，
/// 上面一行都不用动。
///
/// ## 键的形态
///
/// **原样存、带前缀**：`SharedPreferences` 拿到的是 `flutter.settings.provider_id`
/// 这样的键，剥前缀是它自己的事。所以 `getAll` / `clear` 也要按
/// `flutter.` 前缀过滤——口径照抄 `InMemorySharedPreferencesStore`，
/// 改了口径老键就读不出来。
class FileSharedPreferencesStore extends SharedPreferencesStorePlatform {
  FileSharedPreferencesStore._(this._file, this._data);

  /// legacy API 一直用的前缀。照抄，别改。
  static const String defaultPrefix = 'flutter.';

  /// 文件名。跟 `shared_preferences_windows` 原来用的一致，方便对账。
  static const String fileName = 'shared_preferences.json';

  final File _file;
  final Map<String, Object> _data;

  /// 从这个目录读设置。文件不存在、或者读坏了，都当"空设置"起步。
  ///
  /// 读坏了**不能把 App 拖死**：设置全丢也比起不来强，用户重选一次就是了。
  static Future<FileSharedPreferencesStore> open(Directory dir) async {
    final file = File(p.join(dir.path, fileName));
    final data = <String, Object>{};
    try {
      if (await file.exists()) {
        final decoded = json.decode(await file.readAsString());
        if (decoded is Map) data.addAll(decoded.cast<String, Object>());
      }
    } catch (e) {
      debugPrint('设置文件读不出来，当空的用：${file.path} — $e');
    }
    return FileSharedPreferencesStore._(file, data);
  }

  /// 现在的值。排查用，别拿它改。
  Map<String, Object> get snapshot => Map.unmodifiable(_data);

  /// 全量落盘。每次改动都整份重写——设置统共就几项，不值得为增量写做优化。
  Future<bool> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(json.encode(_data), flush: true);
      return true;
    } catch (e) {
      // 写不进去（磁盘满、没权限）不该让调用方崩：内存里那份还是对的，
      // 这一次会话照常用，只是下次启动看到的还是旧值。
      debugPrint('设置写不进去：${_file.path} — $e');
      return false;
    }
  }

  @override
  Future<bool> remove(String key) async {
    _data.remove(key);
    return _flush();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    // valueType 在这里用不上：JSON 自己分得清 bool / num / String / List。
    _data[key] = value;
    return _flush();
  }

  @override
  Future<bool> clear() =>
      clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: defaultPrefix)));

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    _data.removeWhere(
      (key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key)),
    );
    return _flush();
  }

  @override
  Future<Map<String, Object>> getAll() =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: defaultPrefix)));

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async {
    final filter = parameters.filter;
    return Map<String, Object>.from(_data)..removeWhere(
      (key, _) =>
          !key.startsWith(filter.prefix) ||
          (filter.allowList != null && !filter.allowList!.contains(key)),
    );
  }
}
