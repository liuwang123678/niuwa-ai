import 'dart:convert';

import 'package:archive/archive.dart';

import 'document_blocks.dart';

/// 生成 .docx。
///
/// 手写 OOXML 而不是引一个模板库：docx 本质就是个装 XML 的 zip，
/// 这几种块用不到模板引擎。自己写的好处是**不依赖任何 office 库**，
/// Android 和 Windows 上是同一份字节。
List<int> buildDocx({
  required String title,
  required List<DocBlock> blocks,
}) {
  final body = StringBuffer();

  if (title.trim().isNotEmpty) {
    body.write(_paragraph(title, size: 40, bold: true, after: 240));
  }

  for (final block in blocks) {
    switch (block) {
      case HeadingBlock(:final level, :final text):
        final size = switch (level) {
          1 => 36,
          2 => 32,
          3 => 28,
          _ => 24,
        };
        body.write(_paragraph(text, size: size, bold: true, after: 160));
      case ParagraphBlock(:final text):
        body.write(_paragraph(text));
      case BulletBlock(:final items):
        for (final item in items) {
          body.write(_paragraph('• $item', indent: 360));
        }
      case OrderedBlock(:final items):
        for (var i = 0; i < items.length; i++) {
          body.write(_paragraph('${i + 1}. ${items[i]}', indent: 360));
        }
      case QuoteBlock(:final text):
        body.write(_paragraph(text, italic: true, indent: 360));
      case CodeBlock(:final text):
        body.write(_code(text));
      case TableBlock(:final rows):
        body.write(_table(rows));
    }
  }

  final document = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>$body<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body>
</w:document>''';

  return _zip({
    '[Content_Types].xml': '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''',
    '_rels/.rels': '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''',
    'word/document.xml': document,
  });
}

String _paragraph(
  String text, {
  int? size,
  bool bold = false,
  bool italic = false,
  int? indent,
  int after = 120,
}) {
  final runProps = [
    if (bold) '<w:b/>',
    if (italic) '<w:i/>',
    if (size != null) '<w:sz w:val="$size"/><w:szCs w:val="$size"/>',
  ].join();

  final paraProps = [
    if (indent != null) '<w:ind w:left="$indent"/>',
    '<w:spacing w:after="$after"/>',
  ].join();

  // 文本里的换行要变成 <w:br/>，否则 Word 会把它当成一个空格。
  final runs = text.split('\n').map((line) {
    return '<w:r><w:rPr>$runProps</w:rPr>'
        '<w:t xml:space="preserve">${_esc(line)}</w:t></w:r>';
  }).join('<w:r><w:br/></w:r>');

  return '<w:p><w:pPr>$paraProps</w:pPr>$runs</w:p>';
}

String _code(String text) {
  final lines = text.split('\n').map((line) {
    return '<w:p><w:pPr><w:spacing w:after="0"/><w:shd w:val="clear" w:fill="F4F4F4"/></w:pPr>'
        '<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>'
        '<w:sz w:val="20"/></w:rPr>'
        '<w:t xml:space="preserve">${_esc(line)}</w:t></w:r></w:p>';
  }).join();
  return '$lines<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>';
}

String _table(List<List<String>> rows) {
  if (rows.isEmpty) return '';

  final columns = rows.fold<int>(1, (max, r) => r.length > max ? r.length : max);
  const totalWidth = 9000;
  final width = totalWidth ~/ columns;

  final grid = List.filled(columns, '<w:gridCol w:w="$width"/>').join();

  final body = StringBuffer();
  for (var r = 0; r < rows.length; r++) {
    body.write('<w:tr>');
    for (var c = 0; c < columns; c++) {
      final text = c < rows[r].length ? rows[r][c] : '';
      body.write(
        '<w:tc><w:tcPr><w:tcW w:w="$width" w:type="dxa"/></w:tcPr>'
        '${_paragraph(text, bold: r == 0, after: 40)}</w:tc>',
      );
    }
    body.write('</w:tr>');
  }

  const border = '<w:val="single" w:sz="4" w:space="0" w:color="AAAAAA"/>';
  final borders =
      '<w:tblBorders>'
      '<w:top $border/><w:left $border/><w:bottom $border/><w:right $border/>'
      '<w:insideH $border/><w:insideV $border/>'
      '</w:tblBorders>';

  return '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>$borders</w:tblPr>'
      '<w:tblGrid>$grid</w:tblGrid>$body</w:tbl>'
      '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>';
}

