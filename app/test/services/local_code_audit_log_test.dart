import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/fs/local_code_audit_log.dart';
import 'package:path/path.dart' as p;

/// 真的往磁盘上写。
///
/// 跟文件工具那几个测试同一个理由：这里要验的就是"字节到底落下没有、长到
/// 什么时候会砍"，把 `File` mock 掉测出来的绿是假绿——而这份日志唯一的
/// 用途就是**事后能拿出来看**，写到别处去了等于没有。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('n1-audit-log-'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CodeAuditEntry entry(String detail, {CodeDecision decision = CodeDecision.ran}) =>
      CodeAuditEntry(
        at: DateTime(2026, 10, 10, 21, 4, 11),
        tool: 'run_command',
        decision: decision,
        detail: detail,
        workingDirectory: r'D:\work',
        exitCode: 0,
        ok: true,
        duration: const Duration(milliseconds: 120),
      );

  File logFile() => File(p.join(tmp.path, 'code-audit.log'));

  test('一行一条，追加着写', () async {
    final log = LocalCodeAuditLog(file: logFile());

    await log.record(entry('python a.py'));
    await log.record(entry('python b.py'));

    final lines = logFile().readAsLinesSync();
    expect(lines, hasLength(2));
    // 落盘的就是 `toLine()` 的原样——中间不能再加工，不然"测试里看到的格式"
    // 和"用户拿到记事本里看到的"就是两回事了。
    expect(lines.first, entry('python a.py').toLine());
    expect(lines.last, entry('python b.py').toLine());
  });

  test('换一个实例接着写，不把旧的冲掉', () async {
    // 每次启动都会 new 一个新的（`N1Runtime.boot` 就是那么干的）。
    // 用 write 而不是 append 的话，用户第二天打开只会看见最后一条。
    await LocalCodeAuditLog(file: logFile()).record(entry('昨天跑的'));

    await LocalCodeAuditLog(file: logFile()).record(entry('今天跑的'));

    final lines = logFile().readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines.first, contains('昨天跑的'));
    expect(lines.last, contains('今天跑的'));
  });

  test('目录不存在就建出来', () async {
    final nested = File(p.join(tmp.path, 'a', 'b', 'code-audit.log'));

    await LocalCodeAuditLog(file: nested).record(entry('x'));

    expect(nested.existsSync(), isTrue);
  });

  test('被拒的那条也落盘，而且不带退出码', () async {
    await LocalCodeAuditLog(file: logFile())
        .record(entry(r'del /s /q D:\重要资料', decision: CodeDecision.denied));

    final line = logFile().readAsLinesSync().single;
    expect(line, contains('denied'));
    expect(line, contains(r'del /s /q D:\重要资料'));
  });

  group('长胖了就砍', () {
    test('砍掉旧的一半，留最近的', () async {
      // 用户天天让 AI 跑命令，这个文件会一直长，而他根本不知道有这东西。
      // 不砍的话，一年下来是一块悄悄占着的磁盘。
      final log = LocalCodeAuditLog(file: logFile(), maxBytes: 512);

      for (var i = 0; i < 100; i++) {
        await log.record(entry('entry-$i'));
      }

      final size = logFile().lengthSync();
      final lines = logFile().readAsLinesSync();

      // 100 条全留着大约是 5.5 KB。
      expect(size, lessThan(1024), reason: '砍过之后应该稳定在 maxBytes 附近');
      expect(lines.last, contains('entry-99'), reason: '最新的那条必须在');
      expect(
        lines.first,
        isNot(contains('entry-0')),
        reason: '留新的不留旧的：查日志的人几乎总是在查"最近它干了什么"',
      );
    });

    test('没超过上限就一个字不动', () async {
      final log = LocalCodeAuditLog(file: logFile(), maxBytes: 1024 * 1024);

      for (var i = 0; i < 5; i++) {
        await log.record(entry('entry-$i'));
      }

      expect(logFile().readAsLinesSync(), hasLength(5));
    });
  });

  test('写不进去也不抛——日志是旁路', () async {
    // 拿一个文件当目录用，父目录创建必然失败。比换权限位可移植。
    final blocker = File(p.join(tmp.path, 'blocker'))..writeAsStringSync('x');
    final bad = LocalCodeAuditLog(file: File(p.join(blocker.path, 'x.log')));

    await expectLater(bad.record(entry('x')), completes);
  });
}
