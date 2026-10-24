import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 长边压到多少。
///
/// 1024 是清晰度和体积的折中：再大模型也看不出更多细节，再小截图里的字
/// 就糊了——而这个功能有很大一部分用途正是"发张截图问它"。
const int kMaxEdge = 1024;

/// JPEG 质量。85 是"肉眼看不出损失"的常见下限。
const int kQuality = 85;

/// 超过这个字节数就自己压一遍。
///
/// 安卓的原生 picker 会把正常照片压到 200KB 上下，所以这条线平时用不上。
/// 它拦的是**绕过原生压缩的 PNG**：`image_picker_android` 的
/// `ImageResizer.java` 里写死了 PNG 不压、原样返回全尺寸，而截图正好都是 PNG。
///
/// 为什么用字节数而不是"长边超过 1024"：最终要控制的就是传输体积，而字节数
/// 直接可测、零成本。量尺寸得先解码头，就要处理"这个格式的头在哪"的一堆分支。
/// 代价是**压缩比极高的大尺寸 PNG 会漏过去**（比如 300KB 但 3000px 宽的纯色
/// 截图），代价是那张图多花点 token，不影响正确性。这个交换划算。
const int kPassThroughBytes = 400 * 1024;

/// 「这张图我读不了」的人话。
///
/// 提成常量是因为**两个地方要用同一句**：这里抛出时用，`image_intake` 在
/// isolate 返回空结果时也用。写死两遍迟早会分叉。
const String kImageUnreadableMessage = '这张图我读不了，换一张试试。';

/// 该不该自己压一遍。
bool needsReprep(int byteLength) => byteLength > kPassThroughBytes;

/// 压不了（认不出的格式、损坏的字节）。
///
/// [message] 是**可以直接给用户看的人话**——界面会原样弹出来。
class ImagePrepException implements Exception {
  const ImagePrepException(this.message);

  final String message;

  @override
  String toString() => 'ImagePrepException: $message';
}

/// 把任意图片字节压成能进对话的 JPEG。
///
/// 纯 Dart、同步、不碰平台。跑在 isolate 里是调用方的事
/// （见 `services/image_intake.dart`），这里不知道有 isolate 这回事。
///
/// **不放大**：本来就比 [maxEdge] 小的图保持原尺寸，只是重新编成 JPEG。
/// 这条很重要——把一张 200×200 的图放大到 1024 只会让它变模糊、变大。
Uint8List downscaleForChat(
  Uint8List raw, {
  int maxEdge = kMaxEdge,
  int quality = kQuality,
}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(raw);
  } catch (_) {
    // `decodeImage` 认不出格式时返回 null，但畸形字节有时直接抛。
    // 两条路都归到同一句话上，别把库内部的东西漏给用户。
    throw const ImagePrepException(kImageUnreadableMessage);
  }
  if (decoded == null) {
    throw const ImagePrepException(kImageUnreadableMessage);
  }

  // 朝向先落到像素上，再谈摘 EXIF。
  //
  // 有的格式的解码器会替我们烘焙（JPEG 会——`getImageFromJpeg` 把 orientation
  // 转进像素、顺手抹掉那个 tag），有的不会（WebP 不会，tag 原样留在解码结果
  // 里）。只要 tag 还在，下面那句 `exif.clear()` 就等于把"该怎么转"这条信息
  // 扔了而像素没转——竖着拍的照片发出去会变成横的。所以这里统一自己来一次。
  //
  // 没这个 tag 时一点都不碰：`bakeOrientation` 无论如何都要 `Image.from` 把
  // 像素复制一遍，而这个函数每张图都要走。条件与 `copyResize` 内部那条一致
  // （`copy_resize.dart:34` 附近），所以缩放那一支不会被重复烘焙。
  if (decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1) {
    decoded = img.bakeOrientation(decoded);
  }

  final longSide =
      decoded.width > decoded.height ? decoded.width : decoded.height;

  // 只给一个方向，另一个让库按比例算。给两个的话会拉伸变形。
  final img.Image scaled;
  if (longSide <= maxEdge) {
    scaled = decoded;
  } else if (decoded.width >= decoded.height) {
    scaled = img.copyResize(decoded, width: maxEdge);
  } else {
    scaled = img.copyResize(decoded, height: maxEdge);
  }

  // 摘掉 EXIF：里面有 GPS、机型、拍摄时间，而这张图要去的是用户自己配的
  // 第三方接口、本地还要 base64 落库。朝向在上面那一步已经落到像素上了，
  // 所以摘掉不会让图转错方向。
  scaled.exif.clear();

  return img.encodeJpg(scaled, quality: quality);
}
