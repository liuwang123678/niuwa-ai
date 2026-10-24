import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image_picker/image_picker.dart';

// 内核的东西一律从桶文件拿——`image_prep.dart` 的那几个符号（
// `downscaleForChat` / `needsReprep` / `ImagePrepException` /
// `kImageUnreadableMessage`）桶里都有。再单开一行 import 子文件，
// `unnecessary_import` 会直接报出来。
import '../core/n1_core.dart';

/// 压缩函数。
///
/// 生产用 isolate 版（默认值），测试注入假货——测试里起真 isolate 又慢
/// 又让我们分不清"透传判定错了"和"压缩本身有问题"。
///
/// 只有一个位置参数：Dart 的函数类型不允许给具名参数写默认值，而
/// `maxEdge`/`quality` 是调用方的固定选择（`kMaxEdge`/`kQuality`），
/// 没有让外面调的余地。少两个参数就少两处能写错的地方。
typedef DownscaleFn = Future<Uint8List> Function(Uint8List raw);

/// 准备一张图失败。[message] 是可以直接给用户看的人话。
class ImageIntakeException implements Exception {
  const ImageIntakeException(this.message);

  final String message;

  @override
  String toString() => 'ImageIntakeException: $message';
}

/// 把选中的文件做出一份能进对话的图。
///
/// 这是"选图"和"内核"之间唯一的缝：下面读到的是平台的文件，上面交出去的是
/// 纯数据。isolate 和错误翻译都只发生在这里。
class ImageIntake {
  ImageIntake({DownscaleFn? downscale}) : _downscale = downscale ?? _inIsolate;

  final DownscaleFn _downscale;

  Future<ImagePart> prepare(XFile file) async {
    final Uint8List raw;
    try {
      raw = await file.readAsBytes();
    } catch (_) {
      throw const ImageIntakeException('读不到这张图，换一张试试。');
    }
    if (raw.isEmpty) {
      throw const ImageIntakeException('这张图是空的，换一张试试。');
    }

    final mime = _mimeOf(file);

    // 两种情况下自己压：太大，或者类型认不出。
    //
    // 认不出类型就透传等于赌——给一个猜的 mime 骗上游，错了之后错在服务端，
    // 本地什么异常都看不到。压一遍出来一定是 JPEG，类型是确定的。
    if (mime != null && !needsReprep(raw.length)) {
      return ImagePart(base64Data: base64Encode(raw), mimeType: mime);
    }

    final Uint8List jpeg;
    try {
      jpeg = await _downscale(raw);
    } on ImagePrepException catch (e) {
      throw ImageIntakeException(e.message);
    } catch (_) {
      throw const ImageIntakeException('这张图我处理不了，换一张试试。');
    }

    return ImagePart(base64Data: base64Encode(jpeg), mimeType: 'image/jpeg');
  }
}

/// 允许原样透传的四种格式。
///
/// 这是几家主流的看图接口都吃的四种。不在名单里的一律走压缩——**多认一种
/// 就多一种"传上去让对方拒"的机会**（BMP、TIFF 就是这样被排除的，
/// 它们在 `package:image` 里都解得开，压成 JPEG 就稳了）。
const Set<String> _passThroughMimes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
};

/// 认得出就返回权威的 mime，认不出返回 null。
///
/// 顺序：`XFile.mimeType`（Windows 的文件选择器会给，安卓那边通常是 null）
/// → 文件扩展名 → 认不出。
///
/// 自报的那个也要过白名单：安卓上 `image/heic` 之类是能报出来的，
/// 而那种字节我们宁愿自己压（压不动会抛人话，比传上去被拒好）。
String? _mimeOf(XFile file) {
  // 自报的值不可信，先归一化：`IMAGE/JPEG`、`image/jpg ` 都不能从白名单漏出去。
  final declared = file.mimeType?.trim().toLowerCase();
  if (declared != null && _passThroughMimes.contains(declared)) {
    return declared;
  }

  final name = file.name.toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.jpe')) {
    return 'image/jpeg';
  }
  if (name.endsWith('.gif')) return 'image/gif';
  if (name.endsWith('.webp')) return 'image/webp';
  return null;
}

/// 在 isolate 里跑，别堵主线程。
///
/// `package:image` 的解码 + 缩放 + 编码是逐像素的 Dart 代码，一张 5MB 的图在
/// 桌面上能跑到秒级。放主线程上就是几秒钟的界面冻结，用户会以为 App 卡死了。
Future<Uint8List> _inIsolate(Uint8List raw) async {
  final out = await compute(_prepareEntry, raw);
  if (out == null) {
    // 跨 isolate 抛异常时，错误对象能不能原样过来取决于它是否可序列化。
    // 这条不确定性不值得承担——把失败也当成一种**返回值**传回来，稳。
    throw const ImagePrepException(kImageUnreadableMessage);
  }
  return out;
}

/// isolate 的入口。**不抛**：认不出就返回 null。
Uint8List? _prepareEntry(Uint8List raw) {
  try {
    return downscaleForChat(raw);
  } catch (_) {
    return null;
  }
}
