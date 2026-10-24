/// 覆盖文件之前先留一份。
///
/// 这是"安全兜底"里最实在的一层：审批弹窗管的是"要不要做"，这一层管的是
/// **做砸了能不能退回去**。用户说"把那个配置改一下"的时候，真正让他心里
/// 有底的是"原来的那份还在"。
library;

/// 一份备份的记录。
class FileBackup {
  const FileBackup({
    required this.original,
    required this.copyPath,
    required this.at,
  });

  /// 被备份的原文件（绝对路径）。
  final String original;

  /// 备份到哪儿了。要在结果里告诉模型，这样用户问"原来那份呢"有答案。
  final String copyPath;

  final DateTime at;
}

abstract class FileBackupStore {
  /// 覆盖 [path] 之前存一份。
  ///
  /// **文件不存在时返回 null**——没什么可备份的，这不是失败。
  /// 真的是失败（磁盘满了、备份目录写不进去）要**抛异常**：静默跳过的话，
  /// 结果里会写"已备份"，而用户以为有回滚阀，实际上没有。
  Future<FileBackup?> backup(String path);

  /// 清理旧备份，返回删掉几个。
  ///
  /// 留着是因为这份东西**只会涨不会消**：每次覆盖都留一份，用户天天让 AI 改脚本，
  /// 一年下来能把磁盘吃干净。
  Future<int> prune();
}
