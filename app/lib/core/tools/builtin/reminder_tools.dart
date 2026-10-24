import '../../reminder/reminder.dart';
import '../n1_tool.dart';
import '../tool_context.dart';

/// `say` 的字数上限。
///
/// 通知栏放不下更长的，而且模型偶尔会把一句话写成一整段。
const int kReminderMessageMaxChars = 200;

/// 最多能设到多久以后。
///
/// 防的是模型把 2026 手滑写成 2062——那条提醒永远不会响，
/// 而用户在列表里看时间也是合法格式，根本看不出来。
const Duration kReminderMaxHorizon = Duration(days: 365);

/// 设一条提醒。
class ReminderCreateTool extends N1Tool {
  ReminderCreateTool({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  @override
  String get name => 'reminder_create';

  @override
  String get description =>
      '给用户设一条定时提醒。到点那句话会出现在对话里（标着「提醒」），'
      'App 当时没开着的话，用户下次打开会立刻补上。\n'
      '\n'
      '**什么时候用**：用户明确让你提醒，而且说清了具体时间点。'
      '「明天下午三点提醒我交作业」「一小时后叫我」都算。\n'
      '\n'
      '**什么时候别用**：\n'
      '- 用户没给时间，或者时间含糊（「晚点提醒我」「过会儿」）——'
      '先问清楚是几点，**不要自己猜一个时间塞进去**。猜错比不设更烦人\n'
      '- 用户要的是「每天提醒我」这种重复的——现在只支持一次性，如实说明，'
      '并问要不要先设最近的那一次\n'
      '- **绝对不要主动给用户设提醒。** 只能是用户要求的\n'
      '\n'
      '`say` 要**现在就写好**，写得像人说话，一两句就够。'
      '不要写成「提醒：交作业」这种机器口气。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'fire_at': {
        'type': 'string',
        'description':
            '什么时候响。绝对时间，格式 `YYYY-MM-DD HH:MM`（本地时间），'
            '比如 2026-09-26 15:00。别传「明天下午三点」这种自然语言，'
            '自己换算好再传。',
      },
      'say': {
        'type': 'string',
        'description': '到点要说的那句话。一两句，像人说话。',
      },
      'source_text': {
        'type': 'string',
        'description':
            '用户的原话，用来在提醒列表里显示「你当时是这么说的」。'
            '不给就用 say 兜底。',
      },
    },
    'required': ['fire_at', 'say'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final raw = N1Tool.requireString(input, 'fire_at');
    final say = N1Tool.requireString(input, 'say');
    final source = N1Tool.optionalString(input, 'source_text') ?? say;

    final fireAt = _parseFireAt(raw);
    final now = _clock();

    if (!fireAt.isAfter(now)) {
      throw ToolInputException(
        '`fire_at` 是过去的时间（$raw）。设不了已经过去的提醒。',
      );
    }
    if (fireAt.difference(now) > kReminderMaxHorizon) {
      throw ToolInputException(
        '`fire_at` 太远了（$raw）。最多只能设一年以内——'
        '这个多半是年份写错了，确认一下。',
      );
    }

    final notes = <String>[];
    var text = say;
    if (text.length > kReminderMessageMaxChars) {
      text = text.substring(0, kReminderMessageMaxChars);
      notes.add('（原话太长，截到 $kReminderMessageMaxChars 字了）');
    }

    final reminder = Reminder.create(
      fireAt: fireAt,
      message: text,
      sourceText: source,
      now: now,
    );
    await ctx.reminders.save(reminder);
    ctx.log('设了提醒 ${reminder.id} → ${reminder.fireAt}');

    final tail = notes.isEmpty ? '' : '\n${notes.join('\n')}';
    return ToolResult.ok(
      '设好了：${_friendly(fireAt)}提醒用户。$tail',
      meta: {'reminder_id': reminder.id},
    );
  }

  /// 解析 `YYYY-MM-DD HH:MM`。**只放行这一种写法。**
  ///
  /// `DateTime.parse` 其实还吃得下 ISO 8601 的一堆变体（带 T、带秒、带时区），
  /// 但这里故意卡死：模型偶尔会自作主张补个 `Z`（UTC），那样解析出来会差好几个
  /// 小时，而界面上看起来完全正常——这种错要等用户错过一件事才会发现。
  /// 卡格式比事后排查便宜得多。
  ///
  /// 私有的，**别为了测试把它公开**：`@visibleForTesting` 来自
  /// `package:flutter/foundation.dart` 或 `package:meta`，而这个文件在
  /// `lib/core/` 里——引前者会让 `test/core_is_pure_test.dart` 直接变红，
  /// 引后者会因为 pubspec 里没有 meta 而吃一条 `depend_on_referenced_packages`。
  /// 所有用例都从 `call()` 走，本来也不需要直接够到它。
  static DateTime _parseFireAt(String raw) {
    final m = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$',
    ).firstMatch(raw);
    if (m == null) {
      throw ToolInputException(
        '`fire_at` 格式不对：「$raw」。要写成 `YYYY-MM-DD HH:MM`，'
        '例如 2026-09-26 15:00。',
      );
    }

    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);

    if (month < 1 || month > 12 || hour > 23 || minute > 59) {
      throw ToolInputException('`fire_at` 里的数字越界了：「$raw」。');
    }

    // 用构造器而不是 DateTime.parse。它会校验日期是否真实存在——
    // 2 月 30 日这种会被它「顺延」到 3 月，所以下面要回过头验一遍。
    final at = DateTime(year, month, day, hour, minute);
    if (at.year != year || at.month != month || at.day != day) {
      throw ToolInputException('`fire_at` 不是真实存在的日期：「$raw」。');
    }
    return at;
  }

  /// 给人看的时间。回给模型的那句确认里用这个，比 ISO 那样读着自然。
  static String _friendly(DateTime t) =>
      '${t.month}月${t.day}日 '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// 看看给用户设了哪些提醒。
class ReminderListTool extends N1Tool {
  const ReminderListTool();

  @override
  String get name => 'reminder_list';

  @override
  String get description =>
      '看看给用户设了哪些提醒。用户问「我设了什么提醒」「那个提醒还在吗」，'
      '或者你想确认某件事之前有没有设过时，用它。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'include_fired': {
        'type': 'boolean',
        'description': '连已经响过的也一起列出来。默认 false，只列还没响的。',
      },
    },
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final includeFired = input['include_fired'] == true;

    final pending = await ctx.reminders.pending();
    final fired = includeFired
        ? await ctx.reminders.fired()
        : const <Reminder>[];

    if (pending.isEmpty && fired.isEmpty) {
      return ToolResult.ok(includeFired ? '一条提醒都没有。' : '现在没有待响的提醒。');
    }

    final buffer = StringBuffer();
    if (pending.isNotEmpty) {
      buffer.writeln('还没响的：');
      for (final r in pending) {
        buffer.writeln('- ${machineTime(r.fireAt)}｜${r.message}');
      }
    }
    if (fired.isNotEmpty) {
      if (pending.isNotEmpty) buffer.writeln();
      buffer.writeln('已经响过的：');
      for (final r in fired) {
        buffer.writeln('- ${machineTime(r.fireAt)}｜${r.message}');
      }
    }
    return ToolResult.ok(buffer.toString().trimRight());
  }
}

/// 给模型看的时间写法。
///
/// **跟 `ReminderCreateTool` 的 `fire_at` 入参格式一模一样**——这样模型
/// 想把某条提醒改个时间，可以把列出来的时间原样传回去，不用重新换算一遍。
/// 界面上给用户看的那个「9月26日 15:00」是另一回事，那是 `_friendly`。
String machineTime(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';
