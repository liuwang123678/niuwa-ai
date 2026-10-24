import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../theme.dart';

/// 模型的思考过程。默认折叠。
///
/// 折叠是刻意的：思考过程动辄几百字，展开铺在正文前面会把真正要说的话推到
/// 屏幕外面。但它又不能藏起来——用户看得见"它在想"，会觉得慢是可以理解的。
/// 所以留一行摘要，想看再点开。
class ReasoningBlock extends StatefulWidget {
  const ReasoningBlock({
    super.key,
    required this.text,
    required this.streaming,
  });

  final String text;

  /// 还在生成。决定摘要那行写"思考中"还是"思考过程"。
  final bool streaming;

  @override
  State<ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<ReasoningBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    if (widget.text.trim().isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(c),
          // 用 AnimatedSize 而不是 AnimatedCrossFade：后者要把两个子树都建出来，
          // 而思考过程可以很长，折叠状态下白建一整段文本是浪费。
          AnimatedSize(
            duration: M.base,
            curve: M.out,
            alignment: Alignment.topLeft,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(top: S.x3, left: S.x4),
                    child: Container(
                      padding: const EdgeInsets.only(left: S.x4),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: c.line, width: 2),
                        ),
                      ),
                      child: Text(
                        widget.text.trim(),
                        style: n1Text(size: 13.5, height: 1.72, color: c.trace),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _header(N1Colors c) {
    final thinking = widget.streaming;
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      borderRadius: BorderRadius.circular(R.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x2, horizontal: S.x1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (thinking)
              SizedBox.square(
                dimension: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: c.trace,
                ),
              )
            else
              Icon(Icons.psychology_outlined, size: 14, color: c.trace),
            const SizedBox(width: S.x3),
            Text(
              thinking ? '思考中…' : '思考过程',
              style: n1Text(size: 12.5, height: 1.2, color: c.trace),
            ),
            const SizedBox(width: S.x1),
            AnimatedRotation(
              turns: _open ? 0.25 : 0,
              duration: M.base,
              curve: M.out,
              child: Icon(Icons.chevron_right, size: 15, color: c.trace),
            ),
          ],
        ),
      ),
    );
  }
}
