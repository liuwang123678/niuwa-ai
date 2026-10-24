import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/n1_core.dart';

/// 把备份放在 `<appSupport>/backups/`。
///
/// 放应用目录而不是目标文件旁边（比如原文件旁边生成 `报告.txt.bak`）：
/// 那样会在用户的桌面、文档里撒一堆 `.bak`，他删也不是留也不是。
/// 集中放一处，结果里告诉模型备份在哪，用户要找也找得着。
class LocalFileBackupStore implements FileBackupStore {
  /// [dir] 是备份目录。跟 `SkillLoader` 一样注入 [Directory] 而不是内部
  /// 调 `path_provider`——测试塞个临时目录就能跑真的读写，
  /// 不用为了一个路径去 mock 平台通道。
  LocalFileBackupStore({
    required this.dir,
    this.keep = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static Future<LocalFileBackupStore> forApp() async {
    final support = await getApplicationSupportDirectory();
    return LocalFileBackupStore(dir: Directory(p.join(support.path, 'backups')));
  }

  final Directory dir;

  /// 最多留多少份。超了就按时间从旧到新删。
  ///
  /// 这条不能省：用户天天让 AI 改同一个脚本，每次覆盖都留一份，
  /// 一年下来上千份，把磁盘吃干净了用户还不知道东西在哪。
  final int keep;

  final DateTime Function() _clock;

  @override
  Future<FileBackup?> backup(String path) async {
    final source = File(path);
    if (!await source.exists()) return null;

    await dir.create(recursive: true);
    final at = _clock();
    final copy = File(p.join(dir.path, _backupName(path, at)));
    await source.copy(copy.path);
    return FileBackup(original: path, copyPath: copy.path, at: at);
  }

  @override
  Future<int> prune() async {
    if (!await dir.exists()) return 0;
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.bak')) files.add(entity);
    }
    if (files.length <= keep) return 0;

    // 文件名里的时间戳是 `yyyyMMdd-HHmmss-SSS`，**定长且高位在前**，
    // 所以按名字排序就等于按时间排序，不用每个文件去 stat 一遍。
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    var removed = 0;
    for (final file in files.take(files.length - keep)) {
      try {
        await file.delete();
        removed++;
      } catch (_) {
        // 删不掉就算了（被占用之类）。为了清老备份把一次正常的写入搞失败，不值。
      }
    }
    return removed;
  }

  /// `报告.py.20261010-213045-123.ab12cd34.bak`
  ///
  /// 结构是 `原名.时间戳.路径哈希.bak`：
  /// - 保留原文件名和扩展名，用户翻备份目录时一眼知道这是什么；
  /// - 时间戳定长可排序，[prune] 靠它；
  /// - 哈希是给**同名文件**准备的——两个不同目录里都叫 `config.json`，
  ///   光靠名字会互相覆盖，那就不是备份了。
  static String _backupName(String originalPath, DateTime at) {
    final base = _sanitize(p.basename(originalPath));
    return '$base.${_stamp(at)}.${_pathHash(originalPath)}.bak';
  }

  static String _sanitize(String name) {
    // 中文（一-鿿）留着，其余不是字母数字点横线的都换成下划线。
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._\-一-鿿]'), '_');
    if (cleaned.isEmpty) return 'file';
    // 太长会顶到 Windows 的路径长度限制，截断就够——
    // 认得出是什么文件靠的就是前面那几个字。
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60);
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}'
        '-${three(t.millisecond)}';
  }

  /// FNV-1a，32 位，八位十六进制。
  ///
  /// 自己写一个而不是用 `String.hashCode`：Dart 的 `hashCode` **不保证跨进程
  /// 稳定**，换个版本、重开一次进程都可能变。而这里要的是"同一个路径永远算出
  /// 同一个名字"，不然重启一次备份文件就对不上号了。
  static String _pathHash(String path) {
    var hash = 0x811c9dc5;
    for (final unit in path.toLowerCase().codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
