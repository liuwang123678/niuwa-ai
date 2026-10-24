import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../models/chat_item.dart';
import '../platform.dart';
import '../theme.dart';
import 'attachment_chip.dart';
import 'b64_image.dart';
import 'image_preview.dart';
import 'markdown.dart';
import 'reasoning_block.dart';
import 'tool_trace_tile.dart';

/// 一条消息。用户的话是气泡，N1 的话是散在页面上的正文。
///
/// 为什么 N1 的不给气泡：气泡是"我说一句、你回一句"的对话隐喻，适合一问一答。
/// 但 N1 会连续吐很长一段、中间穿插工具调用和思考过程，塞进一个圆角框里
/// 会变成一坨。让它像文章一样铺在纸上，读起来舒服得多。
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.item,
    this.onLinkTap,
    this.maxWidth = 760,
  });

  final ChatItem item;
  final void Function(String url)? onLinkTap;

  /// 正文最大宽度。桌面端窗口可以很宽，但一行超过 80 来个字就没法读了。
  final double maxWidth;

  @override
  Widget build(BuildContext context) => switch (item) {
    UserItem(:final text, :final images, :final attachments) => _UserBubble(
      text: text,
      images: images,
      attachments: attachments,
      maxWidth: maxWidth,
    ),
    AssistantItem() => _AssistantBlock(
      item: item as AssistantItem,
      onLinkTap: onLinkTap,
      maxWidth: maxWidth,
    ),
  };
}

// ══════════════════════════════════════════════════════════════════
// 用户
// ══════════════════════════════════════════════════════════════════

class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.text,
    required this.images,
    required this.attachments,
    required this.maxWidth,
  });

  final String text;
  final List<ImagePart> images;
  final List<Attachment> attachments;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth * 0.78),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: S.x5,
            vertical: S.x4,
          ),
          decoration: BoxDecoration(
            color: c.accentWash,
            // 右下角收窄，做出一个"从右边说出来"的方向感。
            // 四个角一样圆的话气泡会显得飘，没有归属。
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(R.bubble),
              topRight: Radius.circular(R.bubble),
              bottomLeft: Radius.circular(R.bubble),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < images.length; i++) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(R.md),
                  child: GestureDetector(
                    onTap: () => showImagePreview(context, images[i].base64Data),
                    child: ConstrainedBox(
                      // 高度也卡住：竖图不这么办会占满整个屏幕。
                      // 不知道原始比例也不用算，BoxFit.contain 会按内在比例
                      // 在这个框里适配。
                      constraints: const BoxConstraints(maxHeight: 340),
                      child: B64Image(base64Data: images[i].base64Data),
                    ),
                  ),
                ),
                // 张与张之间才空格。最后一张后面也发的话，"以图结尾"的气泡
                // 底部会比顶部多 8px（上 12 / 下 20）。
                if (i < images.length - 1 ||
                    text.isNotEmpty ||
                    attachments.isNotEmpty)
                  const SizedBox(height: S.x3),
              ],
              if (attachments.isNotEmpty) ...[
                // 靠右排，跟文字方向一致。已发出去的不给去掉，所以不带叉。
                Wrap(
                  spacing: S.x2,
                  runSpacing: S.x2,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final a in attachments)
                      AttachmentChip(
                        key: ValueKey('sent-${a.name}'),
                        attachment: a,
                        onWash: true,
                      ),
                  ],
                ),
                if (text.isNotEmpty) const SizedBox(height: S.x3),
              ],
              // 纯图消息不该留一行空文字。
              if (text.isNotEmpty)
                Text(
                  text,
                  style: n1Text(size: 15.5, height: 1.62, color: c.ink),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// N1
// ══════════════════════════════════════════════════════════════════

class _AssistantBlock extends StatelessWidget {
  const _AssistantBlock({
    required this.item,
    required this.onLinkTap,
    required this.maxWidth,
  });

  final AssistantItem item;
  final void Function(String url)? onLinkTap;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 隔了一晚上再打开 App 时，这条就挂在最下面。不标出来的话，
            // 用户会以为 N1 突然自己说了句话。
            if (item.fromReminder)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.alarm, size: 13, color: c.trace),
                    const SizedBox(width: 4),
                    Text(
                      '提醒',
                      style: n1Text(size: 11.5, color: c.trace, height: 1.2),
                    ),
                  ],
                ),
              ),

            if (item.reasoning.trim().isNotEmpty)
              ReasoningBlock(text: item.reasoning, streaming: item.streaming),

            for (final trace in item.tools) ToolTraceTile(trace: trace),

            // 还在跑、又什么都还没吐的时候给个"它在动"的信号。
            // 没有这个的话，用户发完消息要盯着空屏好几秒，会以为卡死了。
            if (item.streaming && item.isEmpty)
              _ThinkingDots(color: c.trace)
            else if (item.text.isNotEmpty)
              MarkdownText(
                item.text,
                onLinkTap: onLinkTap,
                base: n1Text(size: 15.5, height: 1.72, color: c.ink),
              ),

            if (item.wasTruncated) _Notice(
              color: c.dim,
              icon: Icons.more_horiz,
              text: '这一步太长，被截断了。说「继续」让它接着往下写。',
            ),

            if (item.contextTrimmed) _Notice(
              color: c.dim,
              icon: Icons.content_cut,
              text: '这段对话太长了，这一步只带了最近的内容——更早的事它可能不记得。',
            ),

            // 说完之后给一个复制入口。只在有正文时出现——空的复制按钮
            // 点下去只会让用户以为自己复制到了什么。
            if (!item.streaming && item.text.trim().isNotEmpty)
              _CopyAction(text: item.text, colors: c),

            if (item.error != null)
              _ErrorBox(message: item.error!, color: c.danger),

            if (!item.streaming && item.usage != null)
              _UsageLine(usage: item.usage!, color: c.faint),
          ],
        ),
      ),
    );
  }
}