/// 生成 .xlsx。每个表格块一个 sheet；一个表格都没有时，把正文按行放进第一列。
List<int> buildXlsx({
  required String title,
  required List<DocBlock> blocks,
}) {
  final tables = blocks.whereType<TableBlock>().toList();

  final sheets = <List<List<String>>>[];
  if (tables.isEmpty) {
    final lines = <List<String>>[];
    if (title.trim().isNotEmpty) lines.add([title]);
    for (final block in blocks) {
      switch (block) {
        case ParagraphBlock(:final text):
          lines.add([text]);
        case BulletBlock(:final items):
        case OrderedBlock(:final items):
          for (final item in items) {
            lines.add([item]);
          }
        case HeadingBlock(:final text):
          lines.add([text]);
        case QuoteBlock(:final text):
          lines.add([text]);
        case CodeBlock(:final text):
          for (final line in text.split('\n')) {
            lines.add([line]);
          }
        case TableBlock():
          break;
      }
    }
    sheets.add(lines);
  } else {
    sheets.addAll(tables.map((t) => t.rows));
  }

  final sheetEntries = <String, String>{};
  final relEntries = <String, String>{};
  final sheetTags = <String>[];

  for (var i = 0; i < sheets.length; i++) {
    final n = i + 1;
    sheetEntries['xl/worksheets/sheet$n.xml'] = _sheetXml(sheets[i]);
    relEntries['rId$n'] = 'worksheets/sheet$n.xml';
    sheetTags.add(
      '<sheet name="Sheet$n" sheetId="$n" r:id="rId$n"/>',
    );
  }

  // 表头用了 s="1"，样式表就必须真的在包里；少了它 Excel 会弹"需要修复"。
  final stylesRelId = 'rId${sheets.length + 1}';
  relEntries[stylesRelId] = 'styles.xml';

  final workbook = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>${sheetTags.join()}</sheets>
</workbook>''';

  final workbookRels = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${relEntries.entries.map((e) => '<Relationship Id="${e.key}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="${e.value}"/>').join()}
<Relationship Id="$stylesRelId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''';

  final overrides = [
    for (var i = 0; i < sheets.length; i++)
      '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
  ].join();

  return _zip({
    '[Content_Types].xml': '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
$overrides
</Types>''',
    '_rels/.rels': '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''',
    'xl/workbook.xml': workbook,
    'xl/_rels/workbook.xml.rels': workbookRels,
    'xl/styles.xml': _xlsxStyles,
    ...sheetEntries,
  });
}

String _sheetXml(List<List<String>> rows) {
  final buffer = StringBuffer();
  for (var r = 0; r < rows.length; r++) {
    buffer.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      final ref = '${_columnName(c)}${r + 1}';
      final text = rows[r][c];
      if (text.isEmpty) continue;
      final style = r == 0 ? ' s="1"' : '';
      buffer.write(
        '<c r="$ref"$style t="inlineStr"><is><t xml:space="preserve">'
        '${_esc(text)}</t></is></c>',
      );
    }
    buffer.write('</row>');
  }

  return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<cols><col min="1" max="26" width="22" customWidth="1"/></cols>
<sheetData>$buffer</sheetData>
</worksheet>''';
}

/// 0 → A，25 → Z，26 → AA。
String _columnName(int index) {
  var n = index;
  final chars = <String>[];
  do {
    chars.insert(0, String.fromCharCode(65 + n % 26));
    n = n ~/ 26 - 1;
  } while (n >= 0);
  return chars.join();
}

/// 表头加粗用的样式表。没有把 `s="1"` 引到不存在的样式上——那会让 Excel
/// 报"文件需要修复"。
const _xlsxStyles = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border/></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>
</styleSheet>''';

List<int> _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

String _esc(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
