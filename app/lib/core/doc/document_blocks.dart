/// 文档里的一个块。
///
/// 刻意只做这几种：模型最会写的就是 Markdown，而这几种能覆盖"报告、说明、
/// 表格"的绝大多数场合。不支持任意 HTML——把 HTML 原样塞进 Word/PDF 是
/// 不可能忠实的，假装支持比不支持更糟。
sealed class DocBlock {
  const DocBlock();
}

class HeadingBlock extends DocBlock {
  const HeadingBlock(this.level, this.text);

  /// 1 到 6。生成时按级别挑字号。
  final int level;
  final String text;
}

class ParagraphBlock extends DocBlock {
  const ParagraphBlock(this.text);
  final String text;
}

class BulletBlock extends DocBlock {
  const BulletBlock(this.items);
  final List<String> items;
}

class OrderedBlock extends DocBlock {
  const OrderedBlock(this.items);
  final List<String> items;
}

class QuoteBlock extends DocBlock {
  const QuoteBlock(this.text);
  final String text;
}

class CodeBlock extends DocBlock {
  const CodeBlock(this.text);
  final String text;
}

class TableBlock extends DocBlock {
  const TableBlock(this.rows);

  /// 第一行是表头。每行的列数可能不齐，生成时按最宽的一行补齐。
  final List<List<String>> rows;

  int get columns => rows.fold(0, (max, row) => row.length > max ? row.length : max);
}

/// 把一段 Markdown 子集切成块。
///
/// 支持 `#` 标题、`-`/`*` 列表、`1.` 有序列表、`>` 引用、三个反引号的代码块、
/// `| a | b |` 表格。其余按段落处理。行内的 `**粗体**`、`[链接]()` 之类
/// **不解析**——去掉了标记，留纯文字；在 PDF/Word 里保持原样反而更乱。
List<DocBlock> parseDocumentBlocks(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final blocks = <DocBlock>[];

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed.isEmpty) {
      i++;
      continue;
    }

    if (trimmed.startsWith('```')) {
      final body = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        body.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // 跳过收尾的 ```
      blocks.add(CodeBlock(body.join('\n')));
      continue;
    }

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (heading != null) {
      blocks.add(
        HeadingBlock(heading.group(1)!.length, _stripInline(heading.group(2)!)),
      );
      i++;
      continue;
    }

    // 表格：当前行以 | 开头，下一行是 |---| 分隔行。
    if (trimmed.startsWith('|') &&
        i + 1 < lines.length &&
        _isTableDivider(lines[i + 1].trim())) {
      final rows = <List<String>>[_splitRow(trimmed)];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(_splitRow(lines[i].trim()));
        i++;
      }
      blocks.add(TableBlock(rows));
      continue;
    }

    if (trimmed.startsWith('>')) {
      final body = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        body.add(_stripInline(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), '')));
        i++;
      }
      blocks.add(QuoteBlock(body.join('\n')));
      continue;
    }

    final bullet = RegExp(r'^[-*+]\s+(.*)$');
    if (bullet.hasMatch(trimmed)) {
      final items = <String>[];
      while (i < lines.length) {
        final m = bullet.firstMatch(lines[i].trim());
        if (m == null) break;
        items.add(_stripInline(m.group(1)!));
        i++;
      }
      blocks.add(BulletBlock(items));
      continue;
    }

    final ordered = RegExp(r'^\d+[.)]\s+(.*)$');
    if (ordered.hasMatch(trimmed)) {
      final items = <String>[];
      while (i < lines.length) {
        final m = ordered.firstMatch(lines[i].trim());
        if (m == null) break;
        items.add(_stripInline(m.group(1)!));
        i++;
      }
      blocks.add(OrderedBlock(items));
      continue;
    }

    // 普通段落：一直吃到空行或下一个特殊块。
    final paragraph = <String>[];
    while (i < lines.length) {
      final t = lines[i].trim();
      if (t.isEmpty ||
          t.startsWith('#') ||
          t.startsWith('```') ||
          t.startsWith('>') ||
          bullet.hasMatch(t) ||
          ordered.hasMatch(t) ||
          (t.startsWith('|') &&
              i + 1 < lines.length &&
              _isTableDivider(lines[i + 1].trim()))) {
        break;
      }
      paragraph.add(t);
      i++;
    }
    if (paragraph.isNotEmpty) {
      blocks.add(ParagraphBlock(_stripInline(paragraph.join(' '))));
    }
  }

  return blocks;
}

/// 去掉行内标记。链接保留文字、丢掉地址；图片保留 alt。
String _stripInline(String text) => text
    .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
    .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
    .replaceAll(RegExp(r'\*\*|__|`'), '')
    .trim();

bool _isTableDivider(String line) =>
    RegExp(r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?$').hasMatch(line);

List<String> _splitRow(String line) {
  var body = line;
  if (body.startsWith('|')) body = body.substring(1);
  if (body.endsWith('|')) body = body.substring(0, body.length - 1);
  return body.split('|').map((c) => _stripInline(c)).toList();
}
