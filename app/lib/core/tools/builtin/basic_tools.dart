import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../n1_tool.dart';
import '../tool_context.dart';

/// 当前时间。
///
/// system prompt 里已经有一份时间了，但那是这一轮开始时的快照。会话长了、
/// 或者用户隔了很久接着聊，模型需要能重新问一下。
class GetTimeTool extends N1Tool {
  GetTimeTool({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'get_time';

  @override
  String get description => '获取当前日期和时间。需要知道"现在几点""今天几号""星期几"时使用。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final now = _clock();
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return ToolResult.ok(
      '${now.year}年${now.month}月${now.day}日 '
      '星期${weekdays[now.weekday - 1]} '
      '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}',
    );
  }
}

/// 抓取网页并转成纯文本。
class HttpFetchTool extends N1Tool {
  const HttpFetchTool();

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'http_fetch';

  @override
  String get description =>
      '抓取一个已知 URL 的网页内容，返回纯文本。已经知道确切网址时用这个，'
      '比开浏览器快得多。不知道网址、或者页面要靠 JS 渲染才有内容、'
      '或者需要点击登录时，改用 browser_* 工具。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': '完整的网址，要带 http:// 或 https://'},
      'max_chars': {
        'type': 'integer',
        'description': '返回正文的最大字符数，默认 8000',
      },
    },
    'required': ['url'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final url = N1Tool.requireString(input, 'url');
    final maxChars = N1Tool.optionalInt(input, 'max_chars', fallback: 8000);

    final res = await ctx.fetch(url);

    if (!res.ok) {
      return ToolResult.fail('HTTP ${res.statusCode}——这个地址抓不到内容。');
    }

    // 抓到什么就按什么处理：Content-Type 说了是 HTML 才解析，否则当纯文本。
    final isHtml =
        (res.contentType ?? '').contains('html') ||
        res.body.trimLeft().toLowerCase().startsWith('<!doctype html') ||
        res.body.trimLeft().toLowerCase().startsWith('<html');

    final text = isHtml ? _htmlToText(res.body) : res.body;
    final trimmed = _truncate(text, maxChars);

    final notes = <String>[];
    if (res.garbled) {
      notes.add(
        '注意：这个页面不是 UTF-8 编码（多半是 GBK），下面内容可能乱码。'
        '建议改用 browser_open 打开它。',
      );
    }
    if (res.truncated) notes.add('（响应过大，只取了前 512KB）');
    if (trimmed.length < text.length) {
      notes.add('（正文已截断到 $maxChars 字）');
    }

    final header = notes.isEmpty ? '' : '${notes.join('\n')}\n\n';
    return ToolResult.ok(
      '$header$trimmed',
      meta: {'url': url, 'status': res.statusCode},
    );
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// HTML → 纯文本。
  ///
  /// 目标是**喂给模型读**，不是还原排版。所以：干掉脚本样式、块级元素之间补换行、
  /// 把连续空白压成一个空格。丢掉的东西（链接地址、图片）对理解正文通常不重要。
  static String _htmlToText(String html) {
    final doc = html_parser.parse(html);

    for (final el in doc.querySelectorAll(
      'script, style, noscript, svg, iframe, head, nav, footer',
    )) {
      el.remove();
    }

    final root = doc.body ?? doc.documentElement;
    if (root == null) return '';

    final buffer = StringBuffer();
    _walk(root, buffer);

    return buffer
        .toString()
        .replaceAll(RegExp(r'[ \t ]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// 这些元素前后要有换行，否则整页文字会挤成一行，模型读起来很痛苦。
  static const Set<String> _blockTags = {
    'p', 'div', 'br', 'li', 'tr', 'h1', 'h2', 'h3', 'h4',
    'h5', 'h6', 'section', 'article', 'blockquote', 'pre', 'table',
  };

  static void _walk(dom.Node node, StringBuffer out) {
    for (final child in node.nodes) {
      if (child is dom.Element) {
        final isBlock = _blockTags.contains(child.localName);
        if (isBlock) out.write('\n');
        _walk(child, out);
        if (isBlock) out.write('\n');
      } else if (child is dom.Text) {
        out.write(child.text);
      }
    }
  }
}
