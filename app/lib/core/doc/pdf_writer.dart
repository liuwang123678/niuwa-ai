import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_blocks.dart';

/// 生成 PDF。
///
/// 字体必须从外面递进来（[fontData]），因为这个文件在 core 层，不能 import
/// Flutter 的 `rootBundle`。真正的加载在 services 层。
///
/// 中文字体是**必需**的：PDF 内置的 Helvetica 一个汉字都没有，不嵌字体时
/// 中文在阅读器里是空白。没有字体就只做西文，并让调用方去提示用户。
Future<Uint8List> buildPdf({
  required String title,
  required List<DocBlock> blocks,
  ByteData? fontData,
}) async {
  final doc = pw.Document(
    title: title.isEmpty ? null : title,
  );

  final font = fontData == null ? null : pw.Font.ttf(fontData);
  final theme = font == null
      ? null
      : pw.ThemeData.withFont(
          base: font,
          bold: font,
          italic: font,
          boldItalic: font,
        );

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(48, 48, 48, 56),
      theme: theme,
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
      ),
      build: (context) => [
        if (title.trim().isNotEmpty)
          pw.Header(
            level: 0,
            margin: const pw.EdgeInsets.only(bottom: 18),
            child: pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
        ...blocks.map(_widgetFor).nonNulls,
      ],
    ),
  );

  return doc.save();
}

pw.Widget? _widgetFor(DocBlock block) {
  switch (block) {
    case HeadingBlock(:final level, :final text):
      final size = switch (level) {
        1 => 18.0,
        2 => 15.5,
        3 => 13.5,
        _ => 12.0,
      };
      return pw.Container(
        margin: const pw.EdgeInsets.only(top: 14, bottom: 6),
        child: pw.Text(
          text,
          style: pw.TextStyle(
            fontSize: size,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      );

    case ParagraphBlock(:final text):
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Text(text, style: const pw.TextStyle(fontSize: 11, lineSpacing: 3)),
      );

    case BulletBlock(:final items):
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (final item in items)
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(width: 12, child: pw.Text('•')),
                  pw.Expanded(
                    child: pw.Text(item, style: const pw.TextStyle(fontSize: 11, lineSpacing: 2)),
                  ),
                ],
              ),
          ],
        ),
      );

    case OrderedBlock(:final items):
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++)
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(width: 18, child: pw.Text('${i + 1}.')),
                  pw.Expanded(
                    child: pw.Text(items[i], style: const pw.TextStyle(fontSize: 11, lineSpacing: 2)),
                  ),
                ],
              ),
          ],
        ),
      );

    case QuoteBlock(:final text):
      return pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 8),
        padding: const pw.EdgeInsets.only(left: 10),
        decoration: const pw.BoxDecoration(
          border: pw.Border(left: pw.BorderSide(width: 2, color: PdfColors.grey400)),
        ),
        child: pw.Text(
          text,
          style: const pw.TextStyle(fontSize: 10.5, color: PdfColors.grey700, lineSpacing: 2),
        ),
      );

    case CodeBlock(:final text):
      return pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(bottom: 10),
        padding: const pw.EdgeInsets.all(8),
        decoration: const pw.BoxDecoration(
          color: PdfColor.fromInt(0xFFF5F5F5),
          borderRadius: pw.BorderRadius.all(pw.Radius.circular(3)),
        ),
        child: pw.Text(
          text,
          style: const pw.TextStyle(fontSize: 9, lineSpacing: 1.5),
        ),
      );

    case TableBlock(:final rows):
      if (rows.isEmpty) return null;
      final columns = block.columns;
      return pw.Padding(
        padding: const pw.EdgeInsets.only(top: 4, bottom: 10),
        child: pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          children: [
            for (var r = 0; r < rows.length; r++)
              pw.TableRow(
                decoration: r == 0
                    ? const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFEFEF))
                    : null,
                children: [
                  for (var c = 0; c < columns; c++)
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                      child: pw.Text(
                        c < rows[r].length ? rows[r][c] : '',
                        style: pw.TextStyle(
                          fontSize: 9.5,
                          fontWeight: r == 0 ? pw.FontWeight.bold : pw.FontWeight.normal,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      );
  }
}
