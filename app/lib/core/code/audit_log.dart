/// 跑命令 / 动文件这件事的流水账。
///
/// ## 为什么要有它
///
/// 前面几层防线（审批门、受保护路径、超时杀进程）拦的都是**当下**。这一层管的是
/// **事后**：用户过两天想不起来"它到底跑过什么"，或者觉得电脑上多了个文件——
/// 要有个地方能查。
///
/// 另外一个作用是**演示**。告诉别人"它能在你电脑上跑东西"时，一份"什么时候、
/// 跑了什么、你点没点同意、退出码几"的流水比任何说明都直观。
///
/// ⚠️ **它本身不是安全措施**：日志挡不住任何东西。别把它算进"防护层"里
/// ——跟 `danger_command.dart` 一样，那些是触发器，不是边界。
library;

import 'dart:convert';

/// 这次调用最后是怎么处理的。
enum CodeDecision {
  /// 跑了（可能成功可能失败，看 [CodeAuditEntry.ok]）。
  ran,

  /// 跑了，而且是**自动模式免掉确认**的。
  ///
  /// 跟 [ran] 分开记的理由：用户点过同意、和用户压根没被问过，事后是两种
  /// 完全不同的责任。日志里混成一个词，等到真出事那天就查不出"这是它自己
  /// 干的还是我放行的"。
  autoRan,

  /// 用户点了「不要」。
  denied,

  /// 等用户确认等到超时。
  timedOut,

  /// 需要确认，但这个环境没有确认的通道。**也是"没执行"**。
  unavailable;

  /// 写进日志文件的那个词。
  ///
  /// 用固定英文短词而不是中文：这份日志是给人 grep 的，也可能是给别的工具
  /// 读的。中文要对齐、要处理编码，而"判没判拒绝"是它唯一要回答的问题。
  String get id => switch (this) {
    CodeDecision.ran => 'ran',
    CodeDecision.autoRan => 'auto-ran',
    CodeDecision.denied => 'denied',
    CodeDecision.timedOut => 'timedOut',
    CodeDecision.unavailable => 'no-ask',
  };
}

/// 一条记录。
class CodeAuditEntry {
  const CodeAuditEntry({
    required this.at,
    required this.tool,
    required this.decision,
    this.detail = '',
    this.workingDirectory,
    this.exitCode,
    this.ok,
    this.duration,
  });

  final DateTime at;

  /// 工具名（`run_command` / `write_file` …）。
  final String tool;

  final CodeDecision decision;

  /// 最能说明这次干了什么的一句话：命令原文、文件路径、脚本首行。
  ///
  /// **原样，不摘要。** 跟审批弹窗同一个理由：`del /s /q D:\重要资料` 缩成
  /// "删除操作"之后，这份日志就只剩下"它动过东西"这个信息量。
  final String detail;

  /// 命令在哪个目录下跑的。光有命令看不出 `rm -rf *` 删的是哪儿。
  final String? workingDirectory;

  final int? exitCode;

  /// 跑完了没有、成没成。**没跑（被拒/超时）时是 null**，不是 false——
  /// "没成功"和"压根没执行"是两回事，混起来会让日志骗人。
  final bool? ok;

  final Duration? duration;

  /// 一行。字段之间用 tab 分隔，方便 grep 和切。
  ///
  /// ⚠️ [detail] **放在最后一个字段**：命令里本来就可能有 tab。
  /// 放中间的话，那种行会被切成错位的字段，比不解析还糟。
  String toLine() {
    final parts = <String>[
      _stamp(at),
      decision.id,
      tool,
      switch (ok) {
        true => 'ok',
        false => 'fail',
        null => '—',
      },
      'exit=${exitCode ?? '—'}',
      'took=${duration == null ? '—' : '${duration!.inMilliseconds}ms'}',
      'cwd=${workingDirectory ?? '—'}',
      detail,
    ];
    return parts.join('\t');
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

/// 从参数里挑出"最能说明这次干了什么"的那一段。
///
/// 顺序按"人看一眼就懂"排：命令 → 文件路径 → 脚本 → 网址 → 查询词。
/// 挑不到就返回空串（由调用方决定要不要退回整张参数表）。
///
/// ⚠️ 跟界面上那两处预览（`ToolTraceTile._preview`、`ToolApprovalDialog.previewOf`）
/// **看着像，但故意没合并**：它们要的东西不一样。弹窗那个**绝不能为空**
/// （挑不到得把整张参数表铺出来给用户看），痕迹那个挑不到要返回 null
/// （界面上那一截干脆不显示）。这里是"给日志用"，空了就退回 JSON。
/// 合并成一个函数的代价是三个地方各自妥协，那比三份 20 行更糟。
String toolDetail(Map<String, Object?> input) {
  for (final key in const ['command', 'path', 'source', 'url', 'query']) {
    final value = input[key];
    if (value is String) {
      final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (flat.isNotEmpty) return flat;
    }
  }
  return '';
}

/// 挑不到具体字段时的兜底：把参数表压成一行 JSON。
String toolDetailOrJson(Map<String, Object?> input) {
  final detail = toolDetail(input);
  if (detail.isNotEmpty) return detail;
  try {
    return jsonEncode(input);
  } catch (_) {
    // 参数是从 JSON 解出来的，理论上不会序列化不了。真到这儿了也别抛——
    // 日志写不进去不该把一次工具调用带崩。
    return input.toString();
  }
}

/// 记账的地方。
///
/// 只有"加一条"这一个动作：读这份日志的是人（记事本打开、grep），
/// 程序自己不需要把它读回来。所以没有查询接口——有的话就得定义排序、
/// 分页、时间范围，而没有人会用。
abstract class CodeAuditLog {
  Future<void> record(CodeAuditEntry entry);
}

/// 什么都不做。测试和"用户不想要日志"时用。
class NoopCodeAuditLog implements CodeAuditLog {
  const NoopCodeAuditLog();

  @override
  Future<void> record(CodeAuditEntry entry) async {}
}
