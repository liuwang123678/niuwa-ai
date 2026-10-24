import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/db_schema.dart';
import 'package:niuwa_ai/services/message_store.dart';
import 'package:niuwa_ai/services/reminder_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 版本 1 的两张表，**照抄当时的建表语句**。
///
/// 故意不调 `SqliteMemoryStore.createSchema` / `SqliteMessageStore.createSchema`：
/// 那两个函数跟着代码走，将来改了它们，这个「老库」就跟着变，测出来的
/// 是「新库能升到新库」——一个永远绿的假测试。这里要的是**冻住的历史快照**。
const _v1MemoryTable = '''
CREATE TABLE memories (
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
''';

const _v1MessageTable = '''
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  role TEXT,
  content TEXT,
  created_at INTEGER,
  reasoning TEXT,
  images TEXT,
  tool_calls TEXT,
  tool_call_id TEXT,
  tool_name TEXT
)
''';

/// 版本 2 的 messages = v1 + `origin` 列 + 那条按 created_at 排的索引。
///
/// 同样**冻住**，不引用生产代码。用户手上那份库现在就是 v2 形态，
/// 所以「v2 → v3」是一条**只跑 `< 3` 那个分支**的独立路径，
/// 跟 `makeV1` 造出来的（两个分支都跑）不是一回事，必须分开测。
const _v2MessageTable = '''
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  role TEXT,
  content TEXT,
  created_at INTEGER,
  reasoning TEXT,
  images TEXT,
  tool_calls TEXT,
  tool_call_id TEXT,
  tool_name TEXT,
  origin TEXT
)
''';

const _v2RecentIndex =
    'CREATE INDEX idx_messages_recent ON messages(created_at ASC, id ASC)';

/// 版本 2 的 reminders，同样冻住。
///
/// 真实的 v2 库一定有这张表——它是从 v1 升上来的，而 v1 → 2 那一步建的就是它。
/// 漏掉它的话，这个 fixture 就不是「用户的库」，拿它比结构会得出一堆假差异。
const _v2ReminderTable = '''
CREATE TABLE IF NOT EXISTS reminders (
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
''';

const _v2ReminderIndex =
    'CREATE INDEX IF NOT EXISTS idx_reminders_pending '
    'ON reminders(state, fire_at ASC, id ASC)';

/// 版本 3 的 messages = v2 + `seq` 列 + 按 seq 排的新索引。
///
/// 用户手上现在处于 v3 的那批库就是这个形状。冻住它，才有办法单独跑
/// "只走 `< 4` 那个分支"的路径。
const _v3MessageTable = '''
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  role TEXT,
  content TEXT,
  created_at INTEGER,
  reasoning TEXT,
  images TEXT,
  tool_calls TEXT,
  tool_call_id TEXT,
  tool_name TEXT,
  origin TEXT,
  seq INTEGER
)
''';

const _v3RecentIndex =
    'CREATE INDEX idx_messages_recent ON messages(seq, id)';

