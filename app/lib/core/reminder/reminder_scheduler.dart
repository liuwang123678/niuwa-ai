import 'dart:async';

import 'reminder.dart';
import 'reminder_store.dart';

/// 提醒到点了该做什么。返回落进聊天记录的那条消息 id（没有就返回 null）。
typedef ReminderFireHandler = Future<String?> Function(Reminder reminder);

/// 盯着到点的提醒，到点就叫一声。
///
/// ## 为什么用"每 15 秒查一次"而不是"给最近那条挂一个 Timer"
///
/// 挂 Timer 看起来更省，实际上有一堆坑：
///
///   - 手机睡着、电脑休眠之后，那个 Timer 会晚很久才醒，醒来也不会补；
///   - 用户改系统时间、跨时区，Timer 的剩余时长是按单调时钟算的，跟
///     `fireAt` 这个墙钟时间对不上；
///   - 新存一条更早的提醒时，得把旧 Timer 取消重挂，少一处就漏。
///
/// 轮询把这些全绕开了：**每一轮都拿"现在"跟库里的 `fire_at` 比一次**，
/// 不管中间发生过什么，下一轮总能对上。代价是到点最多晚 [tick]——对一句
/// "该交作业了"来说十几秒无所谓。
///
/// ## 补响
///
/// App 没开着的时候到点的提醒，下次打开会**立刻补响**（`fireAt <= now` 就算）。
/// 不补的话，用户关掉 App 睡一觉，第二天的闹钟就永远消失了，而列表里还写着
/// "待响"——那是最糟的一种状态：它说会响，但不会。
class ReminderScheduler {
  ReminderScheduler({
    required this.store,
    required this.onFire,
    DateTime Function()? clock,
    this.tick = const Duration(seconds: 15),
  }) : _clock = clock ?? DateTime.now;

  final ReminderStore store;
  final ReminderFireHandler onFire;
  final Duration tick;
  final DateTime Function() _clock;

  Timer? _timer;

  /// 防重入。一次 [checkNow] 里要 await 好几次（查库、写库、落消息），
  /// 期间下一轮 tick 可能已经来了；不挡的话同一条提醒会被响两遍。
  bool _busy = false;

  bool _disposed = false;

  bool get isRunning => _timer != null;

  /// 开始轮询。重复调用是幂等的。
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(tick, (_) => checkNow());
    // 不等第一轮 tick：App 刚打开时欠着的那几条要马上补响。
    unawaited(checkNow());
  }

  /// 立刻查一遍。存了新提醒、改了系统时间之后也可以手动调。
  Future<void> checkNow() async {
    if (_disposed || _busy) return;
    _busy = true;
    try {
      final now = _clock();
      final pending = await store.pending();
      if (_disposed) return;

      for (final reminder in pending) {
        if (reminder.fireAt.isAfter(now)) continue;
        if (_disposed) return;
        await _fire(reminder, now);
      }
    } catch (_) {
      // 一次查询失败不该把轮询停掉：下一轮还会再来。这里没有日志通道，
      // 也不该为了"记一条日志"把异常抛到 Timer 外面（没人接，会被当成
      // 未捕获异常上报）。状态都在库里，用户下次看列表就知道。
    } finally {
      _busy = false;
    }
  }

  Future<void> _fire(Reminder reminder, DateTime now) async {
    // **先落"已经响过"再叫。** 反过来的话，onFire 里一旦抛异常（比如落库失败），
    // 这条提醒还是 pending，下一轮又响一次——用户会每 15 秒被同一句话烦一遍。
    // 宁可少响一次，也不要重复响。
    final fired = reminder.copyWith(state: ReminderState.fired, firedAt: now);
    await store.save(fired);

    try {
      final messageId = await onFire(fired);
      if (messageId != null && messageId.isNotEmpty) {
        await store.save(fired.copyWith(messageId: messageId));
      }
    } catch (_) {
      // 消息没落下来，但提醒已经算响过了。不重试：重试会把同一句提醒
      // 变成两条消息。
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
