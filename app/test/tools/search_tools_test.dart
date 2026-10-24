import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/fs/local_file_backups.dart';
import 'package:path/path.dart' as p;

import '../support/fake_llm.dart';

/// `grep` / `glob`。
///
/// 跟 `file_tools_test.dart` 一样用真的临时目录：这两个工具要验的正是
/// "递归有没有漏、跳过目录有没有真跳过、行号对不对"，mock 出来的绿没意义。
void main() {
  late Directory tmp;
  late Directory workspace;
  late List<N1Tool> tools;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-search-tools');
    workspace = Directory(p.join(tmp.path, 'work'))..createSync();

    tools = fileTools(
      available: true,
      paths: PathResolver(
        home: tmp.path,
        knownFolders: {KnownFolder.desktop: workspace.path},
      ),
      policy: FilePolicy(sealedRoots: const []),
      backups: LocalFileBackupStore(dir: Directory(p.join(tmp.path, 'backups'))),
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

  File write(String relative, String content) {
    final file = File(p.join(workspace.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  group('grep', () {
    test('找到内容，返回文件路径和行号', () async {
      write('a.dart', '第一行\nfinal answer = 42;\n第三行\n');

      final result = await run('grep', {
        'pattern': 'answer',
        'path': workspace.path,
      });

      expect(result.ok, isTrue);
      expect(result.content, contains('a.dart'));
      expect(result.content, contains(':2: '));
      expect(result.content, contains('final answer = 42;'));
    });

    test('默认不区分大小写', () async {
      write('a.txt', 'Hello World\n');

      final lower = await run('grep', {
        'pattern': 'hello',
        'path': workspace.path,
      });
      expect(lower.content, contains('Hello World'));

      final upper = await run('grep', {
        'pattern': 'HELLO',
        'path': workspace.path,
      });
      expect(upper.content, contains('Hello World'));
    });

    test('case_sensitive: true 时大小写对不上就不算命中', () async {
      write('a.txt', 'Hello World\n');

      final result = await run('grep', {
        'pattern': 'hello',
        'path': workspace.path,
        'case_sensitive': true,
      });

      expect(result.ok, isTrue);
      expect(result.content, contains('没有找到'));
    });

    test('递归进子目录', () async {
      write('lib/deep/nested/a.dart', 'needle here\n');

      final result = await run('grep', {
        'pattern': 'needle',
        'path': workspace.path,
      });

      expect(result.content, contains('nested'));
    });

    test('glob 只搜匹配的文件名', () async {
      write('a.dart', 'needle\n');
      write('a.txt', 'needle\n');

      final result = await run('grep', {
        'pattern': 'needle',
        'path': workspace.path,
        'glob': '*.dart',
      });

      expect(result.content, contains('a.dart'));
      expect(result.content, isNot(contains('a.txt')));
    });

    test('context 带出前后行，用 - 区分', () async {
      write('a.txt', '上一行\nneedle\n下一行\n');

      final result = await run('grep', {
        'pattern': 'needle',
        'path': workspace.path,
        'context': 1,
      });

      expect(result.content, contains(':2: needle'));
      expect(result.content, contains(':1- 上一行'));
      expect(result.content, contains(':3- 下一行'));
    });

    test('跳过 node_modules / .git / build', () async {
      write('node_modules/pkg/index.js', 'needle\n');
      write('.git/config', 'needle\n');
      write('build/out.txt', 'needle\n');
      write('src/a.dart', 'needle\n');

      final result = await run('grep', {
        'pattern': 'needle',
        'path': workspace.path,
      });

      expect(result.content, contains('src'));
      expect(result.content, isNot(contains('node_modules')));
      expect(result.content, isNot(contains('.git')));
      expect(result.content, isNot(contains('build')));
    });

    test('二进制文件跳过，不算命中', () async {
      File(p.join(workspace.path, 'blob.bin')).writeAsBytesSync([
        ...'needle'.codeUnits,
        0,
        ...'needle'.codeUnits,
      ]);

      final result = await run('grep', {
        'pattern': 'needle',
        'path': workspace.path,
      });

      expect(result.content, contains('没有找到'));
    });

    test('正则写错时明确告诉模型，不是抛异常', () async {
      write('a.txt', 'x\n');

      final result = await run('grep', {
        'pattern': '([',
        'path': workspace.path,
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('正则写错了'));
    });

    test('路径不存在时给同级目录提示', () async {
      final result = await run('grep', {
        'pattern': 'x',
        'path': p.join(workspace.path, 'nope'),
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('找不到'));
    });

    test('path 是单个文件时只搜这个文件', () async {
      final file = write('a.txt', 'needle\n');

      final result = await run('grep', {
        'pattern': 'needle',
        'path': file.path,
      });

      expect(result.ok, isTrue);
      expect(result.content, contains('a.txt'));
    });

    test('max_results 到了就截断，并明说只列了前几条', () async {
      write('a.txt', List.generate(20, (i) => 'needle $i').join('\n'));

      final result = await run('grep', {
        'pattern': 'needle',
        'path': workspace.path,
        'max_results': 3,
      });

      expect(result.ok, isTrue);
      expect(result.content, contains('只列了前 3 条'));
    });

    test('结果里的行号对应真实行号，不是 0 起', () async {
      write('a.txt', 'one\ntwo\nthree\nfour\n');

      final result = await run('grep', {
        'pattern': 'four',
        'path': workspace.path,
      });

      expect(result.content, contains(':4: four'));
    });
  });

  group('glob', () {
    test('** 能匹配根目录和任意层子目录', () async {
      write('root.dart', '');
      write('lib/a.dart', '');
      write('lib/deep/b.dart', '');

      final result = await run('glob', {
        'pattern': '**/*.dart',
        'path': workspace.path,
      });

      expect(result.ok, isTrue);
      expect(result.content, contains('root.dart'));
      expect(result.content, contains('a.dart'));
      expect(result.content, contains('b.dart'));
    });

    test('单星只匹配当前这一层', () async {
      write('root.txt', '');
      write('sub/nested.txt', '');

      final result = await run('glob', {
        'pattern': '*.txt',
        'path': workspace.path,
      });

      expect(result.content, contains('root.txt'));
      expect(result.content, isNot(contains('nested.txt')));
    });

    test('花括号多选一', () async {
      write('a.jpg', '');
      write('b.png', '');
      write('c.gif', '');

      final result = await run('glob', {
        'pattern': '*.{jpg,png}',
        'path': workspace.path,
      });

      expect(result.content, contains('a.jpg'));
      expect(result.content, contains('b.png'));
      expect(result.content, isNot(contains('c.gif')));
    });

    test('跳过 node_modules', () async {
      write('node_modules/pkg/index.js', '');
      write('src/a.dart', '');

      final result = await run('glob', {
        'pattern': '**/*',
        'path': workspace.path,
      });

      expect(result.content, contains('src'));
      expect(result.content, isNot(contains('node_modules')));
    });

    test('按修改时间从新到旧', () async {
      final old = write('old.txt', '');
      final newer = write('new.txt', '');
      old.setLastModifiedSync(DateTime(2020, 1, 1));
      newer.setLastModifiedSync(DateTime(2023, 1, 1));

      final result = await run('glob', {
        'pattern': '*.txt',
        'path': workspace.path,
      });

      // 标题行里也有 `*.txt`，所以不能按"包含 .txt"筛行；直接比出现位置。
      expect(
        result.content.indexOf('new.txt'),
        lessThan(result.content.indexOf('old.txt')),
      );
    });

    test('limit 到了就截断', () async {
      for (var i = 0; i < 10; i++) {
        write('f$i.txt', '');
      }

      final result = await run('glob', {
        'pattern': '*.txt',
        'path': workspace.path,
        'limit': 3,
      });

      expect(result.ok, isTrue);
      expect(result.content, contains('只列了前 3 个'));
    });

    test('没有匹配时明确说没有', () async {
      write('a.txt', '');

      final result = await run('glob', {
        'pattern': '*.dart',
        'path': workspace.path,
      });

      expect(result.ok, isTrue);
      expect(result.content, contains('没有匹配'));
    });

    test('path 传文件时如实报错', () async {
      final file = write('a.txt', '');

      final result = await run('glob', {
        'pattern': '*.txt',
        'path': file.path,
      });

      expect(result.ok, isFalse);
      expect(result.content, contains('不是目录'));
    });
  });
}