void main() {
  // sqflite 只有移动端有原生实现，桌面/CI 上跑测试得换成 FFI 版的工厂。
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  var seq = 0;
  late String dir;

  setUp(() async {
    dir = await getDatabasesPath();
  });

  /// 造一个版本 1 的库（只有 memories + messages），返回它的路径。
  Future<String> makeV1() async {
    final path = '$dir/n1_mig_${seq++}.db';
    await deleteDatabase(path);
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(_v1MemoryTable);
        await db.execute(_v1MessageTable);
      },
    );
    await db.close();
    return path;
  }

  /// 造一个版本 2 的库（memories + messages + origin 列 + 老索引），返回路径。
  Future<String> makeV2() async {
    final path = '$dir/n1_mig_${seq++}.db';
    await deleteDatabase(path);
    final db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute(_v1MemoryTable);
        await db.execute(_v2MessageTable);
        await db.execute(_v2RecentIndex);
        await db.execute(_v2ReminderTable);
        await db.execute(_v2ReminderIndex);
      },
    );
    await db.close();
    return path;
  }

  /// 造一个版本 3 的库（v2 的全部东西 + seq 列 + 新索引），返回路径。
  Future<String> makeV3() async {
    final path = '$dir/n1_mig_${seq++}.db';
    await deleteDatabase(path);
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute(_v1MemoryTable);
        await db.execute(_v3MessageTable);
        await db.execute(_v3RecentIndex);
        await db.execute(_v2ReminderTable);
        await db.execute(_v2ReminderIndex);
      },
    );
    await db.close();
    return path;
  }

  /// 按生产那套回调开库——**用的就是 `N1Runtime._openDatabase` 挂的那两个**。
  Future<Database> openProduction(String path) => openDatabase(
    path,
    version: DbSchema.version,
    onCreate: (db, version) => DbSchema.createAll(db),
    onUpgrade: DbSchema.upgrade,
  );

  Future<List<String>> columnsOf(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.map((r) => r['name'] as String).toList()..sort();
  }

  /// 索引名 + 它建在哪几列上。
  ///
  /// 现有的结构对比只看表名和列名，**漏建索引、或旧索引没删掉，它一条都发现不了**。
  /// 而索引恰恰是最容易漏的地方：排序规则改了、索引忘了跟着改，查询会悄悄退化成
  /// 全表排序（慢，但结果还是对的），没有任何断言会红。
  Future<List<String>> indexesOf(Database db, String table) async {
    final list = await db.rawQuery('PRAGMA index_list($table)');
    final out = <String>[];
    for (final idx in list) {
      final name = idx['name'] as String;
      if (name.startsWith('sqlite_autoindex')) continue; // 主键自动建的，不算
      final cols = await db.rawQuery('PRAGMA index_info($name)');
      out.add('$name(${cols.map((c) => c['name']).join(', ')})');
    }
    return out..sort();
  }

  Future<List<String>> tablesOf(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    return rows
        .map((r) => r['name'] as String)
        .where((n) => !n.startsWith('sqlite_'))
        .toList()
      ..sort();
  }

  group('版本 1 → 2', () {
    test('升级出来的结构和全新安装的逐列相同', () async {
      final upgradedPath = await makeV1();
      final upgraded = await openProduction(upgradedPath);

      final freshPath = '$dir/n1_mig_${seq++}.db';
      await deleteDatabase(freshPath);
      // onCreate 只在文件不存在时跑，所以这里必须先删掉。
      final fresh = await openProduction(freshPath);

      expect(await tablesOf(upgraded), await tablesOf(fresh));
      expect(
        await tablesOf(upgraded),
        containsAll(<String>['memories', 'messages', 'reminders']),
      );

      for (final table in ['memories', 'messages', 'reminders']) {
        expect(
          await columnsOf(upgraded, table),
          await columnsOf(fresh, table),
          reason: '$table 两条建表路径（onCreate / onUpgrade）不一致',
        );
      }

      await upgraded.close();
      await fresh.close();
      await deleteDatabase(upgradedPath);
      await deleteDatabase(freshPath);
    });

    test('升级把 reminders 表建出来，而且能真的存进去', () async {
      final path = await makeV1();
      final db = await openProduction(path);

      final store = SqliteReminderStore.fromDatabase(db);
      final r = Reminder.create(
        fireAt: DateTime(2026, 9, 26, 15, 0),
        message: '三点了',
        sourceText: '原话',
        now: DateTime(2026, 9, 25, 20, 30),
      );
      await store.save(r);

      final back = await store.pending();
      expect(back, hasLength(1));
      expect(back.single.message, '三点了');
      expect(back.single.fireAt, DateTime(2026, 9, 26, 15, 0));

      await db.close();
      await deleteDatabase(path);
    });

    test('升级后老数据一行没丢，老行的 origin 是 NULL', () async {
      final path = await makeV1();

      final v1 = await openDatabase(path);
      await v1.insert('memories', {
        'id': 'mem_old',
        'kind': 'fact',
        'content': '用户不吃香菜',
        'importance': 3,
        'created_at': 1,
        'updated_at': 1,
        'use_count': 0,
      });
      await v1.insert('messages', {
        'id': 'msg_old',
        'role': 'user',
        'content': '升级前说的话',
        'created_at': 1,
      });
      await v1.close();

      final db = await openProduction(path);

      final mem = await db.query(
        'memories',
        where: 'id = ?',
        whereArgs: ['mem_old'],
      );
      expect(mem, hasLength(1));
      expect(mem.single['content'], '用户不吃香菜');

      final msg = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: ['msg_old'],
      );
      expect(msg, hasLength(1));
      expect(msg.single['content'], '升级前说的话');

      // 先钉死列真的加出来了。**这一条不能省**：光断言 `origin` 是 null 的话，
      // 在「列压根没加上」的库上也会过——Map 里没有这个 key 一样返回 null，
      // 那条断言就成了空的（实测确认过：抽掉 addColumnIfMissing 之后，
      // 上面那句 null 断言照样绿）。
      expect(await DbSchema.hasColumn(db, 'messages', 'origin'), isTrue);
      // ALTER TABLE 加出来的列，对已存在的行是 NULL。
      expect(msg.single['origin'], isNull);

      await db.close();
      await deleteDatabase(path);
    });

    test('升级跑第二遍不会因为列/表已存在而炸', () async {
      final path = await makeV1();
      final db = await openProduction(path);

      // SQLite 的 CREATE TABLE / ADD COLUMN 对已存在的对象直接报错，
      // 而在升级回调里抛异常会打断整个启动流程——用户看到的是「App 打不开」，
      // 报错里一个字都不提「已经存在」。所以升级必须是幂等的。
      await DbSchema.upgrade(db, 1, 2);

      expect(await DbSchema.hasColumn(db, 'messages', 'origin'), isTrue);
      expect(
        await tablesOf(db),
        containsAll(<String>['memories', 'messages', 'reminders']),
      );

      await db.close();
      await deleteDatabase(path);
    });
  });

  group('版本 2 → 3（seq 排序修复）', () {
    // ---- 用户库里那条坏数据的原样复刻 -------------------------------------
    //
    // 真实值来自 2026-09-25 对 n1.db 的诊断：
    //   rowid=12  assistant  id=msg_hmm9n6v5iqp61efh  created_at=1790328686231
    //   rowid=13  tool       id=msg_hmm9n6v5iq9ukupo  created_at=1790328686231
    //
    // `'9' < 'p'`，所以按 `(created_at, id)` 排的时候 tool 会排到它爸爸前面。
    // 发出去的历史就成了「tool 结果出现在它的 tool_calls 之前」，上游回
    //   HTTP 400: Messages with role 'tool' must be a response to a
    //             preceding message with 'tool_calls'
    // 而且这个顺序已经写死在库里，重启后**每一句话**都失败。
    const assistantId = 'msg_hmm9n6v5iqp61efh';
    const toolId = 'msg_hmm9n6v5iq9ukupo';
    const callId = 'call_00_6zLRf9EsefGJmvRK6AWX6649';
    const ts = 1790328686231;

    /// 往 v2 库里塞进那一对坏数据（写入顺序是 assistant 先、tool 后）。
    Future<void> seedBadPair(Database v2) async {
      await v2.insert('messages', {
        'id': 'msg_hello',
        'role': 'user',
        'content': '你好',
        'created_at': ts - 1000,
      });
      await v2.insert('messages', {
        'id': assistantId,
        'role': 'assistant',
        'content': '',
        'created_at': ts,
        'tool_calls': jsonEncode([
          {
            'id': callId,
            'name': 'skill_read',
            'arguments': {'name': 'browser-task'},
          },
        ]),
      });
      await v2.insert('messages', {
        'id': toolId,
        'role': 'tool',
        'content': '# browser-task',
        'created_at': ts,
        'tool_call_id': callId,
        'tool_name': 'skill_read',
      });
    }

    /// 造一个装着坏数据的 v2 库，升到 v3，返回开着的库 + 路径。
    Future<(Database, String)> upgradedBadPair() async {
      final path = await makeV2();
      final v2 = await openDatabase(path);
      await seedBadPair(v2);
      await v2.close();
      return (await openProduction(path), path);
    }

    test('把库里那条坏顺序治好：assistant 排回自己的 tool 结果前面', () async {
      final (db, path) = await upgradedBadPair();

      final back = await SqliteMessageStore.fromDatabase(db).recent();

      expect(
        back.map((m) => m.id).toList(),
        ['msg_hello', assistantId, toolId],
        reason: 'seq = rowid 回填之后，「写入顺序」才是真顺序；'
            '按 (created_at, id) 排的话 tool 会跑到前面去',
      );
      // 顺序对了还不够，得确认这一轮历史**协议上合法**：
      // assistant 带着 tool_calls，紧跟的 tool 结果对得上那个 id。
      expect(back[1].toolCalls?.single.id, callId);
      expect(back[2].toolCallId, callId);
      expect(back[2].toolName, 'skill_read');

      await db.close();
      await deleteDatabase(path);
    });

    test('把那条坏数据直接改坏到相反顺序，迁移后依然是 assistant 在前', () async {
      // 上面那条测的是"写入顺序被 (created_at, id) 排错了"。
      // 这条换个角度：id 的字典序故意跟写入顺序**相反**，把"迁移其实偷偷
      // 按 id 排"这条路彻底堵死——否则实现只要退化成 `ORDER BY id` 就蒙混过关。
      final path = await makeV2();
      final v2 = await openDatabase(path);
      await v2.insert('messages', {
        'id': 'zzz_assistant', // 字典序大
        'role': 'assistant',
        'content': '',
        'created_at': ts,
        'tool_calls': jsonEncode([
          {'id': callId, 'name': 'f', 'arguments': <String, Object?>{}},
        ]),
      });
      await v2.insert('messages', {
        'id': 'aaa_tool', // 字典序小，按 id 排会跑到前面
        'role': 'tool',
        'content': '结果',
        'created_at': ts,
        'tool_call_id': callId,
      });
      await v2.close();

      final db = await openProduction(path);
      final back = await SqliteMessageStore.fromDatabase(db).recent();
      expect(back.map((m) => m.id).toList(), ['zzz_assistant', 'aaa_tool']);

      await db.close();
      await deleteDatabase(path);
    });

    test('seq 全部有值、会话内不重号', () async {
      final (db, path) = await upgradedBadPair();

      final nulls =
          (await db.rawQuery(
                'SELECT COUNT(*) AS n FROM messages WHERE seq IS NULL',
              )).first['n']
              as int;
      expect(nulls, 0, reason: '回填漏了行 → 那些行只能靠 id 兜底排序，等于没修');

      final dup = await db.rawQuery(
        'SELECT seq, COUNT(*) AS n FROM messages GROUP BY seq HAVING n > 1',
      );
      expect(dup, isEmpty, reason: '重号说明发号规则破了，顺序会变得不确定');

      await db.close();
      await deleteDatabase(path);
    });

    test('迁移跑第二遍不会重发号（挡住漏写 WHERE seq IS NULL）', () async {
      final (db, path) = await upgradedBadPair();

      Future<Map<String, Object?>> seqs() async => {
        for (final r in await db.query('messages', columns: ['id', 'seq']))
          r['id'] as String: r['seq'],
      };

      // 关键一步：**让 seq 和 rowid 分道扬镳**，否则这个测试抓不住任何东西。
      // 重放一条已有的消息时，seq 由 COALESCE 保住原值，而 `INSERT OR REPLACE`
      // 是 delete+insert，它的 rowid 会跳到末尾。此刻 seq != rowid。
      final store = SqliteMessageStore.fromDatabase(db);
      await store.append([
        ChatMessage(
          id: 'msg_hello',
          role: Role.user,
          content: '你好',
          createdAt: ts - 1000,
        ),
      ]);

      final before = await seqs();
      expect(before['msg_hello'], 1, reason: '重放不该把它的号也改了');

      // 装回旧版本时 sqflite 会把版本号默默写低（默认 onDowngrade 是 null，
      // 只 setVersion 不删库），下次启动就会再跑一趟这趟迁移。
      await DbSchema.upgrade(db, 2, 3);

      expect(
        await seqs(),
        before,
        reason: '第二遍又按 rowid 重发了一遍号 → 顺序会变，正是漏写 WHERE 的症状',
      );

      await db.close();
      await deleteDatabase(path);
    });

    test('索引换成按 seq 排的那条，老的没留下', () async {
      final (db, path) = await upgradedBadPair();

      expect(await indexesOf(db, 'messages'), ['idx_messages_recent(seq, id)']);

      await db.close();
      await deleteDatabase(path);
    });

    test('空的 v2 库也能升上去（一条消息都没有）', () async {
      final path = await makeV2();
      final db = await openProduction(path);

      expect(await DbSchema.hasColumn(db, 'messages', 'seq'), isTrue);
      expect(await SqliteMessageStore.fromDatabase(db).recent(), isEmpty);

      await db.close();
      await deleteDatabase(path);
    });

    test('v2 升上来的结构跟全新安装逐列逐索引相同', () async {
      final (upgraded, upPath) = await upgradedBadPair();

      final freshPath = '$dir/n1_mig_${seq++}.db';
      await deleteDatabase(freshPath);
      final fresh = await openProduction(freshPath);

      for (final table in ['memories', 'messages', 'reminders']) {
        expect(
          await columnsOf(upgraded, table),
          await columnsOf(fresh, table),
          reason: '$table 的列在两条建表路径下不一致',
        );
      }
      expect(
        await indexesOf(upgraded, 'messages'),
        await indexesOf(fresh, 'messages'),
      );

      await upgraded.close();
      await fresh.close();
      await deleteDatabase(upPath);
      await deleteDatabase(freshPath);
    });

    test('v1 一路升到 v3：三个分支要加的列一个都不少', () async {
      // 真实老用户的路径：有些人停在 v1，直接跨两级上来。
      final path = await makeV1();
      final db = await openProduction(path);

      expect(await DbSchema.hasColumn(db, 'messages', 'origin'), isTrue);
      expect(await DbSchema.hasColumn(db, 'messages', 'seq'), isTrue);
      expect(await indexesOf(db, 'messages'), ['idx_messages_recent(seq, id)']);

      await db.close();
      await deleteDatabase(path);
    });

    test('升级后新写的消息接在老数据后面，顺序不断', () async {
      final (db, path) = await upgradedBadPair();
      final store = SqliteMessageStore.fromDatabase(db);

      await store.append([
        ChatMessage(
          id: 'msg_after',
          role: Role.user,
          content: '升级之后说的话',
          createdAt: ts + 1000,
        ),
      ]);

      final back = await store.recent();
      expect(back.map((m) => m.id).toList(), [
        'msg_hello',
        assistantId,
        toolId,
        'msg_after',
      ]);
      // 新号必须大于老号的最大值，否则新消息会插到历史中间去。
      final rows = await db.query(
        'messages',
        columns: ['seq'],
        where: 'id = ?',
        whereArgs: ['msg_after'],
      );
      expect(rows.single['seq'], greaterThan(3));

      await db.close();
      await deleteDatabase(path);
    });
  });

  group('版本 3 → 4（附件列）', () {
    test('加出 attachments 列，老行是 NULL，老内容一行没丢', () async {
      final path = await makeV3();

      final v3 = await openDatabase(path);
      await v3.insert('messages', {
        'id': 'msg_old',
        'role': 'user',
        'content': '升级前说的话',
        'created_at': 1,
        'seq': 1,
      });
      await v3.close();

      final db = await openProduction(path);

      // 先钉死列真的加出来了。只看"读回来是空附件"的话，列压根没加也会过——
      // 老代码路径里那列不存在时一样给空 list。
      expect(await DbSchema.hasColumn(db, 'messages', 'attachments'), isTrue);

      final row = (await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: ['msg_old'],
      )).single;
      expect(row['content'], '升级前说的话');
      expect(row['attachments'], isNull);

      // 而且这一行真的能读回来，不是"列在里面、store 认不出"。
      final back = await SqliteMessageStore.fromDatabase(db).recent();
      expect(back, hasLength(1));
      expect(back.single.content, '升级前说的话');
      expect(back.single.attachments, isEmpty);

      await db.close();
      await deleteDatabase(path);
    });

    test('升级出来的结构跟全新安装逐列相同', () async {
      final path = await makeV3();
      final upgraded = await openProduction(path);

      final freshPath = '$dir/n1_mig_${seq++}.db';
      await deleteDatabase(freshPath);
      final fresh = await openProduction(freshPath);

      for (final table in ['memories', 'messages', 'reminders']) {
        expect(
          await columnsOf(upgraded, table),
          await columnsOf(fresh, table),
          reason: '$table 的列在两条建表路径下不一致',
        );
      }
      expect(
        await indexesOf(upgraded, 'messages'),
        await indexesOf(fresh, 'messages'),
      );

      await upgraded.close();
      await fresh.close();
      await deleteDatabase(path);
      await deleteDatabase(freshPath);
    });

    test('升级后写进去的附件能原样读回来', () async {
      final path = await makeV3();
      final db = await openProduction(path);
      final store = SqliteMessageStore.fromDatabase(db);

      await store.append([
        ChatMessage.user(
          '看看这个',
          attachments: const [
            Attachment(name: 'app.log', text: '第一行\n第二行', sizeBytes: 42),
          ],
        ),
      ]);

      final back = await store.recent();
      expect(back.single.attachments, hasLength(1));
      expect(back.single.attachments.single.name, 'app.log');
      expect(back.single.attachments.single.text, '第一行\n第二行');
      expect(back.single.attachments.single.sizeBytes, 42);

      await db.close();
      await deleteDatabase(path);
    });

    test('跑第二遍不会因为列已存在而炸', () async {
      final path = await makeV3();
      final db = await openProduction(path);

      await DbSchema.upgrade(db, 3, 4);
      expect(await DbSchema.hasColumn(db, 'messages', 'attachments'), isTrue);

      await db.close();
      await deleteDatabase(path);
    });
  });
}
