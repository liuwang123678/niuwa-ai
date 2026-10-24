import 'reminder.dart';

/// 提醒存储。
///
/// 抽成接口的理由跟 `MemoryStore` 一模一样：内核不依赖 SQLite 就能跑测试，
/// 以后换存储不用动 agent 那半边。
abstract class ReminderStore {
  Future<void> save(Reminder reminder);

  Future<Reminder?> byId(String id);

  /// 还没响的，**按响的时间正序**——最早要响的排最前。
  /// 上限作用是防止某天有人往里塞了几千条，界面上一次全画出来。
  Future<List<Reminder>> pending({int limit = 100});

  /// 已经响过的，**按响过的时刻倒序**——最近响的排最前。
  Future<List<Reminder>> fired({int limit = 50});

  Future<void> delete(String id);

  Future<int> count();
}

/// 纯内存实现。测试用，也可以当作数据库还没就绪时的兜底。
///
/// **排序语义必须跟 `SqliteReminderStore` 一字不差**——两边一旦分叉，
/// 绿的是测试里的内存版，乱的是用户手机上的 SQLite 版，而后者跑不进单测。
class InMemoryReminderStore implements ReminderStore {
  InMemoryReminderStore([List<Reminder> seed = const []]) {
    for (final r in seed) {
      _items[r.id] = r;
    }
  }

  final Map<String, Reminder> _items = {};

  @override
  Future<void> save(Reminder reminder) async {
    // map 赋值天然是「同 id 覆盖」，跟 SQLite 那边的 ConflictAlgorithm.replace 对齐。
    _items[reminder.id] = reminder;
  }

  @override
  Future<Reminder?> byId(String id) async => _items[id];

  @override
  Future<List<Reminder>> pending({int limit = 100}) async {
    // limit 为负时 SQLite 的 `LIMIT -1` 是「不限量」，跟这边「返回空」会分叉，
    // 所以两边都在最前面挡掉。正常的调用方传的是正数，这行只是把坑封死。
    if (limit <= 0) return const [];

    final list = _items.values.where((r) => r.isPending).toList()
      ..sort(_byPendingOrder);
    return list.take(limit).toList();
  }

  @override
  Future<List<Reminder>> fired({int limit = 50}) async {
    if (limit <= 0) return const [];

    final list = _items.values
        .where((r) => r.state == ReminderState.fired)
        .toList()
      ..sort(_byFiredOrder);
    return list.take(limit).toList();
  }

  @override
  Future<void> delete(String id) async {
    _items.remove(id);
  }

  @override
  Future<int> count() async => _items.length;

  /// 响的时间升序 → id 升序兜底。
  /// 没有 id 那条的话，同一时刻的两条提醒谁先谁后是「没定义」的，界面会抖。
  static int _byPendingOrder(Reminder a, Reminder b) {
    final byTime = a.fireAt.compareTo(b.fireAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  /// 响过的时刻降序 → id 升序兜底。firedAt 理论上不该是 null
  /// （state 已经是 fired 了），但脏数据可能留一个，那就当成 epoch 0 排到末尾。
  static int _byFiredOrder(Reminder a, Reminder b) {
    final at = a.firedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bt = b.firedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final byTime = bt.compareTo(at);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }
}
