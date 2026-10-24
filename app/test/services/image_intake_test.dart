import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/image_intake.dart';

/// 假的压缩函数：原样返回一个可辨认的字节串，并记下被调了几次。
///
/// 测试里绝不注入真的 `downscaleForChat`：那会起一个真 isolate（`compute`），
/// 慢、而且让我们分不清"透传判定错了"和"压缩本身有问题"。
class FakeDownscale {
  int calls = 0;
  Uint8List result = Uint8List.fromList(const [9, 9, 9]);

  Future<Uint8List> call(Uint8List raw) async {
    calls++;
    return result;
  }
}

// ⚠️ 这里必须用 `path:`，**不能用 `name:`**。
//
// `flutter test` 跑在 VM 上，用的是 `cross_file` 的 io 实现，而它的
// `XFile.fromData` **静默忽略 `name:`**——包里那行注释写得很直白：
// `name is ignored; the parameter exists only to match the web version`
// （`cross_file-0.3.5+5/lib/src/types/io.dart:46`）。io 版的 `name` getter 是
// 从 `_file.path` 取最后一段推出来的，所以 `name: 'a.jpg'` 只会得到空字符串。
//
// 后果不是"少认一个扩展名"那么轻：`_mimeOf` 拿不到扩展名就一律走压缩，
// 于是"小文件原样透传"和"扩展名 .png 也认得出"这两条会永久变红，
// 而那根本不是被测代码的问题——字节里压根没有能判出格式的信息。
// `path:` 在 io 和 web 两边都认，且 `readAsBytes()` 会优先用内存里的 bytes。
XFile smallFile(String name, {String? mime}) => XFile.fromData(
  Uint8List.fromList(const [1, 2, 3, 4]),
  path: name,
  mimeType: mime,
);

XFile bigFile(String name, {String? mime}) => XFile.fromData(
  Uint8List(kPassThroughBytes + 1),
  path: name,
  mimeType: mime,
);

void main() {
  test('小文件原样透传，不去压缩', () async {
    final fake = FakeDownscale();
    final intake = ImageIntake(downscale: fake.call);

    final part = await intake.prepare(smallFile('a.jpg'));

    expect(fake.calls, 0, reason: '没超阈值就不该压');
    // ⚠️ 这一条才是"mimeType 没写死"的证据。`ImagePart` 的默认值是
    // `image/png`，所以这里**必须用一个 jpg**——要是断言 png，那跟"什么都没做、
    // 让默认值生效"完全没法区分，是个空绿的测试。
    expect(part.mimeType, 'image/jpeg');
    expect(
      base64Decode(part.base64Data),
      [1, 2, 3, 4],
      reason: '透传必须一个字节都不改',
    );
  });

  test('扩展名 .png 也认得出', () async {
    final intake = ImageIntake(downscale: FakeDownscale().call);
    final part = await intake.prepare(smallFile('shot.png'));
    expect(part.mimeType, 'image/png');
    expect(base64Decode(part.base64Data), [1, 2, 3, 4]);
  });

  test('没有扩展名时用 XFile 自报的 mimeType', () async {
    final intake = ImageIntake(downscale: FakeDownscale().call);
    final part = await intake.prepare(
      smallFile('blob', mime: 'image/webp'),
    );
    expect(part.mimeType, 'image/webp');
  });

  test('大文件走压缩，输出是 JPEG', () async {
    final fake = FakeDownscale();
    final intake = ImageIntake(downscale: fake.call);

    final part = await intake.prepare(bigFile('big.png'));

    expect(fake.calls, 1);
    expect(part.mimeType, 'image/jpeg');
    expect(base64Decode(part.base64Data), fake.result);
  });

  test('认不出的类型即使很小也走压缩', () async {
    // HEIC 之类：与其瞎猜一个 mime 骗上游，不如压成确定的 JPEG。
    // 压不动的话会抛下面的可读错误——那条路才是 HEIC 的归宿。
    final fake = FakeDownscale();
    final intake = ImageIntake(downscale: fake.call);

    final part = await intake.prepare(smallFile('IMG_0001.HEIC'));

    expect(fake.calls, 1, reason: '认不出类型就该压，透传等于赌');
    expect(part.mimeType, 'image/jpeg');
  });

  test('压不动时给一句人话，不是把库的异常漏出去', () async {
    final intake = ImageIntake(
      downscale: (raw) async {
        throw const ImagePrepException(kImageUnreadableMessage);
      },
    );

    expect(
      () => intake.prepare(bigFile('a.png')),
      throwsA(
        isA<ImageIntakeException>().having(
          (e) => e.message,
          'message',
          kImageUnreadableMessage,
        ),
      ),
    );
  });

  test('压缩抛出意料之外的异常也要兜成人话', () async {
    final intake = ImageIntake(
      downscale: (raw) async {
        throw StateError('isolate 炸了');
      },
    );

    expect(
      () => intake.prepare(bigFile('a.png')),
      throwsA(isA<ImageIntakeException>()),
    );
  });

  test('读不到文件给人话', () async {
    final intake = ImageIntake(downscale: FakeDownscale().call);
    // 这个路径在桌面上读会真的抛 FileSystemException。
    expect(
      () => intake.prepare(XFile('/definitely/not/here.jpg')),
      throwsA(isA<ImageIntakeException>()),
    );
  });

  test('空文件给人话', () async {
    final intake = ImageIntake(downscale: FakeDownscale().call);
    final empty = XFile.fromData(Uint8List(0), path: 'a.jpg');
    expect(
      () => intake.prepare(empty),
      throwsA(isA<ImageIntakeException>()),
    );
  });
}
