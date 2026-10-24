import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../theme.dart';

/// 轻量 Markdown 渲染。
///
/// 为什么自己写而不是引包：`flutter_markdown` 官方已停止维护；引一个半废弃的
/// 包来撑门面，将来 Dart 或 Flutter 一升级就是坑。而这个场景要的语法其实很少
/// （标题、列表、代码块、引用、粗斜体、行内代码），几百行够了。
///
/// 关键需求是**流式安全**：模型吐到一半时 ` ``` ` 没闭合、`**` 只有一半，
/// 这时候不能崩、也不能显示成乱码系。所有解析遇到不闭合的语法都退化成普通
/// 文本。
///
/// 覆盖范围刻意保守——不支持的语法（表格、脚注、嵌套列表、链接文字里的
/// 行内格式）按普通文本渲染，总比渲染错好。
class MarkdownText extends StatefulWidget {
  const MarkdownText(
    this.text, {
    super.key,
    this.base,
    this.onLinkTap,
    this.codeMaxHeight = 360,
  });

  final String text;

  /// 基准样式。不给就用 bodyLarge。
  final TextStyle? base;

  /// 点链接。不给的话链接只显示成主色，不可点。
  final void Function(String url)? onLinkTap;

  /// 代码块最高多少。超过就内部滚动，不让一段长代码把整屏撑走。
  final double codeMaxHeight;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  late List<_Block> _blocks;

  /// 链接的手势识别器，按 URL 存。
  ///
  /// 为什么要在这里持有、而不是每次解析时 new 一个挂到 TextSpan 上：
  /// `GestureRecognizer` 是**必须手动 dispose** 的（它注册了全局的手势竞技场）。
  /// 流式输出时文本每变一次就重建一遍 span，如果每次都 new，那些旧的就永远
  /// 没人释放——一条长回复能漏出上百个。所以按 URL 复用，由这个 State 统一
  /// 管生命周期。
  final Map<String, TapGestureRecognizer> _recognizers = {};

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(MarkdownText old) {
    super.didUpdateWidget(old);
    // 只在文本真的变了才重新解析。流式输出时每来一个字都会 rebuild，
    // 一个长对话里每条都重解析是白烧 CPU。
    if (widget.text != old.text) _rebuild();
  }

  @override
  void dispose() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  void _rebuild() => _blocks = _parse(widget.text);

