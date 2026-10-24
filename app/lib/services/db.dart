import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/memory/memory_store.dart';

/// 落在 SQLite 上的记忆存储。
///
/// 这里**只负责存取**：排序、检索打分、去重、淘汰全在 [MemoryStore] 基类里，
/// 两个实现共用同一份代码。以前这里照抄过一套打分公式，注释里写着"一字不差"，
/// 但改公式时两边分叉是必然的，而分叉只在用户手机上显形。
class SqliteMemoryStore extends MemoryStore {
  SqliteMemoryStore._(this._db);

  static const String table = 'memories';

  final Database _db;

  /// 直接用一个**已经打开的**库。生产入口是 `N1Runtime`。
  ///
  /// 为什么生产不走 [open]：同一个 `.db` 文件上如果两个 store 各自
  /// `openDatabase(path, version: 1, onCreate: ...)`，第二个会看到文件已经是
  /// version 1 而**跳过 onCreate**，它那张表就永远建不出来。真实的发作形态是
  /// 首次启动一切正常，直到第一次要写数据才炸「no such table」。
  ///
  /// 所以生产上由 `N1Runtime` 开一次库、建全部表，再分给各个 store。
  factory SqliteMemoryStore.fromDatabase(Database db) = SqliteMemoryStore._;

  /// 建表。给共用同一个库的启动流程调用（见 [fromDatabase]）。
  static Future<void> createSchema(Database db) => _createSchema(db);

  /// 打开（或首次创建）数据库文件。
  ///
  /// ⚠️ 生产路径**不要**直接用它——同一个文件上只能有一个 store 走这条路，
  /// 理由见 [fromDatabase]。测试里每个用例是独立的内存库，所以那里没问题。
  static Future<SqliteMemoryStore> open(String path) async {
    // 首次启动时 <appSupport>/ 下的目录可能还不存在，而 sqflite 只管建库文件、
    // 不管建父目录，不补这一下会以"unable to open database file"失败。
    if (path != inMemoryDatabasePath) {
      final dir = Directory(p.dirname(path));
      if (!await dir.exists()) await dir.create(recursive: true);
    }
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => _createSchema(db),
    );
    return SqliteMemoryStore._(db);
  }

  /// 内存库。测试用——每个测试拿到的是**全新**的一个库，
  /// 所以测试之间不会互相看见对方写的记忆。
  static Future<SqliteMemoryStore> forTesting() => open(inMemoryDatabasePath);

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
CREATE TABLE $table (
  id TEXT PRIMARY KEY,
  kind TEXT,
  content TEXT,
  subject TEXT,
  tags TEXT,
  importance INTEGER,
  created_at INTEGER,
  updated_at INTEGER,
  last_used_at INTEGER,
  use_count INTEGER
)
''');
    // 排序现在在 Dart 里做，这个索引用不上，但老库已经建了就留着——
    // 删它没有收益，而 `CREATE INDEX` 对存数据没有副作用。
  }

  Future<void> close() => _db.close();

  /// 测试钩子：直接看落盘的行，用来验证 tags 真的按 JSON 存（而不是把
  /// List 的 toString 塞进去——那种错误读回来才发现，而且只有第二次启动才炸）。
  @visibleForTesting
  Future<List<Map<String, Object?>>> rawRowsForTesting() => _db.query(table);

  /// 测试钩子：绕过模型直接插一行，用来模拟用户导入/旧版本升级留下的脏数据。
  @visibleForTesting
  Future<void> insertRawForTesting(Map<String, Object?> row) =>
      _db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> save(MemoryEntry entry) async {
    // replace = upsert。MemoryEntry 的语义就是"同 id 覆盖"，
    // 而且 id 是主键、没有外键牵连，删了再插没有副作用。
    await _db.insert(
      table,
      _rowOf(entry),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

  @override
  Future<List<MemoryEntry>> all() async {
    final rows = await _db.query(table);
    return rows.map(_entryOf).whereType<MemoryEntry>().toList();
  }

  // ---------------------------------------------------------------- 内部

  static Map<String, Object?> _rowOf(MemoryEntry entry) {
    final json = entry.toJson();
    // tags 在模型里是 List<String>，在库里是一列 TEXT。两边转换只在这一个地方做，
    // 免得某天有人改了 JSON 编码方式却漏改了读取那边。
    return {...json, 'tags': jsonEncode(json['tags'] ?? const <String>[])};
  }

  static MemoryEntry? _entryOf(Map<String, Object?> row) {
    try {
      final rawTags = row['tags'];
      final tags = rawTags is String && rawTags.isNotEmpty
          ? (jsonDecode(rawTags) as List).whereType<String>().toList()
          : const <String>[];
      // 复用模型自己的 fromJson，字段名和容错规则只维护一份。
      return MemoryEntry.fromJson({...row, 'tags': tags});
    } catch (e) {
      // 库文件在应用目录里，用户导入/手改/旧版本升级都可能留一行脏数据。
      // 一行坏数据不该让整次检索（甚至整个 App 启动）崩掉。
      debugPrint('记忆行解析失败，已跳过：$e');
      return null;
    }
  }
}
