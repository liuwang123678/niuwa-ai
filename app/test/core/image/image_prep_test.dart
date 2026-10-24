import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:niuwa_ai/core/image/image_prep.dart';

/// 造一张纯色测试图。
///
/// 用 `image` 自己编码 PNG 当素材，而不是内嵌一段 base64 常量：编码和
/// "解码 + 缩放"是两条不同的代码路径，而且 16×16 的图画出来是一行代码，
/// 那个常量要占半屏。
Uint8List makePng(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(120, 180, 90));
  return Uint8List.fromList(img.encodePng(image));
}

/// 有噪声的图。**测 quality 必须用它，不能用纯色图。**
///
/// 纯色图在任何 quality 下都会被 JPEG 压到几十字节，30 和 95 出来的大小
/// 可能一模一样或者反过来——那条用例会变成偶尔红偶尔绿的假测试。
/// 噪声图的体积跟 quality 是单调的，这才测得出东西。
Uint8List makeNoisyPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  var seed = 12345;
  for (final pixel in image) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    pixel.setRgb((seed >> 16) & 0xFF, (seed >> 8) & 0xFF, seed & 0xFF);
  }
  return Uint8List.fromList(img.encodePng(image));
}

bool isJpeg(Uint8List bytes) =>
    bytes.length > 3 &&
    bytes[0] == 0xFF &&
    bytes[1] == 0xD8 &&
    bytes[2] == 0xFF;

void main() {
  test('认得出 PNG，吐出来是 JPEG', () {
    final out = downscaleForChat(makePng(16, 16));
    expect(isJpeg(out), isTrue);
  });

  test('横图长边压到 maxEdge，短边等比', () {
    final decoded = img.decodeImage(downscaleForChat(makePng(16, 8), maxEdge: 8))!;
    expect(decoded.width, 8);
    expect(decoded.height, 4);
  });

  test('竖图按高算长边', () {
    final decoded = img.decodeImage(downscaleForChat(makePng(8, 16), maxEdge: 8))!;
    expect(decoded.height, 8);
    expect(decoded.width, 4);
  });

  test('正方形不偏', () {
    final decoded = img.decodeImage(downscaleForChat(makePng(16, 16), maxEdge: 8))!;
    expect(decoded.width, 8);
    expect(decoded.height, 8);
  });

  test('本来就比 maxEdge 小的图不被放大', () {
    final decoded =
        img.decodeImage(downscaleForChat(makePng(16, 8), maxEdge: 1024))!;
    expect(decoded.width, 16);
    expect(decoded.height, 8);
  });

  test('quality 越低字节越少', () {
    final src = makeNoisyPng(64, 64);
    final low = downscaleForChat(src, quality: 30);
    final high = downscaleForChat(src, quality: 95);
    expect(low.length, lessThan(high.length));
  });

  test('坏字节抛 ImagePrepException，不是崩', () {
    expect(
      () => downscaleForChat(Uint8List.fromList([1, 2, 3, 4, 5])),
      throwsA(
        isA<ImagePrepException>().having(
          (e) => e.message,
          'message',
          kImageUnreadableMessage,
        ),
      ),
    );
  });

  test('空字节也抛同一个异常', () {
    expect(
      () => downscaleForChat(Uint8List(0)),
      throwsA(isA<ImagePrepException>()),
    );
  });

  test('认不出格式但不是畸形字节：走 null 分支，抛同一句话', () {
    // decodeImage 有两条失败路：畸形字节直接抛，认不出的格式返回 null。
    // 上面两条用例实测都走的是抛异常那条（RangeError）。这条专打 null 那条——
    // 64 个 'A' 长度够、不越界，所以不抛，但也不是任何图片格式。
    expect(
      () => downscaleForChat(Uint8List.fromList(List.filled(64, 0x41))),
      throwsA(
        isA<ImagePrepException>().having(
          (e) => e.message,
          'message',
          kImageUnreadableMessage,
        ),
      ),
    );
  });

  test('阈值卡在两侧', () {
    expect(needsReprep(kPassThroughBytes), isFalse);
    expect(needsReprep(kPassThroughBytes + 1), isTrue);
  });

  test('压缩路径把 EXIF 摘干净：GPS、机型一个都不留', () {
    // 造输入：一张 4000×100 的图（超阈值，一定走压缩路径），塞进可辨识的 tag。
    final src = img.Image(width: 4000, height: 100);
    src.exif.imageIfd['Make'] = img.IfdValueAscii('N1TestCam');
    src.exif.gpsIfd['GPSLatitudeRef'] = img.IfdValueAscii('N');
    final bytes = Uint8List.fromList(img.encodeJpg(src));

    final out = downscaleForChat(bytes);

    final decoded = img.decodeImage(out)!;
    expect(
      decoded.exif.imageIfd['Make'],
      isNull,
      reason: '压缩路径必须把 EXIF 摘干净——里面有 GPS、机型、拍摄时间',
    );
    expect(
      decoded.exif.gpsIfd['GPSLatitudeRef'],
      isNull,
      reason: 'GPS 才是真正要防的那个',
    );
  });

  test('解码器不烘焙朝向的格式（WebP）也不能把竖图发成横的', () {
    // 为什么拿 WebP 当输入：JPEG 的**解码器**会把 orientation 转进像素再抹掉
    // tag（`_jpeg_quantize_io.dart` 的 `getImageFromJpeg`），所以 JPEG 走不出
    // 这个坑；WebP 的解码器不烘焙，tag 原样留在解码结果里——要防的正是这条路。
    //
    // 800×400：长边 800 < kMaxEdge(1024)，走"不缩放、直接重编码"那一支。
    // orientation=6 = "顺时针转 90° 才是正的"：存的是横的，看的该是竖的。
    final src = img.Image(width: 800, height: 400);
    src.exif.imageIfd.orientation = 6;
    final bytes = Uint8List.fromList(img.encodeWebP(src));
    // 先钉住 fixture 自己：这个 WebP 里真的带着 tag，否则下面两条断言是空的。
    expect(
      img.decodeImage(bytes)!.exif.imageIfd.orientation,
      6,
      reason: '输入里没有 orientation，这条测试就什么都没测',
    );

    final out = downscaleForChat(bytes);

    final decoded = img.decodeImage(out)!;
    expect(
      decoded.width,
      400,
      reason: '朝向得先落到像素上：EXIF 摘掉之后没人再替我们转了',
    );
    expect(decoded.height, 800, reason: '竖图进来，还是竖图出去');
  });

  test('四个常量按规格钉死，改一个就红', () {
    // 这四个值都是规格里定死的，不是实现细节。没有这条的话，把它们"顺手调优"
    // 成 512 / 60 / 1MB 会让 flutter analyze 和 flutter test 双双放行，而实际
    // 传输体积和清晰度已经变了——全靠人肉看 diff 保。
    //
    // 最后一条尤其要钉：kImageUnreadableMessage 是直接弹给用户看的文案，本项目
    // 硬约束"用户可见文案不许出现任何模型厂商名"就落在这句话上。而别处的断言是
    // 拿这个常量去比它自己，所以那句话被改了也不会有测试红。
    expect(kMaxEdge, 1024);
    expect(kQuality, 85);
    expect(kPassThroughBytes, 400 * 1024);
    expect(kImageUnreadableMessage, '这张图我读不了，换一张试试。');
  });
}