/// 复制这条回复。
///
/// 桌面端平时几乎隐形（鼠标移上去才亮），触屏端一直半亮——没有 hover 的话
/// 藏起来就等于没有。复制成功当场变勾，比弹一个 SnackBar 更贴手
/// （SnackBar 在键盘上方、还要等它自己消失）。
class _CopyAction extends StatefulWidget {
  const _CopyAction({required this.text, required this.colors});

  final String text;
  final N1Colors colors;

  @override
  State<_CopyAction> createState() => _CopyActionState();
}

class _CopyActionState extends State<_CopyAction> {
  bool _hover = false;
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    if (!isDesktopPlatform) HapticFeedback.selectionClick();
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final visible = _hover || _copied || !isDesktopPlatform;

    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Semantics(
          button: true,
          label: _copied ? '已复制' : '复制这条回复',
          child: GestureDetector(
            onTap: _copy,
            behavior: HitTestBehavior.opaque,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0.28,
              duration: const Duration(milliseconds: 150),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _copied
                          ? Icons.check_rounded
                          : Icons.content_copy_rounded,
                      size: 13,
                      color: _copied ? c.accentInk : c.faint,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _copied ? '已复制' : '复制',
                      style: n1Text(
                        size: 11.5,
                        color: _copied ? c.accentInk : c.faint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 这一轮花了多少 token。
///
/// 只在流结束后显示。流式过程中很多家根本不推 usage（要等最后一块），
/// 中途显示就只是个 0 在那儿闪，反而让人以为没算对。
class _UsageLine extends StatelessWidget {
  const _UsageLine({required this.usage, required this.color});

  final UsageChunk usage;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      '输入 ${_short(usage.promptTokens)}',
      '输出 ${_short(usage.completionTokens)}',
      // 缓存命中数不是每家都给。给了才显示——它直接关系到这一轮贵不贵。
      if (usage.cachedTokens > 0) '缓存 ${_short(usage.cachedTokens)}',
    ];

    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Text(
        parts.join(' · '),
        style: n1Text(size: 11, height: 1.3, color: color, mono: true),
      ),
    );
  }

  /// 1234 → 1.2k。上万之后取整：`12.3k` 和 `12k` 对这个用户没有区别。
  static String _short(int n) {
    if (n < 1000) return '$n';
    final k = n / 1000;
    return k >= 10 ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
  }
}

/// 三个点的呼吸。
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots({required this.color});

  final Color color;

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: S.x2),
    child: AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            Opacity(
              // 每个点错开三分之一周期，形成"跑马灯"。用 Opacity 而不是
              // 改颜色：改颜色每帧都要新建 Paint，而这里只是透明度。
              //
              // ⚠️ 裸 Opacity 在动画里是要避免的（每个值都会新建图层），
              // 但这里只有三个 6px 的点、范围极小，代价可以忽略。
              opacity: _dotOpacity(i),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  double _dotOpacity(int i) {
    final t = (_ctrl.value + i / 3) % 1.0;
    // 前 40% 淡入、后 60% 淡出——不对称，看起来像"点亮"而不是"闪烁"。
    final v = t < 0.4 ? t / 0.4 : 1 - (t - 0.4) / 0.6;
    return 0.25 + 0.75 * v.clamp(0.0, 1.0);
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.color, required this.icon, required this.text});

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: S.x3),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: S.x2),
        Flexible(
          child: Text(
            text,
            style: n1Text(size: 12.5, height: 1.5, color: color),
          ),
        ),
      ],
    ),
  );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: S.x3),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(S.x4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: R.smAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: color),
          const SizedBox(width: S.x3),
          Expanded(
            child: Text(
              message,
              style: n1Text(size: 13, height: 1.6, color: color),
            ),
          ),
        ],
      ),
    ),
  );
}
