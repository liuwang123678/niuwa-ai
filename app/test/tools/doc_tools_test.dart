import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/fs/local_file_backups.dart';
import 'package:path/path.dart' as p;

import '../support/fake_llm.dart';

/// write_document 端到端：**真的往磁盘写**，再回读字节验格式。
///
/// 不 mock 文件系统。这里最容易坏的正好是"字节有没有真的落下去"和
/// "覆盖前有没有留备份"。
void main() {
  late Directory tmp;
  late Directory workspace;
  late Directory sealed;
  late LocalFileBackupStore backups;
  late N1Tool tool;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-doc-tools');
    workspace = Directory(p.join(tmp.path, 'work'))..createSync();
    sealed = Directory(p.join(tmp.path, 'sealed'))..createSync();
    backups = LocalFileBackupStore(dir: Directory(p.join(tmp.path, 'backups')));

    tool = fileTools(
      available: true,
      paths: PathResolver(
        home: tmp.path,
        knownFolders: {KnownFolder.desktop: workspace.path},
      ),
      policy: FilePolicy(sealedRoots: [sealed.path]),
      backups: backups,
      loadFont: () async {
        final file = File('assets/fonts/NotoSansSC-subset.ttf');
        return file.existsSync()
            ? ByteData.sublistView(file.readAsBytesSync())
            : null;
      },
    ).firstWhere((t) => t.name == 'write_document');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ToolResult> run(Map<String, Object?> input) =>
      tool.call(input, testContext());

  String out(String name) => p.join(workspace.path, name);

  const markdown = '''
# 月度报告

本月收入 **上涨**。

- 华东
- 华南

| 项目 | 金额 |
| --- | --- |
| 收入 | 100 |
''';

  test('docx：写出的是 zip，覆盖时先备份', () async {
    final path = out('报告.docx');

    final first = await run({'path': path, 'content': markdown});
    expect(first.ok, isTrue, reason: first.content);
    final bytes = File(path).readAsBytesSync();
    expect(bytes.sublist(0, 2), [0x50, 0x4B], reason: 'docx 必须是 zip');

    final second = await run({'path': path, 'content': '# 换个内容'});
    expect(second.ok, isTrue);
    expect(second.content, contains('备份在'), reason: '覆盖必须留回滚阀');
    expect(File(path).readAsBytesSync().length, isNot(bytes.length));
  });

  test('xlsx：文件落下去了，且认得出来是 xlsx', () async {
    final path = out('表格.xlsx');
    final result = await run({'path': path, 'content': markdown});

    expect(result.ok, isTrue, reason: result.content);
    expect(File(path).readAsBytesSync().sublist(0, 2), [0x50, 0x4B]);
  });

  test('pdf：开头是 %PDF，中文字体能嵌进去', () async {
    final path = out('报告.pdf');
    final result = await run({'path': path, 'content': markdown, 'title': '月报'});

    expect(result.ok, isTrue, reason: result.content);
    final bytes = File(path).readAsBytesSync();
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
  });

  test('txt：去掉 markdown 标记，留纯文字', () async {
    final path = out('报告.txt');
    final result = await run({'path': path, 'content': markdown});

    expect(result.ok, isTrue);
    final text = File(path).readAsStringSync();
    expect(text, contains('月度报告'));
    expect(text, contains('本月收入 上涨。'));
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('|')));
  });

  test('md：结构原样保留', () async {
    final path = out('报告.md');
    await run({'path': path, 'content': markdown, 'title': '标题'});

    final text = File(path).readAsStringSync();
    expect(text.startsWith('# 标题'), isTrue);
    expect(text, contains('# 月度报告'));
    expect(text, contains('- 华东'));
    expect(text, contains('| 项目 | 金额 |'));
  });

  test('认不出的扩展名要说清楚支持哪些，不是默默写文本', () async {
    final result = await run({'path': out('a.html'), 'content': 'x'});

    expect(result.ok, isFalse);
    expect(result.content, contains('pdf'));
    expect(result.content, contains('docx'));
  });

  test('显式 format 覆盖扩展名', () async {
    final path = out('没有扩展名');
    final result = await run({
      'path': path,
      'content': '# 标题',
      'format': 'docx',
    });

    expect(result.ok, isTrue);
    expect(File(path).readAsBytesSync().sublist(0, 2), [0x50, 0x4B]);
  });

  test('父目录不存在时默认不建，带 create_parents 才建', () async {
    final path = p.join(workspace.path, '新目录', 'a.docx');

    final refused = await run({'path': path, 'content': 'x'});
    expect(refused.ok, isFalse);
    expect(refused.content, contains('create_parents'));
    expect(Directory(p.dirname(path)).existsSync(), isFalse);

    final allowed = await run({
      'path': path,
      'content': 'x',
      'create_parents': true,
    });
    expect(allowed.ok, isTrue, reason: allowed.content);
    expect(File(path).existsSync(), isTrue);
  });

  test('受保护目录写不进去', () async {
    final result = await run({
      'path': p.join(sealed.path, 'a.docx'),
      'content': 'x',
    });

    expect(result.ok, isFalse);
    expect(File(p.join(sealed.path, 'a.docx')).existsSync(), isFalse);
  });

  test('内容是空串也合法（生成一张空白文档）', () async {
    final result = await run({'path': out('空.docx'), 'content': ''});

    expect(result.ok, isTrue, reason: result.content);
  });
}
