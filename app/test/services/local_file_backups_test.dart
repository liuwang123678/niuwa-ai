import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/services/fs/local_file_backups.dart';
import 'package:path/path.dart' as p;

/// 备份。
///
/// 这是"做砸了能不能退回去"那一层，所以每条测试问的都是同一件事：
/// **备份里那一份，是不是覆盖前的那一份。**
void main() {
  late Directory tmp;
  late Directory backupsDir;
  late LocalFileBackupStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-backups-test');
    backupsDir = Directory(p.join(tmp.path, 'backups'));
    store = LocalFileBackupStore(dir: backupsDir);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File source(String name, String content) {
    final file = File(p.join(tmp.path, name))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return file;
  }

  group('存一份', () {
    test('文件不存在就返回 null——没什么可备份的，这不是失败', () async {
      expect(await store.backup(p.join(tmp.path, '没有这个.txt')), isNull);
    });

    test('备份里的内容和原件一字不差（含中文和换行）', () async {
      const original = '第一行\n第二行\r\n第三行\n';
      final file = source('报告.txt', original);

      final record = (await store.backup(file.path))!;

      expect(record.original, file.path);
      expect(await File(record.copyPath).readAsString(), original);
    });

    test('原件之后被改掉，备份里还是老的', () async {
      // 这条才是这个类存在的理由。备份如果跟着一起变，那就是个摆设。
      final file = source('a.txt', 'v1');
      final record = await store.backup(file.path);

      file.writeAsStringSync('v2');

      expect(await File(record!.copyPath).readAsString(), 'v1');
      expect(await file.readAsString(), 'v2');
    });

    test('备份目录不存在会自己建出来', () async {
      expect(backupsDir.existsSync(), isFalse);

      await store.backup(source('a.txt', 'x').path);

      expect(backupsDir.existsSync(), isTrue);
    });

    test('文件名里看得出原来叫什么', () async {
      final record = await store.backup(source('报告.py', 'x').path);

      expect(p.basename(record!.copyPath), contains('报告.py'));
      expect(p.basename(record.copyPath), endsWith('.bak'));
    });

    test('两个不同目录里的同名文件不会互相覆盖', () async {
      // 没有这一条的话，第二次备份会把第一次的盖掉——
      // 那"备份"就退化成了"只留最近一次"，而用户以为一直有。
      final a = File(p.join(tmp.path, 'one', 'config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"a":1}');
      final b = File(p.join(tmp.path, 'two', 'config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"b":2}');

      final first = await store.backup(a.path);
      final second = await store.backup(b.path);

      expect(first!.copyPath, isNot(second!.copyPath));
      expect(await File(first.copyPath).readAsString(), '{"a":1}');
      expect(await File(second.copyPath).readAsString(), '{"b":2}');
    });

    test('同一个文件备份两次，两次都在', () async {
      final file = source('a.txt', 'v1');

      final first = await store.backup(file.path);
      // 时间戳是毫秒级的，连续两次调用要错开一点才拿得到不同的名字。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      file.writeAsStringSync('v2');
      final second = await store.backup(file.path);

      expect(first!.copyPath, isNot(second!.copyPath));
      expect(await File(first.copyPath).readAsString(), 'v1');
      expect(await File(second.copyPath).readAsString(), 'v2');
    });
  });

  group('清理老的', () {
    test('没超上限时一个都不删', () async {
      final one = source('a.txt', 'x');
      await store.backup(one.path);
      await store.backup(one.path);

      expect(await store.prune(), 0);
      expect(backupsDir.listSync(), hasLength(2));
    });

    test('超上限就删最老的，留下最新的', () async {
      final small = LocalFileBackupStore(dir: backupsDir, keep: 3);
      final one = source('a.txt', 'x');

      // 文件名里的时间戳是毫秒级的，得错开时间才排得出先后。
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        one.writeAsStringSync('v$i');
        await small.backup(one.path);
      }
      final removed = await small.prune();

      expect(removed, 2);
      final left = backupsDir.listSync().whereType<File>().toList();
      expect(left, hasLength(3));
      // 留下的必须是**最新**那三份。按名字排序 = 按时间排序，
      // 靠的就是时间戳定长且高位在前。
      final contents = <String>[];
      for (final file in left) {
        contents.add(await file.readAsString());
      }
      expect(contents..sort(), ['v2', 'v3', 'v4']);
    });

    test('目录还不存在时清理不报错', () async {
      expect(await store.prune(), 0);
    });

    test('不管非 .bak 的文件', () async {
      final small = LocalFileBackupStore(dir: backupsDir, keep: 0);
      backupsDir.createSync(recursive: true);
      File(p.join(backupsDir.path, '别删我.txt')).writeAsStringSync('x');
      final one = source('a.txt', 'x');
      await small.backup(one.path);

      await small.prune();

      expect(File(p.join(backupsDir.path, '别删我.txt')).existsSync(), isTrue);
    });
  });
}
