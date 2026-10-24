// 迁移彩排：拿**用户真实那份 n1.db 的副本**跑一遍生产迁移，然后逐项体检。
//
// 为什么要单独有这么个东西：迁移是整个项目里唯一**不可逆**的动作。sqflite 把
// onUpgrade 包在一个事务里，抛异常会整体回滚（数据没事，但 App 起不来）；
// 而"迁移成功但结果错"会把错误固化进库——版本号已经写到 3，迁移永远不会再跑。
// 所以上线前必须先在副本上跑一遍，而不是指望单元测试全绿。
//
// 单元测试用的是**造出来的**库；这个脚本用的是**真的那个**。
//
// 用法（先关掉 App，它占着库文件）：
//
//   flutter test tool/verify_migration.dart --dart-define=SRC_DB=D:/path/to/n1.db
//
// 不传 SRC_DB 就自动用便携版的数据目录。脚本**只读源文件**，全程在临时目录里操作。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/db_schema.dart';
import 'package:niuwa_ai/services/message_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _kSrcDb = String.fromEnvironment('SRC_DB');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('在真实库的副本上彩排一遍迁移', () async {
    final src = File(_kSrcDb.isEmpty ? _defaultDbPath() : _kSrcDb);
    if (!src.existsSync()) {
      fail('找不到源库：${src.path}\n'
          '（便携版在 <exe 目录>/userdata/n1.db，装到 Program Files 时在 '
          'AppData/Roaming/com.niuwa/niuwa_ai/）');
    }

    // 副本放到临时目录，**一个字节都不碰源文件**。
    final work = await Directory.systemTemp.createTemp('n1_mig_rehearsal_');
    final copy = File('${work.path}/n1.db')..writeAsBytesSync(src.readAsBytesSync());
    stdout.writeln('源库  : ${src.path}  (${src.lengthSync()} 字节)');
    stdout.writeln('工作在: ${copy.path}');

    // 先看版本号。不是 DbSchema.version 才有得升；已经是了就直接报告。
    final probe = await openDatabase(copy.path);
    final beforeVersion = await probe.getVersion();
    final beforeRows = await probe.query('messages');
    stdout.writeln('迁移前: user_version=$beforeVersion  消息 ${beforeRows.length} 条');
    await probe.close();

    // ---- 跑生产那套回调，参数跟 N1Runtime._openDatabase 一字不差 --------------
    final db = await openDatabase(
      copy.path,
      version: DbSchema.version,
      onCreate: (db, version) => DbSchema.createAll(db),
      onUpgrade: DbSchema.upgrade,
    );

    final afterVersion = await db.getVersion();
    final store = SqliteMessageStore.fromDatabase(db);
    final back = await store.recent(limit: 100000);

    stdout.writeln('\n=== 体检报告 ===');
    stdout.writeln('迁移后: user_version=$afterVersion');
    stdout.writeln('条数  : 迁移前 ${beforeRows.length} → 迁移后 ${back.length}'
        '  ${beforeRows.length == back.length ? '✓ 一条没丢' : '✗ 数目对不上！'}');

    final seqNull = await _count(db, 'seq IS NULL');
    stdout.writeln('seq 为 NULL 的行: $seqNull ${seqNull == 0 ? '✓' : '✗ 漏回填'}');

    final dup = await db.rawQuery(
      'SELECT seq, COUNT(*) AS n FROM messages GROUP BY seq HAVING n > 1',
    );
    stdout.writeln('重号的 seq: ${dup.length} 组 ${dup.isEmpty ? '✓' : '✗'}');

    // 顺序体检：把消息按当前顺序过一遍，检查每一轮 tool_calls 配对。
    // 这就是那个线上 bug 的形状——顺序错了这里必然报出来。
    final problems = <String>[];
    final openCalls = <String>{};
    for (final m in back) {
      if (m.role == Role.assistant && m.toolCalls != null) {
        for (final c in m.toolCalls!) {
          openCalls.add(c.id);
        }
      } else if (m.role == Role.tool) {
        if (m.toolCallId == null) {
          problems.add('${m.id}: tool 消息没有 tool_call_id');
        } else if (!openCalls.remove(m.toolCallId)) {
          problems.add('${m.id}: 它的 tool_call_id 找不到前面的 assistant');
        }
      }
    }
    for (final id in openCalls) {
      problems.add('tool_call $id 没有对应的结果 —— 发出去会被上游拒');
    }
    stdout.writeln('配对体检: ${problems.isEmpty ? '✓ 全部自洽' : '✗ ${problems.length} 处问题'}');
    for (final p in problems) {
      stdout.writeln('    $p');
    }

    stdout.writeln('\n顺序（前 40 条）:');
    for (final m in back.take(40)) {
      final tag = m.toolCalls != null
          ? ' tool_calls=${m.toolCalls!.map((c) => c.id).join(",")}'
          : '';
      final tid = m.toolCallId != null ? ' ←${m.toolCallId}' : '';
      stdout.writeln(
        '  ${m.role.name.padRight(9)} ${m.createdAt}  '
        '${jsonEncode(m.content.length > 24 ? "${m.content.substring(0, 24)}…" : m.content)}'
        '$tag$tid',
      );
    }

    await db.close();
    // 副本留着（路径已打印），方便自己用 sqlite 再看两眼；系统临时目录会自己清。
    stdout.writeln('\n副本保留在: ${copy.path}');
  });
}

Future<int> _count(Database db, String where) async {
  final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM messages WHERE $where');
  return rows.first['n'] as int;
}

/// 便携版的数据目录：exe 旁边的 userdata/。
String _defaultDbPath() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return '$exeDir/userdata/n1.db';
}
