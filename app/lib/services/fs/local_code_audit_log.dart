import 'dart:io';

import '../../core/n1_core.dart';

/// 把审计流水追加到 `<appSupport>/code-audit.log`。
///
/// 一行一条，追加写。**不做数据库**：这份东西的读者是人——想不起来"它昨天
/// 跑过什么"的时候拿记事本打开看一眼，或者 grep 一个文件名。用 SQLite 存起来
/// 只会让"怎么查"变成一个需要学的问题，而收益是零。
///
/// ⚠️ **这个文件是**明文**的**：命令里如果带 token、路径带用户名，就都在里面。
/// 这是刻意的取舍——日志的意义就是能查，加密了用户自己都看不了；而它躺在
/// appSupport 里，跟聊天数据库同一层敏感度。别把它当成可以随便发出去的东西。
class LocalCodeAuditLog implements CodeAuditLog {
  /// 时间戳由**调用方**（`ToolRegistry._audit`）填进 [CodeAuditEntry] 里，
  /// 这里不自己取——一份日志里的时间得来自同一个地方，不然"两条挨着的记录
  /// 时间差是负的"这种事就会出现。
  LocalCodeAuditLog({required this.file, this.maxBytes = 256 * 1024});

  final File file;

  /// 超过这个大小就砍掉旧的一半。
  ///
  /// 不能省：用户天天让 AI 跑命令，一年下来这个文件能把磁盘吃掉一块，
  /// 而且他根本不知道有这个东西在长。256 KiB 大约是几千条，够查很久了。
  final int maxBytes;

  @override
  Future<void> record(CodeAuditEntry entry) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString('${entry.toLine()}\n', mode: FileMode.append);
      await _trimIfNeeded();
    } catch (_) {
      // 磁盘满、权限不够、路径被人占了……都**不该把一次工具调用带崩**。
      // 日志是旁路。上层（`ToolRegistry._audit`）还会再兜一道并把原因说出来。
      //
      // 这里不 debugPrint：那是给开发看的，而这个是用户环境里可能反复发生的
      // 情况（比如只读盘），刷屏没意义。
    }
  }

  /// 太大了就**留后半截**。
  ///
  /// 留新的而不是留旧的：查日志的人几乎总是在查"最近它干了什么"，
  /// 而最早那几百条早在几个月前就没用了。
  Future<void> _trimIfNeeded() async {
    final length = await file.length();
    if (length <= maxBytes) return;

    final lines = await file.readAsLines();
    final keep = lines.sublist(lines.length ~/ 2);
    await file.writeAsString('${keep.join('\n')}\n');
  }
}
