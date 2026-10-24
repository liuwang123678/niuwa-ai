import 'package:flutter/material.dart';

import 'b64_image.dart';

/// 全屏看大图。点任意处关闭。
///
/// 刻意不做成一条路由：这是一个"看一眼就回去"的动作，路由会留下回退栈，
/// 桌面端还会多一层转场动画。`showDialog` 更贴合它的分量。
Future<void> showImagePreview(BuildContext context, String base64Data) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => GestureDetector(
        onTap: () => Navigator.of(dialogContext).pop(),
        child: InteractiveViewer(
          // 捏合放大。缩略图看不清细节时，这是唯一的补救。
          maxScale: 6,
          child: Center(
            child: B64Image(base64Data: base64Data, fit: BoxFit.contain),
          ),
        ),
      ),
    );
