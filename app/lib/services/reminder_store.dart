import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/reminder/reminder.dart';
import '../core/reminder/reminder_store.dart';

/// 落在 SQLite 上的提醒存储。
///
/// 跟 `SqliteMemoryStore` 一个套路：接口在 core、实现在这儿，
/// 排序语义必须跟 `InMemoryReminderStore` 一字不差。
class SqliteReminderStore implements ReminderStore {
  SqliteReminderStore._(this._db);

  static const String table = 'reminders';

  /// 待响的排序：响的时间升序 → id 兜底。
  /// **跟 `InMemoryReminderStore._byPendingOrder` 严格对应**，改一处要改两处。
  static const String pendingOrderBy = 'fire_at ASC, id ASC';

  /// 已响的排序：响过的时刻降序 → id 兜底。
  static const String firedOrderBy = 'fired_at DESC, id ASC';

  final Database _db;

  /// 直接用一个**已经打开的**库。生产入口是 `N1Runtime`，理由见 `db_schema.dart`。
  factory SqliteReminderStore.fromDatabase(Database db) = SqliteReminderStore._;

  /// 建表。给共用的启动流程调用。
  ///
  /// **必须是幂等的**（`IF NOT EXISTS`）：它同时被 `onCreate` 和 `onUpgrade` 调，
  /// 而升级路径在某些情况下可能跑第二遍。SQLite 对已存在的表直接报错，
  /// 在升级回调里抛异常会把整个启动流程打断——用户看到的是「App 打不开」。
  static Future<void> createSchema(Database db) => _createSchema(db);

  /// 内存库。测试用。
  ///
  /// ⚠️ 只给**单独测这个类**用。生产路径不要走它——同一个 `.db` 上
  /// 两个 store 各自 `openDatabase(version:)` 的话，第二个会看到版本号已经对了
  /// 而跳过建表，那张表永远建不出来。理由详见 `db_schema.dart`。
  static Future<SqliteReminderStore> forTesting() async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) => _createSchema(db),
    );
    return SqliteReminderStore._(db);
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $table (
  id TEXT PRIMARY KEY,
  fire_at INTEGER,
  message TEXT,
  source_text TEXT,
  kind TEXT,
  state TEXT,
  created_at INTEGER,
  fired_at INTEGER,
  message_id TEXT
)
''');
    // 待响那条路每次开界面都要走（按 fire_at 排），这个索引跟 pendingOrderBy
    // 顺序一致，让 SQLite 顺着索引吐结果，不用全表排序 + 临时 B 树。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_${table}_pending '
      'ON $table(state, fire_at ASC, id ASC)',
    );
  }

  Future<void> close() => _db.close();

  /// 测试钩子：直接看落盘的行。
  @visibleForTesting
  Future<List<Map<String, Object?>>> rawRowsForTesting() => _db.query(table);

  @override
  Future<void> save(Reminder reminder) async {
    await _db.insert(
      table,
      reminder.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<Reminder?> byId(String id) async {
    final rows = await _db.query(
      table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _reminderOf(rows.single);
  }

  @override
  Future<List<Reminder>> pending({int limit = 100}) async {
    if (limit <= 0) return const [];
    final rows = await _db.query(
      table,
      where: 'state = ?',
      whereArgs: [ReminderState.pending.name],
      orderBy: pendingOrderBy,
      limit: limit,
    );
    return _remindersOf(rows);
  }

  @override
  Future<List<Reminder>> fired({int limit = 50}) async {
    if (limit <= 0) return const [];
    final rows = await _db.query(
      table,
      where: 'state = ?',
      whereArgs: [ReminderState.fired.name],
      orderBy: firedOrderBy,
      limit: limit,
    );
    return _remindersOf(rows);
  }

  @override
  Future<void> delete(String id) async {
    await _db.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) FROM $table');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  List<Reminder> _remindersOf(List<Map<String, Object?>> rows) =>
      rows.map(_reminderOf).whereType<Reminder>().toList();

  /// 一行 → 一条提醒。**id 为空就整行丢掉。**
  ///
  /// 主键都没有的行写不回去也删不掉，留着只会让界面上出现一条点不动的鬼影。
  /// 解析本身不抛（见 `Reminder.fromJson`），所以这里不会因为脏数据崩。
  static Reminder? _reminderOf(Map<String, Object?> row) {
    if ((row['id'] as String?)?.isEmpty ?? true) {
      debugPrint('提醒行缺 id，已跳过：$row');
      return null;
    }
    return Reminder.fromJson(row);
  }
}
