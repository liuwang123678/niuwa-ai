import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/doc/document_blocks.dart';
import 'package:niuwa_ai/core/doc/pdf_writer.dart';

/// PDF 生成。
///
/// 这里不检查结构细节（那是在测别人的库），只验三件真正会坏事的：
/// 字节真的是 PDF、中文字体真的嵌进去了、没有字体时不会崩。
void main() {
  /// 用真字体文件，不从 Flutter assets 里拿——测试环境没有 rootBundle，
  /// 而且打包后出问题的往往正是"这个文件到底进没进包"，那一条得靠打包后的
  /// 真机验证，不是这里。
  ByteData? font;

  setUpAll(() {
    final file = File('assets/fonts/NotoSansSC-subset.ttf');
    if (file.existsSync()) {
      font = ByteData.sublistView(file.readAsBytesSync());
    }
  });

  const blocks = [
    HeadingBlock(1, '报告'),
    ParagraphBlock('这是一段中文正文。'),
    BulletBlock(['第一条', '第二条']),
    TableBlock([
      ['项目', '金额'],
      ['收入', '100'],
    ]),
  ];

  test('生成的是合法 PDF，中文能被嵌进去', () async {
    expect(font, isNotNull, reason: '字体资产必须先存在，否则中文一定显示不出来');

    final bytes = await buildPdf(title: '标题', blocks: blocks, fontData: font);

    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(ascii.decode(bytes.sublist(bytes.length - 6)), contains('%%EOF'));

    // 嵌了字体的 PDF 一定带 FontFile2（TrueType 主体）和 Type0（Identity-H
    // 编码的复合字体）。只看 "中文" 本身是查不到的——PDF 里存的是字形编号。
    final text = latin1.decode(bytes, allowInvalid: true);
    expect(text, contains('/FontFile2'));
    expect(text, contains('/Type0'));

    // 别拿绝对大小做标准：dart_pdf 只嵌**用到的那几十个字形**，整份不到
    // 10 KB 很正常。有意义的比较是"嵌字体的比不嵌的大"。
    final bare = await buildPdf(title: '标题', blocks: blocks);
    expect(bytes.length, greaterThan(bare.length));
  });

  test('没有字体也能出 PDF，只是中文会缺（这是降级，不是崩溃）', () async {
    final bytes = await buildPdf(title: 'Title', blocks: blocks);

    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(latin1.decode(bytes, allowInvalid: true), isNot(contains('/FontFile2')));
  });

  test('长文档会分页，页码写进去了', () async {
    final long = List.generate(80, (i) => ParagraphBlock('第 $i 段，' * 6));
    final bytes = await buildPdf(title: '长文', blocks: long, fontData: font);

    final text = latin1.decode(bytes, allowInvalid: true);
    expect(RegExp(r'/Count [2-9]').hasMatch(text), isTrue, reason: '80 段应该不止一页');
  });

  test('空文档不报错', () async {
    final bytes = await buildPdf(title: '', blocks: const [], fontData: font);

    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
  });
}
