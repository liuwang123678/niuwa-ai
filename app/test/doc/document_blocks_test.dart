import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/doc/document_blocks.dart';

void main() {
  group('parseDocumentBlocks', () {
    test('标题按级别切，行内标记去掉', () {
      final blocks = parseDocumentBlocks('# 一级\n\n### 三级 **粗**\n');

      expect(blocks, hasLength(2));
      expect(blocks[0], isA<HeadingBlock>());
      expect((blocks[0] as HeadingBlock).level, 1);
      expect((blocks[0] as HeadingBlock).text, '一级');
      expect((blocks[1] as HeadingBlock).level, 3);
      expect((blocks[1] as HeadingBlock).text, '三级 粗');
    });

    test('连续多行合并成一个段落', () {
      final blocks = parseDocumentBlocks('第一行\n第二行\n\n另一个段落');

      expect(blocks, hasLength(2));
      expect((blocks[0] as ParagraphBlock).text, '第一行 第二行');
      expect((blocks[1] as ParagraphBlock).text, '另一个段落');
    });

    test('无序列表和有序列表分开成块', () {
      final blocks = parseDocumentBlocks('- 甲\n* 乙\n+ 丙\n\n1. 一\n2) 二\n');

      expect(blocks, hasLength(2));
      expect((blocks[0] as BulletBlock).items, ['甲', '乙', '丙']);
      expect((blocks[1] as OrderedBlock).items, ['一', '二']);
    });

    test('引用块整段收进来，去掉了 >', () {
      final blocks = parseDocumentBlocks('> 第一句\n> 第二句');

      expect(blocks, hasLength(1));
      expect((blocks[0] as QuoteBlock).text, '第一句\n第二句');
    });

    test('代码块原样保留，里面的 # 不当标题', () {
      final blocks = parseDocumentBlocks('```dart\n# 这是注释\nvar a = 1;\n```');

      expect(blocks, hasLength(1));
      expect((blocks[0] as CodeBlock).text, '# 这是注释\nvar a = 1;');
    });

    test('没有收尾的代码块不会吞掉后面的内容', () {
      final blocks = parseDocumentBlocks('```\n没收尾');

      expect(blocks, hasLength(1));
      expect((blocks[0] as CodeBlock).text, '没收尾');
    });

    test('表格认出表头与数据行，并去掉首尾的竖线', () {
      final blocks = parseDocumentBlocks(
        '| 名字 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n| 梨 | 5 |',
      );

      expect(blocks, hasLength(1));
      final table = blocks[0] as TableBlock;
      expect(table.rows, [
        ['名字', '数量'],
        ['苹果', '3'],
        ['梨', '5'],
      ]);
      expect(table.columns, 2);
    });

    test('单元格里的重点是去掉的，不是原样留着', () {
      final blocks = parseDocumentBlocks('| **a** | `b` |\n| --- | --- |');

      final table = blocks[0] as TableBlock;
      expect(table.rows.first, ['a', 'b']);
    });

    test('链接保留文字丢掉地址', () {
      final blocks = parseDocumentBlocks('看 [这里](https://example.com) 和 ![图](x.png)');

      expect((blocks[0] as ParagraphBlock).text, '看 这里 和 图');
    });

    test('空输入得到空表', () {
      expect(parseDocumentBlocks(''), isEmpty);
      expect(parseDocumentBlocks('\n\n  \n'), isEmpty);
    });

    test('CRLF 换行跟 LF 一样处理', () {
      final blocks = parseDocumentBlocks('# 标题\r\n\r\n正文');

      expect(blocks, hasLength(2));
      expect((blocks[1] as ParagraphBlock).text, '正文');
    });
  });
}
