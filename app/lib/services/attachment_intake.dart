import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../core/n1_core.dart';

/// 读附件失败。[message] 是可以直接给用户看的人话。
class AttachmentIntakeException implements Exception {
  const AttachmentIntakeException(this.message);

  final String message;

  @override
  String toString() => 'AttachmentIntakeException: $message';
}

/// 把用户选中的文件读成一段能进对话的文本。
///
/// 只做文本。PDF / Word / 压缩包这些二进制格式需要各自的解析器，现在没有；
/// 与其把一堆乱码塞给模型（它会拿乱码认真分析，然后编出一个结论），
/// 不如当场说清楚"这个格式不行"。
class AttachmentIntake {
  const AttachmentIntake({
    this.maxBytes = 512 * 1024,
    this.maxChars = 40000,
  });

  /// 最多读这么多字节。再大的文件读进来也只是截断，不如早停。
  final int maxBytes;

  /// 最多给模型这么多字。四万字大约是 2.4 万 token，已经够一个很长的日志了。
  final int maxChars;

  Future<Attachment> prepare(XFile file) async {
    final name = _fileName(file);

    final int size;
    try {
      size = await file.length();
    } catch (_) {
      throw const AttachmentIntakeException('读不到这个文件的信息，换一个试试。');
    }

    final Uint8List raw;
    try {
      raw = await _readCapped(file);
    } catch (_) {
      throw const AttachmentIntakeException('读不到这个文件，换一个试试。');
    }
    if (raw.isEmpty) {
      throw AttachmentIntakeException('「$name」是空文件。');
    }

    final text = _decodeText(raw, name);
    final clipped = text.length > maxChars
        ? clipAtCodeUnit(text, maxChars)
        : text;

    return Attachment(
      name: name,
      text: clipped,
      sizeBytes: size,
      truncated: raw.length >= maxBytes || clipped.length < text.length,
    );
  }

  /// 只留文件名。
  ///
  /// 为什么不直接用 `file.name`：IO 平台上的实现是按 `Platform.pathSeparator`
  /// 切的（`cross_file/lib/src/types/io.dart:103`），Windows 上只要路径里混进
  /// 一个 `/`，切不动，把中间几级目录整段带出来。附件名要显示在气泡上、
  /// 还要进喂给模型的提示词，带路径既乱也漏隐私，所以两种分隔符都自己切一遍。
  String _fileName(XFile file) {
    var name = file.name.trim();
    final slash = name.lastIndexOf('/');
    final backslash = name.lastIndexOf(r'\');
    final cut = slash > backslash ? slash : backslash;
    if (cut >= 0) name = name.substring(cut + 1).trim();
    return name.isEmpty ? '（未命名文件）' : name;
  }

  /// 一块一块读，凑够上限就停——`readAsBytes()` 会把一个 200MB 的视频
  /// 整个读进内存，正好是这里要避免的。
  Future<Uint8List> _readCapped(XFile file) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      out.add(chunk);
      if (out.length >= maxBytes) break;
    }
    final bytes = out.takeBytes();
    return bytes.length > maxBytes
        ? Uint8List.sublistView(bytes, 0, maxBytes)
        : bytes;
  }

  /// 字节 → 文本。认不出就抛人话，**不猜编码**。
  ///
  /// 猜错的后果比失败严重：GBK 页面按 UTF-8 解出来是满屏 U+FFFD，模型会
  /// 把它当成文件原文去总结，然后非常自信地告诉你一个错误结论。
  String _decodeText(Uint8List raw, String name) {
    // UTF-16 带 BOM 的（Windows 记事本的「Unicode」）。这个能确定地解，
    // 不算猜——先处理掉，免得被下面的二进制判定误杀。
    if (raw.length >= 2) {
      final le = raw[0] == 0xFF && raw[1] == 0xFE;
      final be = raw[0] == 0xFE && raw[1] == 0xFF;
      if (le || be) {
        final units = <int>[];
        for (var i = 2; i + 1 < raw.length; i += 2) {
          units.add(le ? raw[i] | (raw[i + 1] << 8) : (raw[i] << 8) | raw[i + 1]);
        }
        return String.fromCharCodes(units);
      }
    }

    // 先看有没有 NUL：文本文件（哪怕是中文）不会在正常位置出现 0 字节，
    // 而所有主流二进制格式的开头都有。这一步比"试着 decode 一下"可靠。
    final head = raw.length > 4096 ? raw.sublist(0, 4096) : raw;
    if (head.contains(0)) throw _binary(name);

    var body = raw;
    if (body.length >= 3 &&
        body[0] == 0xEF &&
        body[1] == 0xBB &&
        body[2] == 0xBF) {
      body = Uint8List.sublistView(body, 3);
    }

    final String text;
    try {
      text = utf8.decode(body);
    } on FormatException {
      throw const AttachmentIntakeException(
        '这个文件不是 UTF-8 文本（可能是 GBK 编码的老文件，或者干脆是二进制）。'
        '用记事本另存为 UTF-8 再试一次。',
      );
    }

    // 解出来了，但控制字符多到不像文本（有些二进制恰好是合法 UTF-8）。
    var control = 0;
    for (final rune in text.runes) {
      if (rune < 0x20 && rune != 0x0A && rune != 0x0D && rune != 0x09) {
        control++;
      }
    }
    if (text.isNotEmpty && control / text.length > 0.02) throw _binary(name);

    return text;
  }

  AttachmentIntakeException _binary(String name) =>
      AttachmentIntakeException(
        '「$name」看起来是二进制文件（PDF、Word、压缩包这类），'
        '我目前只能读文本文件。',
      );
}
