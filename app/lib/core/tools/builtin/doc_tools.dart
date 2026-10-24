import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../code/file_backup.dart';
import '../../doc/document_blocks.dart';
import '../../doc/office_writers.dart';
import '../../doc/pdf_writer.dart';
import '../n1_tool.dart';
import '../tool_context.dart';
import 'file_tools.dart';

/// 能生成的格式。扩展名和它一一对应。
const Set<String> _formats = {'pdf', 'docx', 'xlsx', 'md', 'txt'};

/// 生成文档（PDF / Word / Excel / Markdown / 纯文本）。
///
/// 为什么要有这个工具，而不是让模型用 `write_file` 直接写字：
/// docx/xlsx 是 zip 包，pdf 是带字体嵌入的二进制格式——模型**写不出**这些
/// 字节。它只会写 Markdown，所以这里的接口也就只收 Markdown，格式转换在
/// 本地做。
class WriteDocumentTool extends FileToolBase {
  const WriteDocumentTool({
    required super.paths,
    required super.policy,
    required this.backups,
    this.loadFont,
  });

  final FileBackupStore backups;

  /// 取中文字体的字节。**由 services 层注入**（core 不能 import Flutter，
  /// 拿不到 rootBundle）。为 null 时 PDF 只能显示西文。
  final Future<ByteData?> Function()? loadFont;

  @override
  String get name => 'write_document';

