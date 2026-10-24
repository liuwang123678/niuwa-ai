import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/fs/local_file_backups.dart';
import 'package:path/path.dart' as p;

import '../support/fake_llm.dart';

/// 文件工具。
///
/// **故意用真的临时目录，不 mock 文件系统。** 这一层要验的东西恰恰是
/// "字节真的落下去了吗""改名真的顶掉了旧文件吗"——mock 出来的绿是假绿，
/// 真出事的时候（比如 Windows 上改名撞到已存在的目标）它一点忙都帮不上。
void main() {
  late Directory tmp;
  late Directory workspace;
  late Directory sealed;
  late LocalFileBackupStore backups;
  late List<N1Tool> tools;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-file-tools');
    workspace = Directory(p.join(tmp.path, 'work'))..createSync();
    sealed = Directory(p.join(tmp.path, 'sealed'))..createSync();
    backups = LocalFileBackupStore(dir: Directory(p.join(tmp.path, 'backups')));

    tools = fileTools(
      available: true,
      paths: PathResolver(
        home: tmp.path,
        knownFolders: {KnownFolder.desktop: workspace.path},
      ),
      policy: FilePolicy(sealedRoots: [sealed.path]),
      backups: backups,
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  N1Tool tool(String name) {
    final found = tools.where((t) => t.name == name);
    expect(found, hasLength(1), reason: '工具表里应该有 $name');
    return found.single;
  }

  Future<ToolResult> run(String name, Map<String, Object?> input) =>
      tool(name).call(input, testContext());

  String inWork(String name) => p.join(workspace.path, name);

  group('read_file', () {
    test('读回来就是写进去的那段字节', () async {
      await File(inWork('a.txt')).writeAsString('第一行\n第二行\n');

      final result = await run('read_file', {'path': inWork('a.txt')});

      expect(result.ok, isTrue);
      expect(result.content, contains('第一行'));
      expect(result.content, contains('第二行'));
    });

    test('每行前面带行号，行号不在文件里', () async {
      await File(inWork('a.txt')).writeAsString('alpha\nbeta\n');

      final result = await run('read_file', {'path': inWork('a.txt')});

      // 行号是给模型对齐用的。文件里没有这三个字。
      expect(result.content, contains('1\talpha'));
      expect(result.content, contains('2\tbeta'));
      expect(
        await File(inWork('a.txt')).readAsString(),
        'alpha\nbeta\n',
        reason: '读操作不能改文件',
      );
    });

    test('offset / limit 只看一段', () async {
      await File(inWork('a.txt')).writeAsString(
        List.generate(50, (i) => 'line${i + 1}').join('\n'),
      );

      final result = await run('read_file', {
        'path': inWork('a.txt'),
        'offset': 10,
        'limit': 3,
      });

      expect(result.content, contains('10\tline10'));
      expect(result.content, contains('12\tline12'));
      expect(result.content, isNot(contains('line13')));
      expect(result.content, contains('共 50 行'));
    });

    test('CRLF 的行尾不会带进结果里', () async {
      await File(inWork('a.txt')).writeAsString('a\r\nb\r\n');

      final result = await run('read_file', {'path': inWork('a.txt')});

      expect(result.content, contains('1\ta'));
      expect(result.content, isNot(contains('\r')));
    });

    test('UTF-8 BOM 吃掉', () async {
      // 不吃的后果很具体：第一行开头挂一个看不见的 U+FEFF，
      // 模型把这行复制去做 edit_file 的 old_string，怎么都匹配不上。
      await File(inWork('a.txt')).writeAsBytes([
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('hello'),
      ]);

      final result = await run('read_file', {'path': inWork('a.txt')});

      expect(result.content, contains('\thello'));
      expect(result.content, isNot(contains('﻿')));
    });

    test('GBK 文件明确报错，不猜着解码', () async {
      // 猜错的后果比报错严重得多：模型拿到乱码，然后基于乱码去改文件。
      await File(inWork('gbk.txt')).writeAsBytes([0xC4, 0xE3, 0xBA, 0xC3]);

      final result = await run('read_file', {'path': inWork('gbk.txt')});

      expect(result.ok, isFalse);
      expect(result.content, contains('UTF-8'));
    });

    test('空文件说清楚是空的', () async {
      await File(inWork('empty.txt')).writeAsString('');

      final result = await run('read_file', {'path': inWork('empty.txt')});

      expect(result.ok, isTrue);
      expect(result.content, contains('空文件'));
    });

    test('路径不存在时，顺带报一下同目录里有什么', () async {
      // 这一句能省一整轮：模型否则只能瞎猜下一个路径再撞一次。
      await File(inWork('真的在这儿.txt')).writeAsString('x');

      final result = await run('read_file', {'path': inWork('打错了.txt')});

      expect(result.ok, isFalse);
      expect(result.content, contains('真的在这儿.txt'));
    });

    test('路径是目录时说清楚，并指向 list_dir', () async {
      final result = await run('read_file', {'path': workspace.path});

      expect(result.ok, isFalse);
      expect(result.content, contains('list_dir'));
    });

    test('「桌面/文件名」这种说法能用', () async {
      await File(inWork('d.txt')).writeAsString('桌面上的东西');

      final result = await run('read_file', {'path': '桌面/d.txt'});

      expect(result.ok, isTrue);
      expect(result.content, contains('桌面上的东西'));
    });
  });

  group('write_file', () {
    test('新建文件，内容一个字节不差', () async {
      final result = await run('write_file', {
        'path': inWork('new.txt'),
        'content': '  前后都有空格  \n而且有中文\n',
      });

      expect(result.ok, isTrue);
      expect(
        await File(inWork('new.txt')).readAsString(),
        '  前后都有空格  \n而且有中文\n',
        reason: '参数里的空白不能被 trim 掉——那会把代码的缩进和结尾换行吃掉',
      );
    });

    test('覆盖已有文件之前先备份，备份里是原来的内容', () async {
      final file = File(inWork('old.txt'))..writeAsStringSync('原来那份');

      final result = await run('write_file', {
        'path': inWork('old.txt'),
        'content': '新的',
      });

      expect(result.ok, isTrue);
      expect(await file.readAsString(), '新的');

      final saved = Directory(backups.dir.path)
          .listSync()
          .whereType<File>()
          .toList();
      expect(saved, hasLength(1));
      expect(
        await saved.single.readAsString(),
        '原来那份',
        reason: '备份里必须是**覆盖前**的内容，否则这个回滚阀是假的',
      );
      expect(result.content, contains(saved.single.path));
    });

    test('新建的文件不会产生备份（没什么可备的）', () async {
      await run('write_file', {'path': inWork('fresh.txt'), 'content': 'x'});

      expect(
        backups.dir.existsSync() && backups.dir.listSync().isNotEmpty,
        isFalse,
      );
    });

    test('父目录不存在要显式带 create_parents', () async {
      final nested = p.join(workspace.path, 'deep', 'deeper', 'a.txt');

      final refused = await run('write_file', {'path': nested, 'content': 'x'});
      expect(refused.ok, isFalse);
      expect(refused.content, contains('create_parents'));
      expect(File(nested).existsSync(), isFalse);

      final allowed = await run('write_file', {
        'path': nested,
        'content': 'x',
        'create_parents': true,
      });
      expect(allowed.ok, isTrue);
      expect(File(nested).readAsStringSync(), 'x');
    });

    test('受保护的目录写不进去', () async {
      final result = await run('write_file', {
        'path': p.join(sealed.path, 'evil.txt'),
        'content': 'x',
      });

      expect(result.ok, isFalse);
      expect(File(p.join(sealed.path, 'evil.txt')).existsSync(), isFalse);
    });

    test('写完不留临时文件', () async {
      // 原子写是"先写同目录的临时文件再改名"。失败路径上没清干净的话，
      // 用户的目录里会慢慢堆一堆 `.xxx.niuwa-*.tmp`。
      await run('write_file', {'path': inWork('a.txt'), 'content': 'x'});
      await run('write_file', {'path': inWork('a.txt'), 'content': 'y'});

      final leftovers = workspace
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.contains('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('覆盖已存在的文件真的成功了（改名顶掉了旧的）', () async {
      // Windows 上"改名到已存在的目标"是个真实的分歧点，这条钉的就是它。
      final file = File(inWork('same.txt'))..writeAsStringSync('旧的');

      final result = await run('write_file', {
        'path': inWork('same.txt'),
        'content': '新的',
      });

      expect(result.ok, isTrue);
      expect(await file.readAsString(), '新的');
    });

    test('备份失败时宁可不写，也不含糊说"已覆盖"', () async {
      // 备份目录指向一个已经存在的**文件**，创建目录必然失败。
      final blocked = File(p.join(tmp.path, 'not-a-dir'))..writeAsStringSync('x');
      final brokenStore = LocalFileBackupStore(
        dir: Directory(p.join(blocked.path, 'backups')),
      );
      final brokenTools = fileTools(
        available: true,
        paths: PathResolver(home: tmp.path),
        policy: const FilePolicy.unrestricted(),
        backups: brokenStore,
      );
      File(inWork('keep.txt')).writeAsStringSync('原来的');

      final result = await brokenTools
          .firstWhere((t) => t.name == 'write_file')
          .call({'path': inWork('keep.txt'), 'content': '新的'}, testContext());

      expect(result.ok, isFalse);
      expect(
        File(inWork('keep.txt')).readAsStringSync(),
        '原来的',
        reason: '没有回滚阀的时候，绝不能让文件被改掉还以为有备份',
      );
    });
  });

  group('edit_file', () {
    test('只换掉指定的一段，别的不动', () async {
      final file = File(inWork('a.py'))
        ..writeAsStringSync('def f():\n    return 1\n\ndef g():\n    return 2\n');

      final result = await run('edit_file', {
        'path': inWork('a.py'),
        'old_string': 'return 1',
        'new_string': 'return 100',
      });

      expect(result.ok, isTrue);
      expect(await file.readAsString(), contains('return 100'));
      expect(await file.readAsString(), contains('return 2'));
      expect(result.content, contains('第 2 行'));
    });

    test('CRLF 文件按 CRLF 写回', () async {
      // 模型给的多半是 LF。不归一的话，一个 CRLF 文件改一次就变成混排，
      // 整个 diff 全是行尾变化。
      final file = File(inWork('a.txt'))..writeAsStringSync('one\r\ntwo\r\nthree\r\n');

      final result = await run('edit_file', {
        'path': inWork('a.txt'),
        'old_string': 'two\n',
        'new_string': 'TWO\n',
      });

      expect(result.ok, isTrue);
      expect(await file.readAsString(), 'one\r\nTWO\r\nthree\r\n');
    });

    test('LF 文件不会被改成 CRLF', () async {
      final file = File(inWork('a.txt'))..writeAsStringSync('one\ntwo\n');

      await run('edit_file', {
        'path': inWork('a.txt'),
        'old_string': 'two',
        'new_string': 'TWO',
      });

      expect(await file.readAsString(), 'one\nTWO\n');
    });

    test('出现多次就拒绝，并把每一处的位置摆出来', () async {
      // 拒绝之后得让模型下一轮能改对。"出现 3 次"这种话它只能继续猜。
      final file = File(inWork('a.txt'))
        ..writeAsStringSync('x = 1\ny = 1\nz = 1\n');

      final result = await run('edit_file', {
        'path': inWork('a.txt'),
        'old_string': '= 1',
        'new_string': '= 2',
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('3 次'));
      expect(result.content, contains('第 1 行'));
      expect(result.content, contains('第 2 行'));
      expect(result.content, contains('replace_all'));
      expect(await file.readAsString(), 'x = 1\ny = 1\nz = 1\n');
    });

    test('确认要全改时 replace_all 能过', () async {
      final file = File(inWork('a.txt'))..writeAsStringSync('x = 1\ny = 1\n');

      final result = await run('edit_file', {
        'path': inWork('a.txt'),
        'old_string': '= 1',
        'new_string': '= 2',
        'replace_all': true,
      });

      expect(result.ok, isTrue);
      expect(await file.readAsString(), 'x = 2\ny = 2\n');
      expect(result.content, contains('2 处'));
    });

    test('找不到原文时给出能用的线索', () async {
      final file = File(inWork('a.txt'))
        ..writeAsStringSync('def compute_total():\n    pass\n');

      final result = await run('edit_file', {
        'path': inWork('a.txt'),
        'old_string': '    def compute_total():\n        pass',
        'new_string': 'x',
      });

      expect(result.ok, isFalse);
      // 宁可直接把"文件里跟这段沾边的行"摆出来，也别只说一句"找不到"——
      // 后者模型只能拿同一段原文继续撞。
      expect(result.content, contains('def compute_total():'));
      expect(result.content, contains('第 1 行'));
      expect(await file.readAsString(), contains('def compute_total'));
    });

    test('空 old_string 直接拒', () async {
      final file = File(inWork('a.txt'))..writeAsStringSync('abc');

      final result = await run('edit_file', {
        'path': inWork('a.txt'),
        'old_string': '',
        'new_string': 'x',
      });

      expect(result.ok, isFalse);
      expect(await file.readAsString(), 'abc');
    });

    test('改之前先备份', () async {
      final file = File(inWork('a.py'))..writeAsStringSync('a = 1\n');

      await run('edit_file', {
        'path': inWork('a.py'),
        'old_string': 'a = 1',
        'new_string': 'a = 2',
      });

      final saved = backups.dir.listSync().whereType<File>().toList();
      expect(saved, hasLength(1));
      expect(await saved.single.readAsString(), 'a = 1\n');
      expect(await file.readAsString(), 'a = 2\n');
    });

    test('受保护的目录改不动', () async {
      final file = File(p.join(sealed.path, 'a.txt'))..writeAsStringSync('abc');

      final result = await run('edit_file', {
        'path': file.path,
        'old_string': 'abc',
        'new_string': 'x',
      });

      expect(result.ok, isFalse);
      expect(await file.readAsString(), 'abc');
    });

    test('文件不存在时报的是"找不到"，不是"原文对不上"', () async {
      // 两件事让模型该做的下一步完全不同——一个去核对路径，
      // 一个去核对文字。混成一句话它就只会瞎撞。
      final result = await run('edit_file', {
        'path': inWork('没有这个.txt'),
        'old_string': 'a',
        'new_string': 'b',
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('找不到'));
    });
  });

  group('list_dir', () {
    test('目录排前面，各自按名字排', () async {
      File(inWork('b.txt')).writeAsStringSync('123');
      File(inWork('a.txt')).writeAsStringSync('45');
      Directory(inWork('sub')).createSync();

      final result = await run('list_dir', {'path': workspace.path});

      expect(result.ok, isTrue);
      final lines = result.content
          .split('\n')
          .where((l) => l.startsWith('['))
          .toList();
      expect(lines[0], contains('sub'));
      expect(lines[1], contains('a.txt'));
      expect(lines[2], contains('b.txt'));
      expect(result.content, contains('[目录]'));
      expect(result.content, contains('[文件]'));
      // 报的是字节数，不是内容——模型靠它判断"这个文件要不要整个读进来"。
      expect(lines[2], matches(RegExp(r'\[文件\]\s+3\s')));
      expect(result.content, contains('2026-'));
    });

    test('limit 限制条数并说明还有没列完的', () async {
      for (var i = 0; i < 10; i++) {
        File(inWork('f$i.txt')).writeAsStringSync('x');
      }

      final result = await run('list_dir', {
        'path': workspace.path,
        'limit': 3,
      });

      expect(result.content, contains('还有更多'));
      expect(
        result.content.split('\n').where((l) => l.startsWith('[文件]')),
        hasLength(3),
      );
    });

    test('空目录说清楚是空的', () async {
      final result = await run('list_dir', {'path': workspace.path});

      expect(result.ok, isTrue);
      expect(result.content, contains('空的'));
    });

    test('给的是文件时指向 read_file', () async {
      File(inWork('a.txt')).writeAsStringSync('x');

      final result = await run('list_dir', {'path': inWork('a.txt')});

      expect(result.ok, isFalse);
      expect(result.content, contains('read_file'));
    });

    test('目录不存在时报出同级的有什么', () async {
      Directory(inWork('真实目录')).createSync();

      final result = await run('list_dir', {'path': p.join(workspace.path, '错目录')});

      expect(result.ok, isFalse);
      expect(result.content, contains('真实目录'));
    });
  });

  group('注册表', () {
    test('平台不支持就一个都不注册', () {
      final none = fileTools(
        available: false,
        paths: PathResolver(home: tmp.path),
        policy: const FilePolicy.unrestricted(),
        backups: backups,
      );

      // 注册了再返回"不支持"，模型会反复重试同一个不可用的工具。
      expect(none, isEmpty);
    });

    test('每个文件工具的 schema 都是合法 JSON 对象形状', () {
      for (final t in tools) {
        expect(t.inputSchema['type'], 'object', reason: '${t.name} 的 schema');
        expect(t.inputSchema['properties'], isA<Map<String, Object?>>());
      }
      expect(
        tools.map((t) => t.name).toSet(),
        {
          'read_file',
          'write_file',
          'edit_file',
          'list_dir',
          'grep',
          'glob',
          'write_document',
        },
      );
    });
  });
}
