import 'package:flutter/material.dart';

import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../theme.dart';

/// 一个附件的标签：图标 + 文件名 + 大小。
///
/// 输入条里的待发文件和已发出的消息气泡共用这个——两处长得不一样的话，
/// 用户会怀疑"发出去的那份是不是变了"。
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({
    super.key,
    required this.attachment,
    this.onRemove,
    this.onWash = false,
  });

  final Attachment attachment;

  /// 点右边的叉去掉。为 null 就不显示叉（已发出的消息不给改）。
  final VoidCallback? onRemove;

  /// 放在用户气泡（浅色主色底）上时打开。那里再用 `line` 当底色会糊成一片。
  final bool onWash;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final meta = _meta();

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(S.x3, 6, 6, 6),
      decoration: BoxDecoration(
        color: onWash ? c.raised : c.line,
        borderRadius: BorderRadius.circular(R.md),
        border: onWash ? Border.all(color: c.lineStrong, width: 0.8) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_outlined, size: 15, color: c.accentInk),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: n1Text(size: 12.5, color: c.ink),
                ),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    maxLines: 1,
                    style: n1Text(size: 10.5, color: c.faint),
                  ),
              ],
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            Semantics(
              button: true,
              label: '去掉 ${attachment.name}',
              child: GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded, size: 14, color: c.faint),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "12 KB · 已截断"。大小是原始文件大小，不是喂进去的那段字数——
  /// 用户认的是文件，不是 token。
  String _meta() {
    final parts = <String>[];
    if (attachment.sizeBytes > 0) parts.add(prettyBytes(attachment.sizeBytes));
    if (attachment.truncated) parts.add('只看了一部分');
    return parts.join(' · ');
  }
}

/// 1024 → "1 KB"。超过 1MB 就不给小数了，那个位数没人关心。
String prettyBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return '${kb < 10 ? kb.toStringAsFixed(1) : kb.round()} KB';
  }
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}
