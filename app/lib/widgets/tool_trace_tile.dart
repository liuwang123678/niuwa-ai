import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/tokens.dart';
import '../models/chat_item.dart';
import '../theme.dart';

/// 一次工具调用在界面上的样子。
///
/// 默认折叠成一行——"用了什么"要一眼看见，"看到了什么"点开才有。
/// 工具返回动辄几千字（网页正文、搜索结果），默认铺开会把对话冲没。
class ToolTraceTile extends StatefulWidget {
  const ToolTraceTile({super.key, required this.trace});

  final ToolTrace trace;

  /// 工具名 → 中文。
  ///
  /// 表格写死而不是用工具自带的 description：那是**给模型看的**，措辞为了
  /// 让模型选对工具而优化，通常冗长且是完整句子。界面上要的是两三个字，
  /// 两边的诉求不一样，硬凑会两边都别扭。
  ///
  /// ⚠️ **加新工具必须往这儿补一行**，忘了的话界面上会直接显示英文的
  /// 工具名（`run_command`），一眼就不像给人看的东西。
  /// `test/widgets/tool_trace_tile_test.dart` 里有一条对账测试盯着这件事：
  /// 它把 `alwaysOnTools()` + 浏览器/代码/文件工具的名字全捞出来，
  /// 逐个查这张表。
  ///
  /// 公开（不是 `_labels`）就是为了那条测试能拿到它。
  @visibleForTesting
  static const Map<String, String> labels = {
    'get_time': '查看时间',
    'http_fetch': '抓取网页',
    'memory_save': '记下来',
    'memory_search': '回忆',
    'skill_list': '翻技能',
    'skill_read': '读技能',
    'todo_write': '列步骤',
    'reminder_create': '设提醒',
    'reminder_list': '看提醒',
    'browser_open': '打开网页',
    'browser_snapshot': '看页面',
    'browser_click': '点击',
    'browser_type': '输入',
    'browser_scroll': '翻页',
    'browser_screenshot': '截图',
    'browser_back': '返回',
    'read_file': '读文件',
    'write_file': '写文件',
    'write_document': '写文档',
    'edit_file': '改文件',
    'list_dir': '看目录',
    'grep': '搜内容',
    'glob': '找文件',
    'run_command': '跑命令',
    'run_code': '跑代码',
    'run_subagent': '派子代理',
  };

  /// 工具名翻成中文。**认不出来就把原名还回去**——显示一个英文名虽然不像话，
  /// 但比显示"未知工具"强：英文名至少能拿去搜。
  static String labelFor(String name) => labels[name] ?? name;

  @override
  State<ToolTraceTile> createState() => _ToolTraceTileState();
}

class _ToolTraceTileState extends State<ToolTraceTile> {
  bool _open = false;

  String get _label => ToolTraceTile.labelFor(widget.trace.call.name);

  /// 折叠行右边那一小截预览：**跑的是什么命令、动的是哪个文件**。
  ///
  /// 为什么要有：以前这一行只有工具名，于是"跑命令"和"跑代码"在界面上长得
  /// 一模一样。用户要判断"它刚才干的事对不对"，得点开每一行去看——而点开是
  /// 个副作用很小的动作，也很容易漏掉最要紧的那一次调用。
  ///
  /// 取值顺序按"最能说明它在干什么"排：命令 → 脚本 → 路径 → 查询词 → 网址。
  /// 拿不到就返回 null，那一截不显示（宁可空着也不显示"…"占位）。
  String? get _preview {
    final args = widget.trace.call.arguments;
    for (final key in const ['command', 'path', 'source', 'query', 'url']) {
      final value = args[key];
      if (value is String) {
        final single = value.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (single.isNotEmpty) return single;
      }
    }
    return null;
  }