  InlineSpan _linkSpan(String label, String url, TextStyle style) {
    final onTap = widget.onLinkTap;
    if (onTap == null) return TextSpan(text: label, style: style);

    final recognizer = _recognizers.putIfAbsent(
      url,
      () => TapGestureRecognizer()..onTap = () => onTap(url),
    );
    return TextSpan(text: label, style: style, recognizer: recognizer);
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.base ?? Theme.of(context).textTheme.bodyLarge!;
    final inline = _Inline(
      owner: widget,
      link: _linkSpan,
      colors: N1Colors.of(context),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _blocks.length; i++)
          Padding(
            // 块间距。标题上方给得多一点，让层级靠留白拉开，而不是靠字号堆。
            padding: EdgeInsets.only(top: i == 0 ? 0 : _blocks[i].gapBefore),
            child: _blocks[i].build(context, base, inline),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 块
// ══════════════════════════════════════════════════════════════════

sealed class _Block {
  const _Block();

  /// 跟上一个块之间的间距。
  double get gapBefore => S.x3;

  Widget build(BuildContext context, TextStyle base, _Inline inline);
}

final class _Para extends _Block {
  const _Para(this.text);
  final String text;

  @override
  Widget build(BuildContext context, TextStyle base, _Inline inline) =>
      Text.rich(TextSpan(children: inline.parse(text, base)), style: base);
}

final class _Heading extends _Block {
  const _Heading(this.level, this.text);
  final int level;
  final String text;

  @override
  double get gapBefore => level <= 2 ? S.x6 : S.x5;

  @override
  Widget build(BuildContext context, TextStyle base, _Inline inline) {
    // 标题在聊天正文里不该比气泡还大，所以层级压得比文档场景平。
    final size = switch (level) {
      1 => 18.0,
      2 => 16.5,
      _ => 15.5,
    };
    return Padding(
      padding: EdgeInsets.only(top: level <= 2 ? S.x1 : 0),
      child: Text.rich(
        TextSpan(children: inline.parse(text, base)),
        style: base.copyWith(
          fontSize: size,
          fontVariations: const [FontVariation('wght', 650)],
          height: 1.45,
          letterSpacing: -0.015 * size,
        ),
      ),
    );
  }
}

final class _Code extends _Block {
  const _Code(this.code, this.lang);
  final String code;
  final String? lang;

  @override
  double get gapBefore => S.x4;

  @override
  Widget build(BuildContext context, TextStyle base, _Inline inline) {
    final c = inline.colors;
    final mono = n1Text(size: 13, height: 1.65, mono: true, color: c.ink);
    final hasLabel = lang != null && lang!.isNotEmpty;

    // 暗底上代码块要比卡片更暗一档，亮底上要比卡片更灰一档——
    // 两个方向都是"凹陷"，跟浮起来的卡片形成对比。
    final bg = c.hasShadow
        ? c.bg
        : Color.alphaBlend(Colors.black.withValues(alpha: 0.22), c.card);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: R.smAll,
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasLabel)
            Padding(
              padding: const EdgeInsets.only(
                left: S.x4,
                right: S.x4,
                top: S.x3,
              ),
              child: Text(
                lang!,
                style: n1Text(
                  size: 10.5,
                  color: c.faint,
                  height: 1.2,
                  mono: true,
                ).n1W(500),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: inline.owner.codeMaxHeight),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                  horizontal: S.x4,
                  vertical: hasLabel ? S.x3 : S.x4,
                ),
                child: Text(code, style: mono),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _Bullet extends _Block {
  const _Bullet(this.items, this.markers);

  final List<String> items;

  /// 每条的编号。无序列表给 `•`；有序列表沿用原文的序号——模型从 3 开始写
  /// 就显示 3，那是它的本意。
  final List<String> markers;

  @override
  double get gapBefore => S.x4;

  @override
  Widget build(BuildContext context, TextStyle base, _Inline inline) {
    final lineHeight = base.height ?? 1.7;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : S.x2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 固定宽度让正文左边缘对齐——中文标点和数字宽度不一，
                // 不固定的话多条列表会参差不齐。
                SizedBox(
                  width: 22,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      markers[i],
                      style: n1Text(
                        size: 13,
                        color: inline.colors.accentInk,
                        height: lineHeight,
                        mono: markers[i] != '•',
                      ).n1W(600),
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: inline.parse(items[i], base)),
                    style: base,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

final class _Quote extends _Block {
  const _Quote(this.text);
  final String text;

  @override
  double get gapBefore => S.x4;

  @override
  Widget build(BuildContext context, TextStyle base, _Inline inline) => Container(
    padding: const EdgeInsets.only(left: S.x4),
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: inline.colors.lineStrong, width: 3)),
    ),
    child: Text.rich(
      TextSpan(children: inline.parse(text, base)),
      style: base.copyWith(color: inline.colors.dim),
    ),
  );
}

final class _Rule extends _Block {
  const _Rule();

  @override
  double get gapBefore => S.x5;

  @override
  Widget build(BuildContext context, TextStyle base, _Inline inline) =>
      Container(height: 1, color: inline.colors.line);
}

// ══════════════════════════════════════════════════════════════════
// 解析
// ══════════════════════════════════════════════════════════════════

final _fence = RegExp(r'^\s*(```|~~~)\s*([^\s`]*)');
final _bullet = RegExp(r'^(\s*)([-*+])\s+(.*)$');
final _ordered = RegExp(r'^(\s*)(\d{1,3})[.)]\s+(.*)$');
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])\s*(\1\s*){2,}$');

List<_Block> _parse(String src) {
  final lines = src.replaceAll('\r\n', '\n').split('\n');
  final blocks = <_Block>[];

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];

