import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'message_store.dart';
import 'reminder_store.dart';

/// 数据库结构的**唯一真相**。
///
/// 建表（全新安装）和升级（老用户）走的是两个不同的回调，而 sqflite 只会调其中一个：
/// `onCreate` 在文件不存在时跑，`onUpgrade` 在文件存在但版本低时跑。
/// 一次只会发生一件，所以**两条路的最终结构必须由这里统一保证**——
/// 各写各的迟早分叉，而分叉只在「老用户升级」这一种组合下现形，
/// 全新安装的机器一辈子碰不到。
///
/// 项目已经踩过一次同款的坑：两个 store 各自 `openDatabase(version: 1, onCreate:)`，
/// 第二个看到版本号已经对了就跳过建表，那张表永远建不出来，
/// 直到第一次要写数据才炸 `no such table`。
class DbSchema {
  const DbSchema._();

  /// 1 → 2：加 reminders 表、给 messages 加 origin 列。
  /// 2 → 3：给 messages 加 seq 列（单调写入序号，排序的唯一依据）。
  /// 3 → 4：给 messages 加 attachments 列（用户附的文本文件）。
  static const int version = 4;

  /// 全新安装：一次建齐。
  static Future<void> createAll(Database db) async {
    await SqliteMemoryStore.createSchema(db);
    await SqliteMessageStore.createSchema(db);
    await SqliteReminderStore.createSchema(db);
  }

  /// 老库升级。
  ///
  /// **必须幂等**：同一个库上跑两遍不能炸。SQLite 的 `CREATE TABLE` 和
  /// `ALTER TABLE ADD COLUMN` 对已存在的对象都是直接报错，而在升级回调里抛异常
  /// 会把整个启动流程打断——用户看到的是「App 打不开」，报错里一个字都不提
  /// 「表已经存在」。
  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // reminders 的建表语句写成了 `CREATE TABLE IF NOT EXISTS`，直接调就行。
      // messages 的加列得自己查一遍——SQLite 没有 ADD COLUMN IF NOT EXISTS。
      await SqliteReminderStore.createSchema(db);
      await addColumnIfMissing(db, SqliteMessageStore.table, 'origin', 'TEXT');
    }

    if (oldVersion < 3) {
      // **不能靠重跑 createSchema 来加列**：它里面那句 `CREATE TABLE IF NOT EXISTS`
      // 对已经存在的表是一个字节都不动的空操作，列永远不会出现。ALTER 得自己来。
      await addColumnIfMissing(db, SqliteMessageStore.table, 'seq', 'INTEGER');

      // 序号 = rowid 快照。**rowid 在这整个项目里只出现这一次。**
      //
      // 它代表"这一趟迁移时真实的物理写入顺序"，而 `append` 的写入顺序就是消息
      // 真实发生的顺序（assistant 先、它的 tool 结果后），所以这次回填**顺手就
      // 把那条坏数据治好了**：用户库里 rowid 12 是 assistant、13 是 tool，
      // 回填后 assistant 排在前面，那一轮历史立刻变成协议合法的。
      //
      // 之后代码里再也不许引用 rowid——VACUUM 会重编它（对没有 INTEGER PRIMARY
      // KEY 的表，官方文档明说），所以它不能当运行期的稳定标识。
      //
      // `WHERE seq IS NULL` 是幂等的那一半：跑第二遍没有 NULL 行了，0 行受影响。
      // 漏掉这个 WHERE 的写法第一遍看着完全正确，第二遍会把所有号重发一遍——
      // 顺序侥幸还对，只有值变了，不盯就发现不了。测试里有一条专抓这个。
      await db.execute(
        'UPDATE ${SqliteMessageStore.table} SET seq = rowid WHERE seq IS NULL',
      );

      // 旧索引的排序键（created_at）已经不是查询的排序键（seq）了，留着白占磁盘
      // 还拖慢每次写入。索引名字没变、形态变了，而 CREATE INDEX 这次写成了
      // IF NOT EXISTS（不会报错也不会更新），所以必须先把旧的 DROP 掉。
      await db.execute(
        'DROP INDEX IF EXISTS idx_${SqliteMessageStore.table}_recent',
      );
      // 用新形态把索引建回来。调 createSchema 而不是在这儿再抄一遍 CREATE INDEX：
      // "升级出来的结构 == 全新安装的结构"这件事由它一处保证，抄一遍就是第二份真相。
      await SqliteMessageStore.createSchema(db);
    }

    if (oldVersion < 4) {
      // 老行这一列是 NULL，读的时候当"没有附件"处理——附件是附加信息，
      // 不值得为它丢用户一句原话。
      await addColumnIfMissing(
        db,
        SqliteMessageStore.table,
        'attachments',
        'TEXT',
      );
    }
  }

  /// 表里有没有这一列。
  static Future<bool> hasColumn(
    Database db,
    String table,
    String column,
  ) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.any((row) => row['name'] == column);
  }

  /// 加一列，已经有了就跳过。
  static Future<void> addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    if (await hasColumn(db, table, column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }
}