  IconData get _icon => switch (widget.trace.call.name) {
    'get_time' => Icons.schedule_outlined,
    'http_fetch' => Icons.download_outlined,
    'memory_save' => Icons.bookmark_add_outlined,
    'memory_search' => Icons.search_outlined,
    'skill_list' || 'skill_read' => Icons.auto_awesome_outlined,
    'reminder_create' || 'reminder_list' => Icons.alarm_outlined,
    'browser_scroll' => Icons.swap_vert,
    'read_file' => Icons.description_outlined,
    'write_file' => Icons.note_add_outlined,
    'write_document' => Icons.picture_as_pdf_outlined,
    'edit_file' => Icons.edit_outlined,
    'list_dir' => Icons.folder_open_outlined,
    'run_command' => Icons.terminal_outlined,
    'run_code' => Icons.code,
    'run_subagent' => Icons.account_tree_outlined,
    _ => Icons.language_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final t = widget.trace;
    final done = !t.running;
    final failed = done && !t.ok;

    final accent = failed ? c.danger : c.trace;
    final preview = _preview;

    return Padding(
      padding: const EdgeInsets.only(bottom: S.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: done ? () => setState(() => _open = !_open) : null,
            borderRadius: BorderRadius.circular(R.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: S.x2,
                horizontal: S.x1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (t.running)
                    SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: c.trace,
                      ),
                    )
                  else
                    Icon(
                      failed
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 14,
                      color: accent,
                    ),
                  const SizedBox(width: S.x3),
                  Icon(_icon, size: 14, color: accent),
                  const SizedBox(width: S.x2),
                  Text(
                    t.running ? '正在$_label' : _label,
                    style: n1Text(size: 12.5, height: 1.2, color: accent),
                  ),
                  if (preview != null) ...[
                    const SizedBox(width: S.x3),
                    // ⚠️ 这一栏**不能用 `Expanded`**：外面那个 Row 是
                    // `MainAxisSize.min`（这一行要贴着左边紧凑地排），
                    // Expanded 会把它撑满整个 760 的正文宽度，于是耗时和箭头
                    // 被推到屏幕最右边，离正文十万八千里。
                    // `ConstrainedBox` 封个上限就够：Row 给非 flex 子节点的
                    // 主轴约束是无限的，所以长度**必须**在这儿夹住，
                    // 不然一行长命令会把整行撑爆。
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: n1Text(
                          size: 12,
                          height: 1.2,
                          color: c.faint,
                          mono: true,
                        ),
                      ),
                    ),
                  ],
                  if (t.duration != null) ...[
                    const SizedBox(width: S.x2),
                    Text(
                      _formatDuration(t.duration!),
                      style: n1Text(
                        size: 11.5,
                        height: 1.2,
                        color: c.faint,
                        mono: true,
                      ),
                    ),
                  ],
                  if (done) ...[
                    const SizedBox(width: S.x1),
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: M.base,
                      curve: M.out,
                      child: Icon(Icons.chevron_right, size: 15, color: c.faint),
                    ),
                  ],
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: M.base,
            curve: M.out,
            alignment: Alignment.topLeft,
            child: _open && done
                ? Padding(
                    padding: const EdgeInsets.only(left: S.x4, bottom: S.x2),
                    child: _ResultBox(content: t.result?.content ?? ''),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// 秒级以下给一位小数，超过就给整数——"1.4s" 有用，"63.2s" 那位小数是噪音。
  static String _formatDuration(Duration d) {
    final ms = d.inMilliseconds;
    if (ms < 100) return '${ms}ms';
    final s = ms / 1000;
    return s < 10 ? '${s.toStringAsFixed(1)}s' : '${s.round()}s';
  }
}

/// 展开后的结果框。
///
/// 三件事都是**真跑里暴露出来的**，不是先想着要做的：
///
///   1. **限高 + 内部滚动。** 原来是一段裸 `Text`，读一个大文件或者跑一段
///      输出很多的代码，这一条消息能比整个屏幕还高，往上翻对话要滑半天。
///   2. **可选中。** 模型跑出来的报错、路径，用户的第一反应就是复制出去。
///      不可选的话他只能截图。
///   3. **复制按钮。** 一整个文件内容靠长按拖选也是折磨。
class _ResultBox extends StatelessWidget {
  const _ResultBox({required this.content});

  /// 工具回给模型的**原文**。空的时候界面上显示一句说明，但**复制按钮不给**
  /// ——复制一句"它没有输出"是没有任何用处的。
  final String content;

  /// 超过这个高度就内部滚动。约 16 行正文——够看清是什么，
  /// 又不至于把整条对话顶走。
  static const double _maxHeight = 320;

  /// 成功的工具**一个字都不回**是真会发生的：`mkdir`、`cd`、只会退出码的
  /// 命令。原来这里显示一个只有「复制」按钮的空框，看着像坏了。
  static const String _emptyNote = '(它没有输出)';

  /// 空成什么样算空。只有空白也算——一个全是换行的 stdout 在框里就是一片空白。
  bool get _empty => content.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.hasShadow
            ? Color.alphaBlend(Colors.black.withValues(alpha: 0.035), c.bg)
            : c.bg,
        borderRadius: R.smAll,
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _maxHeight),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(S.x4),
                child: SelectableText(
                  _empty ? _emptyNote : content,
                  style: n1Text(size: 12.5, height: 1.6, color: c.dim, mono: true),
                ),
              ),
            ),
          ),
          if (!_empty) ...[
            Divider(height: 1, color: c.line),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: content));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('复制好了')),
                  );
                },
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: S.x3),
                ),
                icon: const Icon(Icons.copy_all_outlined, size: 14),
                label: Text(
                  '复制',
                  style: n1Text(size: 11.5, height: 1.2, color: c.faint),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