    // 空行：跳过。块间距由 gapBefore 统一控制，不靠堆空行。
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // ── 代码围栏 ──
    final fence = _fence.firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      final lang = fence.group(2)!;
      final body = <String>[];
      i++;
      while (i < lines.length) {
        if (lines[i].trimLeft().startsWith(marker)) {
          i++;
          break;
        }
        body.add(lines[i]);
        i++;
      }
      // 没闭合（还在流式输出）也照常渲染成代码块——否则它会先当普通文本渲染
      // 一次，等闭合了再变成代码块，视觉上"跳"一下。
      blocks.add(_Code(body.join('\n'), lang));
      continue;
    }

    if (_rule.hasMatch(line)) {
      blocks.add(const _Rule());
      i++;
      continue;
    }

    final h = _heading.firstMatch(line);
    if (h != null) {
      blocks.add(_Heading(h.group(1)!.length, h.group(2)!.trim()));
      i++;
      continue;
    }

    // ── 引用：连续的 `>` 行并成一块 ──
    if (line.trimLeft().startsWith('>')) {
      final body = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        body.add(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      blocks.add(_Quote(body.join(' ').trim()));
      continue;
    }

    // ── 列表：连续的同类行并成一块 ──
    final b = _bullet.firstMatch(line);
    final o = _ordered.firstMatch(line);
    if (b != null || o != null) {
      final isOrdered = o != null;
      final items = <String>[];
      final markers = <String>[];

      while (i < lines.length) {
        final cur = lines[i];
        if (cur.trim().isEmpty) break;

        final mb = _bullet.firstMatch(cur);
        final mo = _ordered.firstMatch(cur);

        if (isOrdered && mo != null) {
          markers.add('${mo.group(2)}.');
          items.add(mo.group(3)!.trim());
          i++;
        } else if (!isOrdered && mb != null) {
          markers.add('•');
          items.add(mb.group(3)!.trim());
          i++;
        } else if (cur.startsWith('  ') && items.isNotEmpty) {
          // 续行：缩进的行接到上一条后面
          items[items.length - 1] = '${items.last} ${cur.trim()}';
          i++;
        } else {
          break;
        }
      }

      blocks.add(_Bullet(items, markers));
      continue;
    }

    // ── 普通段落：吃到空行或下一个块级标记为止 ──
    final para = <String>[];
    while (i < lines.length) {
      final cur = lines[i];
      if (cur.trim().isEmpty ||
          _fence.hasMatch(cur) ||
          _heading.hasMatch(cur) ||
          _bullet.hasMatch(cur) ||
          _ordered.hasMatch(cur) ||
          _rule.hasMatch(cur) ||
          cur.trimLeft().startsWith('>')) {
        break;
      }
      para.add(cur.trim());
      i++;
    }
    if (para.isNotEmpty) blocks.add(_Para(para.join(' ')));
  }

  return blocks;
}

// ══════════════════════════════════════════════════════════════════
// 行内
// ══════════════════════════════════════════════════════════════════

final _url = RegExp(r'https?://[^\s<>()\[\]「」【】，。；：！？]+');

/// 行内解析要用到的一小撮上下文。打包成一个对象，免得每个块都要多传三个参数。
///
/// 只在 `build` 阶段创建——颜色要从 `BuildContext` 取，而块结构（`_parse`）
/// 是纯字符串处理、不需要颜色。两者分开，就不会出现"解析时颜色还没绑好"这种
/// 时序问题。
class _Inline {
  _Inline({required this.owner, required this.link, required this.colors});

  final MarkdownText owner;

  /// 造一个链接 span。识别器的生命周期由宿主 State 管，这里只负责要。
  final InlineSpan Function(String label, String url, TextStyle style) link;

  final N1Colors colors;

