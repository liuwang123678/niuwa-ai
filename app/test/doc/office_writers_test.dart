import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/doc/document_blocks.dart';
import 'package:niuwa_ai/core/doc/office_writers.dart';

/// 解析 zip 里的一个 XML，返回文本。
String part(List<int> bytes, String name) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.files.firstWhere(
    (f) => f.name == name,
    orElse: () => throw StateError('包里没有 $name，只有 ${archive.files.map((f) => f.name)}'),
  );
  return utf8.decode(file.content);
}

List<String> names(List<int> bytes) =>
    ZipDecoder().decodeBytes(bytes).files.map((f) => f.name).toList();

void main() {
  const blocks = [
    HeadingBlock(1, '季度报告'),
    ParagraphBlock('这是正文。'),
    BulletBlock(['甲', '乙']),
    TableBlock([
      ['项目', '金额'],
      ['收入', '100'],
    ]),
  ];

  group('buildDocx', () {
    test('是一个带齐三件套的 zip', () {
      final bytes = buildDocx(title: '标题', blocks: blocks);
      final entries = names(bytes);

      expect(entries, containsAll(['[Content_Types].xml', '_rels/.rels', 'word/document.xml']));
      expect(bytes.sublist(0, 2), [0x50, 0x4B], reason: 'zip 的魔数必须是 PK');
    });

    test('标题、正文、列表项、表格单元格都进了 document.xml', () {
      final xml = part(buildDocx(title: '标题', blocks: blocks), 'word/document.xml');

      expect(xml, contains('标题'));
      expect(xml, contains('季度报告'));
      expect(xml, contains('这是正文。'));
      expect(xml, contains('• 甲'));
      expect(xml, contains('<w:tbl>'));
      expect(xml, contains('收入'));
    });

    test('特殊字符被转义，没有裸的 & 或 <', () {
      final xml = part(
        buildDocx(
          title: '',
          blocks: const [ParagraphBlock('a & b < c > d "e"')],
        ),
        'word/document.xml',
      );

      expect(xml, contains('a &amp; b &lt; c &gt; d &quot;e&quot;'));
      expect(xml, isNot(contains('a & b')));
    });

    test('空文档也能生成，不是坏的 zip', () {
      final bytes = buildDocx(title: '', blocks: const []);

      expect(part(bytes, 'word/document.xml'), contains('<w:body>'));
    });
  });

  group('buildXlsx', () {
    test('每个表格一个 sheet，工作表关系对得上', () {
      final bytes = buildXlsx(
        title: '',
        blocks: const [
          TableBlock([
            ['a', 'b'],
            ['1', '2'],
          ]),
          TableBlock([
            ['c'],
            ['3'],
          ]),
        ],
      );

      final entries = names(bytes);
      expect(entries, containsAll(['xl/workbook.xml', 'xl/styles.xml']));
      expect(entries, containsAll(['xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml']));

      final workbook = part(bytes, 'xl/workbook.xml');
      expect(workbook, contains('name="Sheet1"'));
      expect(workbook, contains('name="Sheet2"'));

      final rels = part(bytes, 'xl/_rels/workbook.xml.rels');
      expect(rels, contains('worksheets/sheet1.xml'));
      expect(rels, contains('styles.xml'));
    });

    test('表头带加粗样式，数据行不带', () {
      final xml = part(
        buildXlsx(
          title: '',
          blocks: const [
            TableBlock([
              ['名字', '数量'],
              ['苹果', '3'],
            ]),
          ],
        ),
        'xl/worksheets/sheet1.xml',
      );

      expect(xml, contains('<c r="A1" s="1" t="inlineStr">'));
      expect(xml, contains('<c r="A2" t="inlineStr">'));
      expect(xml, contains('名字'));
    });

    test('没有表格时按行铺进第一列，不是空文件', () {
      final xml = part(
        buildXlsx(
          title: '报告',
          blocks: const [ParagraphBlock('第一段'), ParagraphBlock('第二段')],
        ),
        'xl/worksheets/sheet1.xml',
      );

      expect(xml, contains('报告'));
      expect(xml, contains('第一段'));
      expect(xml, contains('第二段'));
    });

    test('列名超过 Z 会进位成 AA', () {
      final row = List.generate(28, (i) => 'c$i');
      final xml = part(
        buildXlsx(title: '', blocks: [TableBlock([row])]),
        'xl/worksheets/sheet1.xml',
      );

      expect(xml, contains('r="Z1"'));
      expect(xml, contains('r="AA1"'));
      expect(xml, contains('r="AB1"'));
    });

    test('样式表真的在包里（引用 s="1" 却没 styles.xml 会被 Excel 判成损坏）', () {
      final bytes = buildXlsx(title: '', blocks: const [TableBlock([['x']])]);

      expect(part(bytes, 'xl/styles.xml'), contains('<cellXfs'));
      expect(part(bytes, '[Content_Types].xml'), contains('/xl/styles.xml'));
    });
  });
}
