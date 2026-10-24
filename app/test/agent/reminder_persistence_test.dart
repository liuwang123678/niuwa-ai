import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/db_schema.dart';
import 'package:niuwa_ai/services/n1_runtime.dart';
import 'package:niuwa_ai/services/reminder_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 「关掉 App 再打开，提醒还在」——用真的 SQLite、真的生产接线来证。
///
/// 这个文件补的是端到端用例够不到的那一段：`reminder_end_to_end_test.dart`
/// 用的是内存存储，证明不了落盘。这里走 `DbSchema` 建的真库文件 +
/// `SqliteReminderStore` + `N1Runtime.alwaysOnTools()` 那套真工具表，
/// 中间把库关掉再开一次，模拟进程重启。
///
/// 到点会不会响是第二份计划的事，这里不管。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late String dir;
  var seq = 0;

  setUp(() async {
    dir = await getDatabasesPath();
  });

  /// 按生产那套开库（跟 `N1Runtime._openDatabase` 挂的是同一对回调）。
  Future<Database> openLikeProduction(String path) => openDatabase(
    path,
    version: DbSchema.version,
    onCreate: (db, version) => DbSchema.createAll(db),
    onUpgrade: DbSchema.upgrade,
  );

  test('设完提醒关掉 App，再打开还在，而且 reminder_list 答得上来', () async {
    // 时间必须**相对于当下**算，不能写死。
    //
    // 这里用的 `N1Runtime.alwaysOnTools()` 造出来的 ReminderCreateTool 走的是
    // 真实时钟（那正是生产里的样子），所以写死一个具体日期的话，那条用例会在
    // 那个日期过去之后突然变红——而且失败信息是「设不了已经过去的提醒」，
    // 看着像功能坏了，其实只是测试过期了。往后推一天，永远不会过期。
    final target = DateTime.now().add(const Duration(days: 1));
    final fireAt = DateTime(
      target.year,
      target.month,
      target.day,
      target.hour,
      target.minute,
    );
    final fireAtText = machineTime(fireAt);

    final path = '$dir/n1_persist_${seq++}.db';
    await deleteDatabase(path);

    // —— 第一次启动 ——
    var db = await openLikeProduction(path);

    // 用生产那套工具表，只是把 LLM 那半边去掉（这里不调模型）。
    final registry = ToolRegistry();
    for (final tool in N1Runtime.alwaysOnTools()) {
      registry.register(tool);
    }

    final ctx = ToolContext(
      memory: InMemoryMemoryStore(),
      skills: SkillRegistry(),
      browser: const UnavailableBrowserDriver('测试环境不支持浏览器'),
      reminders: SqliteReminderStore.fromDatabase(db),
    );

    // 通过工具表调，跟模型走的是同一条路——不是直接调 store.save()。
    final created = await registry.invoke(
      ToolCall(
        id: 'call_1',
        name: 'reminder_create',
        arguments: {
          'fire_at': fireAtText,
          'say': '三点了，作业交了没？',
          'source_text': '明天下午三点提醒我交作业',
        },
      ),
      ctx,
    );
    expect(created.result.ok, isTrue, reason: created.result.content);

    // 关掉 App
    await db.close();
    ctx.dispose();

    // —— 第二次启动 ——
    db = await openLikeProduction(path);
    final ctx2 = ToolContext(
      memory: InMemoryMemoryStore(),
      skills: SkillRegistry(),
      browser: const UnavailableBrowserDriver('测试环境不支持浏览器'),
      reminders: SqliteReminderStore.fromDatabase(db),
    );

    final listed = await registry.invoke(
      const ToolCall(id: 'call_2', name: 'reminder_list', arguments: {}),
      ctx2,
    );
    expect(listed.result.ok, isTrue);
    expect(listed.result.content, contains(fireAtText));
    expect(listed.result.content, contains('三点了，作业交了没？'));

    // 不只信工具自己报的，直接查库确认那一行真的在。
    final rows = await db.query('reminders');
    expect(rows, hasLength(1));
    expect(rows.single['message'], '三点了，作业交了没？');
    expect(rows.single['state'], 'pending');
    expect(rows.single['source_text'], '明天下午三点提醒我交作业');

    await db.close();
    ctx2.dispose();
    await deleteDatabase(path);
  });
}
