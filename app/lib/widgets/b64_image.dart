import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../theme.dart';

/// 画一张 base64 的图，**解码只做一次**。
///
/// 为什么不直接在 `build` 里写 `Image.memory(base64Decode(...))`：
/// 流式回复的每个文字 delta 都会让整个列表重建，那样写就是每帧解一次 base64；
/// 更要命的是每帧产生一个**新的 `Uint8List`**，而 Flutter 的 `ImageCache`
/// 拿字节数组的相等性当 key —— 新旧不相等，于是判定为新图，
/// **每帧重新解码一遍图片**。
///
/// 所以这不是优化，是不这么做就是错的。
class B64Image extends StatefulWidget {
  const B64Image({
    super.key,
    required this.base64Data,
    this.fit = BoxFit.contain,
  });

  final String base64Data;
  final BoxFit fit;

  @override
  State<B64Image> createState() => _B64ImageState();
}

class _B64ImageState extends State<B64Image> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(B64Image oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在这一串真的换了的时候才重解。这里不用 setState：
    // didUpdateWidget 之后本来就会 build。
    if (oldWidget.base64Data != widget.base64Data) _decode();
  }

  void _decode() {
    try {
      _bytes = base64Decode(widget.base64Data);
    } on FormatException {
      // 坏数据不该让整条消息渲染不出来，画个占位就行。
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const _BrokenImage();

    return Image.memory(
      bytes,
      fit: widget.fit,
      // 换图时不要闪一下白。
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const _BrokenImage(),
    );
  }
}

/// 数据坏了、或者解不开。**不许抛** —— 一张坏图不该让整条消息消失。
class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    return Container(
      width: 140,
      height: 100,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.line,
        borderRadius: BorderRadius.circular(R.md),
      ),
      child: Icon(
        Icons.broken_image_outlined,
        size: 22,
        color: c.faint,
      ),
    );
  }
}
