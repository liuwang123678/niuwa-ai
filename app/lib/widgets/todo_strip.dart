import 'package:flutter/material.dart';

import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../theme.dart';

/// 输入框上方那条任务进度。
///
/// 只在当前会话有清单时出现。默认收成一行，点开看全部步骤——跑长任务时
/// 用户最想知道的是"它还卡在哪一步"，而不是一屏清单。
class TodoStrip extends StatefulWidget {
  const TodoStrip({super.key, required this.items});

  final List<TodoItem> items;

  @override
  State<TodoStrip> createState() => _TodoStripState();
}

class _TodoStripState extends State<TodoStrip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final done = widget.items
        .where((i) => i.status == TodoStatus.completed)
        .length;
    final total = widget.items.length;
    final current = widget.items
        .where((i) => i.status == TodoStatus.inProgress)
        .firstOrNull;

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: R.mdAll,
        border: Border.all(color: c.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: R.mdAll,
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: S.x4,
                vertical: S.x3,
              ),
              child: Row(
                children: [
                  _ProgressRing(done: done, total: total, color: c),
                  const SizedBox(width: S.x3),
                  Text(
                    '$done/$total',
                    style: n1Text(
                      size: 11.5,
                      height: 1.2,
                      color: c.dim,
                      mono: true,
                    ),
                  ),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Text(
                      current?.content ??
                          (done == total ? '全部做完了' : '还没开始下一步'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: n1Text(
                        size: 12.5,
                        height: 1.3,
                        color: current == null ? c.faint : c.ink,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.expand_more,
                      size: 18,
                      color: c.faint,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _open
                ? Column(
                    children: [
                      Divider(height: 1, color: c.line),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          S.x4,
                          S.x2,
                          S.x4,
                          S.x3,
                        ),
                        child: Column(
                          children: [
                            for (final item in widget.items)
                              _Row(item: item, colors: c),
                          ],
                        ),
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item, required this.colors});

  final TodoItem item;
  final N1Colors colors;

  @override
  Widget build(BuildContext context) {
    final (icon, color, style) = switch (item.status) {
      TodoStatus.completed => (
        Icons.check_circle,
        colors.faint,
        TextDecoration.lineThrough,
      ),
      TodoStatus.inProgress => (
        Icons.play_circle_fill,
        colors.accentInk,
        TextDecoration.none,
      ),
      TodoStatus.pending => (
        Icons.radio_button_unchecked,
        colors.dim,
        TextDecoration.none,
      ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2 - 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Text(
              item.content,
              style: n1Text(
                size: 13,
                height: 1.45,
                color: item.status == TodoStatus.completed
                    ? colors.faint
                    : colors.ink,
              ).copyWith(decoration: style),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个小圆环，比数字更快读出进度。
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.done,
    required this.total,
    required this.color,
  });

  final int done;
  final int total;
  final N1Colors color;

  @override
  Widget build(BuildContext context) {
    final value = total == 0 ? 0.0 : done / total;
    return SizedBox(
      width: 16,
      height: 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: value,
            strokeWidth: 2,
            backgroundColor: color.line,
            valueColor: AlwaysStoppedAnimation(color.accentInk),
          ),
          if (done == total && total > 0)
            Icon(Icons.check, size: 9, color: color.accentInk),
        ],
      ),
    );
  }
}