  List<InlineSpan> parse(String src, TextStyle base) =>
      _parseInline(src, base, colors, this);
}

/// 行内语法：`代码`、**粗**、*斜*、~~删~~、[文字](链接)、裸链接。
///
/// 递归下降。遇到不闭合的标记就当普通字符吐出去——输出到一半的 `**` 不该让
/// 后面整段变形。
List<InlineSpan> _parseInline(
  String src,
  TextStyle base,
  N1Colors c,
  _Inline inline,
) {
  final spans = <InlineSpan>[];
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    spans.add(TextSpan(text: buf.toString()));
    buf.clear();
  }

  void recurse(String inner, TextStyle style) {
    flush();
    spans.addAll(_parseInline(inner, style, c, inline));
  }

  var i = 0;
  while (i < src.length) {
    final ch = src[i];

    // ── 行内代码 ──
    if (ch == '`') {
      final end = src.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        spans.add(
          TextSpan(
            text: src.substring(i + 1, end),
            style: base.copyWith(
              fontFamily: kFontMono,
              fontFamilyFallback: const ['Consolas', 'monospace'],
              fontSize: (base.fontSize ?? 15) - 1.5,
              backgroundColor: c.accentWash,
              color: c.hasShadow ? kAccentInkLight : c.ink,
            ),
          ),
        );
        i = end + 1;
        continue;
      }
    }

    // ── 粗体 ──
    if (ch == '*' && i + 1 < src.length && src[i + 1] == '*') {
      final end = src.indexOf('**', i + 2);
      if (end > i + 1) {
        recurse(src.substring(i + 2, end), base.n1W(680).copyWith(color: c.ink));
        i = end + 2;
        continue;
      }
    }

    // ── 删除线 ──
    if (ch == '~' && i + 1 < src.length && src[i + 1] == '~') {
      final end = src.indexOf('~~', i + 2);
      if (end > i + 1) {
        recurse(
          src.substring(i + 2, end),
          base.copyWith(decoration: TextDecoration.lineThrough, color: c.dim),
        );
        i = end + 2;
        continue;
      }
    }

    // ── 斜体 ──
    // 要求两侧不是词字符，否则 `a*b*c` 这种算式会被误判成斜体。
    if (ch == '*' || ch == '_') {
      final prevOk = i == 0 || !_isWordChar(src[i - 1]);
      final end = src.indexOf(ch, i + 1);
      if (prevOk &&
          end > i + 1 &&
          end + 1 < src.length &&
          !_isWordChar(src[end + 1])) {
        recurse(
          src.substring(i + 1, end),
          base.copyWith(fontStyle: FontStyle.italic),
        );
        i = end + 1;
        continue;
      }
    }

    // ── 链接 ──
    if (ch == '[') {
      final close = src.indexOf(']', i + 1);
      if (close > i && close + 1 < src.length && src[close + 1] == '(') {
        final paren = src.indexOf(')', close + 2);
        if (paren > close) {
          flush();
          spans.add(
            inline.link(
              src.substring(i + 1, close),
              src.substring(close + 2, paren),
              base.copyWith(color: c.accentInk),
            ),
          );
          i = paren + 1;
          continue;
        }
      }
    }

    // ── 裸链接 ──
    if (ch == 'h' && src.startsWith('http', i)) {
      final m = _url.matchAsPrefix(src, i);
      if (m != null) {
        final url = m.group(0)!;
        flush();
        spans.add(inline.link(url, url, base.copyWith(color: c.accentInk)));
        i = m.end;
        continue;
      }
    }

    buf.write(ch);
    i++;
  }

  flush();
  return spans;
}

bool _isWordChar(String ch) {
  final code = ch.codeUnitAt(0);
  return (code >= 48 && code <= 57) || // 0-9
      (code >= 65 && code <= 90) || // A-Z
      (code >= 97 && code <= 122) || // a-z
      code > 127; // 中文等一律当"词字符"，免得中文里的 * 被当成斜体
}