  @override
  String get description =>
      '把内容写成一份文档文件：PDF、Word（.docx）、Excel（.xlsx）、'
      'Markdown（.md）、纯文本（.txt）。'
      '内容用 Markdown 写，支持标题、列表、引用、代码块和表格——'
      'xlsx 会把每个表格放进单独的 sheet。'
      '要生成 Word/PDF/Excel 必须用这个工具，`write_file` 只能写文本。'
      '覆盖已有文件会自动备份。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': '写到哪个文件。扩展名决定格式（.pdf/.docx/.xlsx/.md/.txt）',
      },
      'content': {
        'type': 'string',
        'description': '文档内容，用 Markdown 写',
      },
      'title': {
        'type': 'string',
        'description': '文档标题。PDF 会放在第一页顶部，docx 会作为首行标题；'
            'xlsx 没有表格时作为第一行',
      },
      'format': {
        'type': 'string',
        'enum': ['pdf', 'docx', 'xlsx', 'md', 'txt'],
        'description': '不填就按 path 的扩展名判断',
      },
      'create_parents': {
        'type': 'boolean',
        'description': '父目录不存在时自动创建，默认 false',
      },
    },
    'required': ['path', 'content'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      guard(input, (absolute) async {
        final content = FileToolBase.requireRaw(input, 'content');
        final title = N1Tool.optionalString(input, 'title') ?? '';
        final explicit = N1Tool.optionalString(input, 'format')?.toLowerCase();
        final format = explicit ?? _extensionOf(absolute);

        if (!_formats.contains(format)) {
          return ToolResult.fail(
            '认不出要生成什么格式（`${explicit ?? _extensionOf(absolute)}`）。'
            '支持：${_formats.join(' / ')}。'
            '扩展名要和格式一致，或者显式给 format。',
          );
        }

        final createParents = input['create_parents'] == true;
        final parentPath = _parentOf(absolute);
        if (parentPath != null) {
          final parent = Directory(parentPath);
          if (!await parent.exists()) {
            if (!createParents) {
              return ToolResult.fail(
                '`$parentPath` 这个目录不存在。'
                '如果确实要建，重新调一次并带上 create_parents: true。',
              );
            }
            try {
              await parent.create(recursive: true);
            } on FileSystemException catch (e) {
              return ToolResult.fail(
                '建不了目录 `$parentPath`：${e.osError?.message ?? e.message}',
              );
            }
          }
        }

        if (FileSystemEntity.typeSync(absolute) == FileSystemEntityType.directory) {
          return ToolResult.fail('`$absolute` 是个目录，写不了。');
        }

        final blocks = parseDocumentBlocks(content);

        final Uint8List bytes;
        try {
          bytes = await _render(format, title: title, blocks: blocks);
        } on Object catch (e) {
          return ToolResult.fail('生成 $format 失败：$e');
        }

        final file = File(absolute);
        final existed = await file.exists();
        FileBackup? backup;
        if (existed) {
          try {
            backup = await backups.backup(absolute);
          } catch (e) {
            return ToolResult.fail(
              '要覆盖 `$absolute`，但备份失败（$e），所以没动它。'
              '告诉用户这件事，让他自己决定。',
            );
          }
        }

        try {
          await FileToolBase.writeAtomically(file, bytes);
        } on FileSystemException catch (e) {
          return ToolResult.fail(
            '写 `$absolute` 失败：${e.osError?.message ?? e.message}',
          );
        }

        final buffer = StringBuffer()
          ..write('${existed ? '已覆盖' : '已生成'} `$absolute`')
          ..write('（$format，${bytes.length} 字节）');
        if (format == 'pdf' && loadFont == null) {
          buffer.write('\n注意：这次没加载到中文字体，PDF 里的中文会显示不出来。');
        }
        if (backup != null) {
          buffer.write('\n原来的那份备份在 `${backup.copyPath}`');
          final pruned = await backups.prune();
          if (pruned > 0) buffer.write('（顺手清掉了 $pruned 个更老的备份）');
        }

        return ToolResult.ok(buffer.toString(), meta: {'path': absolute});
      }, forWrite: true);

  Future<Uint8List> _render(
    String format, {
    required String title,
    required List<DocBlock> blocks,
  }) async {
    switch (format) {
      case 'pdf':
        final font = await loadFont?.call();
        return buildPdf(title: title, blocks: blocks, fontData: font);
      case 'docx':
        return Uint8List.fromList(buildDocx(title: title, blocks: blocks));
      case 'xlsx':
        return Uint8List.fromList(buildXlsx(title: title, blocks: blocks));
      case 'md':
        return Uint8List.fromList(
          utf8.encode(title.isEmpty ? _markdownBody(blocks) : '# $title\n\n${_markdownBody(blocks)}'),
        );
      case 'txt':
        return Uint8List.fromList(
          utf8.encode(_plainText(title: title, blocks: blocks)),
        );
      default:
        throw StateError('不支持的格式 `$format`');
    }
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  static String? _parentOf(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    if (cut <= 0) return null;
    final parent = path.substring(0, cut);
    if (parent.length == 2 && RegExp(r'^[A-Za-z]:').hasMatch(parent)) {
      return '$parent\\';
    }
    return parent;
  }
}

/// 纯文本版。markdown 标记全部去掉，结构靠缩进和空行保留。
String _plainText({required String title, required List<DocBlock> blocks}) {
  final buffer = StringBuffer();
  if (title.isNotEmpty) buffer.writeln('$title\n');

  for (final block in blocks) {
    switch (block) {
      case HeadingBlock(:final text):
        buffer.writeln('$text\n');
      case ParagraphBlock(:final text):
        buffer.writeln('$text\n');
      case BulletBlock(:final items):
        for (final item in items) {
          buffer.writeln('· $item');
        }
        buffer.writeln();
      case OrderedBlock(:final items):
        for (var i = 0; i < items.length; i++) {
          buffer.writeln('${i + 1}. ${items[i]}');
        }
        buffer.writeln();
      case QuoteBlock(:final text):
        for (final line in text.split('\n')) {
          buffer.writeln('    $line');
        }
        buffer.writeln();
      case CodeBlock(:final text):
        buffer.writeln(text);
        buffer.writeln();
      case TableBlock(:final rows):
        for (final row in rows) {
          buffer.writeln(row.join('\t'));
        }
        buffer.writeln();
    }
  }
  return buffer.toString().trimRight();
}

/// 原样写回 Markdown。只在这一处把块重新拼成文本——用于 `.md`，
/// 让"生成 md"和"生成 docx"走同一套解析，标题/表格的识别结果一致。
String _markdownBody(List<DocBlock> blocks) {
  final buffer = StringBuffer();
  for (final block in blocks) {
    switch (block) {
      case HeadingBlock(:final level, :final text):
        buffer.writeln('${'#' * level} $text\n');
      case ParagraphBlock(:final text):
        buffer.writeln('$text\n');
      case BulletBlock(:final items):
        for (final item in items) {
          buffer.writeln('- $item');
        }
        buffer.writeln();
      case OrderedBlock(:final items):
        for (var i = 0; i < items.length; i++) {
          buffer.writeln('${i + 1}. ${items[i]}');
        }
        buffer.writeln();
      case QuoteBlock(:final text):
        for (final line in text.split('\n')) {
          buffer.writeln('> $line');
        }
        buffer.writeln();
      case CodeBlock(:final text):
        buffer.writeln('```\n$text\n```\n');
      case TableBlock(:final rows):
        if (rows.isEmpty) break;
        for (var r = 0; r < rows.length; r++) {
          buffer.writeln('| ${rows[r].join(' | ')} |');
          if (r == 0) {
            buffer.writeln('|${List.filled(rows[r].length, ' --- ').join('|')}|');
          }
        }
        buffer.writeln();
    }
  }
  return buffer.toString().trimRight();
}
