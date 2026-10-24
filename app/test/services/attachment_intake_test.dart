import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/services/attachment_intake.dart';

/// 读附件的规矩只有一条：**读不准就说读不准，别猜**。
///
/// 猜错的后果不是报错，而是把乱码当成原文喂给模型，然后它非常自信地
/// 总结出一个错误结论。下面几条把"会猜"的实现全堵死。
void main() {
  late Directory dir;
  var seq = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('n1_attach_');
  });

  tearDown(() => dir.delete(recursive: true));

  /// 每次写到**自己的子目录**里，文件名就是用户会看到的那个。
  ///
  /// 不能在文件名前面加序号来防重名：IO 平台上的 `XFile.name` 是从路径切出来的
  /// （`name:` 参数在那边是被忽略的），前缀会跟着进水。
  XFile write(String name, List<int> bytes) {
    final sub = Directory('${dir.path}/${seq++}')..createSync();
    final f = File('${sub.path}/$name')..writeAsBytesSync(bytes);
    return XFile(f.path, name: name);
  }

  group('正常文本', () {
    test('UTF-8 读进来原样，带文件名和字节数', () async {
      final a = await const AttachmentIntake().prepare(
        write('app.log', utf8.encode('第一行\n第二行')),
      );

      expect(a.name, 'app.log');
      expect(a.text, '第一行\n第二行');
      expect(a.truncated, isFalse);
      // 字节数按 UTF-8 算：每个汉字 3 字节。
      expect(a.sizeBytes, greaterThan(0));
    });

    test('BOM 去掉，不要偷偷变成文件开头的怪字符', () async {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('hello')];
      final a = await const AttachmentIntake().prepare(write('bom.txt', bytes));
      expect(a.text, 'hello');
    });

    test('UTF-16LE（Windows 记事本的“Unicode”）能解', () async {
      final bytes = <int>[0xFF, 0xFE];
      for (final unit in '中文abc'.codeUnits) {
        bytes
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      final a = await const AttachmentIntake().prepare(
        write('unicode.txt', bytes),
      );
      expect(a.text, '中文abc');
    });

    test('CRLF 原样保留（不擅自改行尾）', () async {
      final a = await const AttachmentIntake().prepare(
        write('crlf.txt', utf8.encode('a\r\nb')),
      );
      expect(a.text, 'a\r\nb');
    });
  });

  group('拒绝读不了的东西', () {
    test('二进制带 NUL → 明说是二进制，不塞乱码', () async {
      final bytes = <int>[0x25, 0x50, 0x44, 0x46, 0x00, 0x01, 0x02];
      await expectLater(
        const AttachmentIntake().prepare(write('a.pdf', bytes)),
        throwsA(
          isA<AttachmentIntakeException>().having(
            (e) => e.message,
            'message',
            allOf(contains('二进制'), contains('a.pdf')),
          ),
        ),
      );
    });

    test('GBK 编码的老文件 → 说清是编码问题，不许猜着解', () async {
      // "中文" 的 GBK 字节，按 UTF-8 解不合法。
      final bytes = <int>[0xD6, 0xD0, 0xCE, 0xC4];
      await expectLater(
        const AttachmentIntake().prepare(write('gbk.txt', bytes)),
        throwsA(
          isA<AttachmentIntakeException>().having(
            (e) => e.message,
            'message',
            allOf(contains('UTF-8'), contains('另存为')),
          ),
        ),
      );
    });

    test('空文件 → 直接说明', () async {
      await expectLater(
        const AttachmentIntake().prepare(write('empty.txt', [])),
        throwsA(
          isA<AttachmentIntakeException>().having(
            (e) => e.message,
            'message',
            contains('空文件'),
          ),
        ),
      );
    });

    test('控制字符占比过高的"合法 UTF-8"也判二进制', () async {
      // 0x01 是合法 UTF-8，但不是文本。全篇都是它的时候必须拦。
      final bytes = List<int>.filled(200, 0x01);
      await expectLater(
        const AttachmentIntake().prepare(write('weird.bin', bytes)),
        throwsA(isA<AttachmentIntakeException>()),
      );
    });
  });

  group('截断', () {
    test('超过字数上限就截断，并标记出来', () async {
      final a = await const AttachmentIntake(
        maxChars: 10,
      ).prepare(write('long.txt', utf8.encode('0123456789abcdef')));

      expect(a.text, '0123456789');
      expect(a.truncated, isTrue, reason: '不标出来的话模型会拿半截下结论');
      // 字节数还是原始大小，界面上显示的是文件，不是喂进去的那一段。
      expect(a.sizeBytes, greaterThan(a.text.length));
    });

    test('超过字节上限就不会把整个文件读进来', () async {
      final a = await const AttachmentIntake(
        maxBytes: 8,
        maxChars: 1000,
      ).prepare(write('big.txt', utf8.encode('abcdefghijklmnop')));

      expect(a.text, 'abcdefgh');
      expect(a.truncated, isTrue);
      expect(a.sizeBytes, 16);
    });

    test('截断点不会切出半个字符（emoji 不变成问号）', () async {
      // "😀" 在 Dart 里占两个 UTF-16 code unit。按长度硬切就会劈成两半。
      final a = await const AttachmentIntake(
        maxChars: 3,
      ).prepare(write('emoji.txt', utf8.encode('a😀b')));

      expect(a.text, 'a😀');
      // 切点必须落在字符边界上：解回来不该出现 U+FFFD。
      expect(a.text.contains('�'), isFalse);
    });
  });

  test('文件不在也能给出人话，而不是抛原始异常', () async {
    final missing = XFile('${dir.path}/does-not-exist.txt', name: 'gone.txt');
    await expectLater(
      const AttachmentIntake().prepare(missing),
      throwsA(isA<AttachmentIntakeException>()),
    );
  });

  test('没有名字时给一个占位名，不让界面出现空白标签', () async {
    final f = File('${dir.path}/nameless')..writeAsStringSync('x');
    final a = await const AttachmentIntake().prepare(XFile(f.path));
    expect(a.name, isNotEmpty);
  });

  test('名字里不残留目录，两种分隔符都切干净', () async {
    // `XFile.name` 在 IO 上是按 `Platform.pathSeparator` 切的，Windows 上
    // 路径里混进一个 `/` 就切不动。附件名会显示在气泡上、也会进提示词，
    // 带路径既不好看也漏隐私，所以实现里自己又切了一遍。
    final f = File('${dir.path}/deep/notes.txt');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('x');
    final a = await const AttachmentIntake().prepare(XFile(f.path));
    expect(a.name, 'notes.txt');
  });

  test('读的是 Uint8List——别把 List<int> 当成二进制再解一遍', () async {
    // 这条看着像废话，守的是 `_readCapped` 的返回类型：它要是退化成
    // `List<int>` 之外的某个包装，下面这个长度断言会先炸。
    final a = await const AttachmentIntake().prepare(
      write('x.txt', utf8.encode('abc')),
    );
    expect(Uint8List.fromList(utf8.encode(a.text)).length, 3);
  });
}
