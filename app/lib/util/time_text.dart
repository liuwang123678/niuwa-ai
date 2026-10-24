/// 把时间点说成人话。
///
/// 为什么不用 `intl`：这个 App 只需要中文的粗粒度相对时间，为它引一个包
/// （还是带一整套 locale 数据的）不划算。真正需要格式化的地方（日期选择器之类）
/// Flutter 自带的 `MaterialLocalizations` 已经覆盖了。
library;

/// 相对时间：刚刚 / 12 分钟前 / 3 小时前 / 昨天 / 5 天前 / 具体日期。
///
/// 粒度**刻意粗**。给记忆列表看的时间，精确到"14:37"没有意义，但"多久以前"
/// 对判断一条记忆还作不作数很关键——三年前的偏好和昨天的偏好，可信度不一样。
String relativeTime(DateTime t, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final d = ref.difference(t);

  // 时钟回拨或者服务端时间略快时会算出负数，当作"刚刚"，别显示"-3 分钟前"。
  if (d.isNegative || d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';

  // 按"日历天"算而不是按 24 小时：今天 23:00 写的，明天 01:00 看应该是"昨天"
  // 而不是"2 小时前"——人就是这么记事的。
  final days = _calendarDaysBetween(t, ref);
  if (days == 1) return '昨天';
  if (days < 30) return '$days 天前';
  if (days < 365) return '${days ~/ 30} 个月前';
  return '${t.year} 年 ${t.month} 月 ${t.day} 日';
}

/// 消息下面的时间戳。比 [relativeTime] 精确一点，因为同一个会话里
/// "3 小时前"这种说法会连着一大片全一样。
String clockTime(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

int _calendarDaysBetween(DateTime a, DateTime b) {
  final da = DateTime(a.year, a.month, a.day);
  final db = DateTime(b.year, b.month, b.day);
  return db.difference(da).inDays;
}
