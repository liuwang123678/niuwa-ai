import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../providers/memory_provider.dart';
import '../theme.dart';
import '../util/time_text.dart';

/// 记忆页：N1 攒下来的关于你的事。
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mem = context.watch<MemoryProvider>();
    final c = N1Colors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        title: const Text('记忆'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: mem.load,
            icon: const Icon(Icons.refresh, size: 20),
          ),
          const SizedBox(width: S.x2),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x6, S.x2, S.x6, S.x4),
            child: _SearchField(
              controller: _search,
              onChanged: (v) => v.trim().isEmpty ? mem.clearSearch() : null,
              onSubmitted: mem.search,
            ),
          ),
          Expanded(child: _list(mem, c)),
        ],
      ),
    );
  }

  Widget _list(MemoryProvider mem, N1Colors c) {
    if (mem.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    if (mem.entries.isEmpty) {
      return _Empty(searching: mem.searching, query: mem.query);
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(S.x6, 0, S.x6, S.x8),
          itemCount: mem.entries.length + 1,
          itemBuilder: (context, i) {
            if (i == mem.entries.length) return _Footer(mem: mem);
            return _MemoryCard(entry: mem.entries[i], mem: mem);
          },
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      style: n1Text(size: 14.5, height: 1.4, color: c.ink),
      decoration: InputDecoration(
        hintText: '搜记忆里的内容、标签…',
        prefixIcon: Icon(Icons.search, size: 18, color: c.faint),
        prefixIconConstraints: const BoxConstraints(minWidth: 42),
        suffixIcon: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => controller.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  icon: Icon(Icons.close, size: 16, color: c.faint),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: S.x4),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.entry, required this.mem});

  final MemoryEntry entry;
  final MemoryProvider mem;

  /// 记忆的种类 → 中文。用表格而不是 `kind.name`：`preference` 直接显示出来
  /// 对用户是天书。
  static const Map<MemoryKind, String> _kindLabels = {
    MemoryKind.fact: '事实',
    MemoryKind.preference: '偏好',
    MemoryKind.event: '经历',
    MemoryKind.relation: '关系',
    MemoryKind.summary: '小结',
  };

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: Container(
        padding: const EdgeInsets.all(S.x5),
        decoration: c.surface(radius: R.md, outline: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Chip(
                  text: _kindLabels[entry.kind] ?? entry.kind.name,
                  color: c.accentInk,
                  bg: c.accentWash,
                ),
                if (entry.subject != null && entry.subject!.isNotEmpty) ...[
                  const SizedBox(width: S.x2),
                  Flexible(
                    child: Text(
                      entry.subject!,
                      overflow: TextOverflow.ellipsis,
                      style: n1Text(
                        size: 12,
                        height: 1.4,
                        color: c.dim,
                      ).n1W(500),
                    ),
                  ),
                ],
                const Spacer(),
                // 重要度用点表示，不用星星。星星有"评分"的联想，
                // 而这里的含义是"这条有多值得记住"，是权重不是好坏。
                _Importance(value: entry.importance, color: c.accentInk),
              ],
            ),
            const SizedBox(height: S.x3),
            Text(
              entry.content,
              style: n1Text(size: 14.5, height: 1.65, color: c.ink),
            ),
            if (entry.tags.isNotEmpty) ...[
              const SizedBox(height: S.x3),
              Wrap(
                spacing: S.x2,
                runSpacing: S.x2,
                children: [
                  for (final t in entry.tags)
                    Text(
                      '#$t',
                      style: n1Text(size: 11.5, height: 1.3, color: c.faint),
                    ),
                ],
              ),
            ],
            const SizedBox(height: S.x3),
            Row(
              children: [
                Text(
                  relativeTime(
                    DateTime.fromMillisecondsSinceEpoch(entry.updatedAt),
                  ),
                  style: n1Text(size: 11.5, height: 1.3, color: c.faint),
                ),
                if (entry.useCount > 0) ...[
                  const SizedBox(width: S.x3),
                  Text(
                    '用过 ${entry.useCount} 次',
                    style: n1Text(size: 11.5, height: 1.3, color: c.faint),
                  ),
                ],
                const Spacer(),
                IconButton(
                  tooltip: '改一下',
                  onPressed: () => _edit(context, entry, mem),
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  color: c.faint,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
                IconButton(
                  tooltip: '忘掉这条',
                  onPressed: () => _confirmDelete(context, entry, mem),
                  icon: const Icon(Icons.close, size: 16),
                  color: c.faint,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 改内容 / 改重要度。
  ///
  /// 为什么值得做：模型记错的时候（人称、时间、把"不喜欢"写成"喜欢"），
  /// 以前唯一的出路是删掉重记，而删掉之后它不一定再记一次——这条就没了。
  Future<void> _edit(
    BuildContext context,
    MemoryEntry entry,
    MemoryProvider mem,
  ) async {
    final controller = TextEditingController(text: entry.content);
    var importance = entry.importance;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('改一下'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 5,
                autofocus: true,
                decoration: const InputDecoration(hintText: '一句话说清'),
              ),
              const SizedBox(height: S.x4),
              Text(
                '重要度 $importance',
                style: n1Text(
                  size: 12.5,
                  height: 1.4,
                  color: N1Colors.of(ctx).dim,
                ),
              ),
              Slider(
                value: importance.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                label: '$importance',
                onChanged: (v) => setState(() => importance = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('算了'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      await mem.update(entry, content: controller.text, importance: importance);
    }
    controller.dispose();
  }

  Future<void> _confirmDelete(
    BuildContext context,
    MemoryEntry entry,
    MemoryProvider mem,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让它忘掉？'),
        content: Text('「${entry.content}」\n\n删了就真没了。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('留着'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('忘掉', style: TextStyle(color: N1Colors.of(ctx).danger)),
          ),
        ],
      ),
    );
    if (ok == true) await mem.delete(entry.id);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color, required this.bg});

  final String text;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(R.sm),
    ),
    child: Text(
      text,
      style: n1Text(size: 11.5, height: 1.35, color: color).n1W(600),
    ),
  );
}

class _Importance extends StatelessWidget {
  const _Importance({required this.value, required this.color});

  /// 1..5
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= value ? color : c.line,
              ),
            ),
          ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.mem});

  final MemoryProvider mem;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: S.x4),
      child: Center(
        child: Text(
          mem.searching
              ? '在 ${mem.total} 条记忆里找到 ${mem.entries.length} 条'
              : '一共 ${mem.total} 条',
          style: n1Text(size: 12, height: 1.4, color: c.faint),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.searching, required this.query});

  final bool searching;
  final String query;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(S.x8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                searching ? Icons.search_off : Icons.psychology_outlined,
                size: 40,
                color: c.lineStrong,
              ),
              const SizedBox(height: S.x5),
              Text(
                searching ? '没找到跟「$query」有关的' : '还什么都没记住',
                textAlign: TextAlign.center,
                style: n1Text(size: 15, height: 1.6, color: c.dim),
              ),
              if (!searching) ...[
                const SizedBox(height: S.x2),
                Text(
                  '聊天的时候说点关于你自己的事，我会记下来。',
                  textAlign: TextAlign.center,
                  style: n1Text(size: 13, height: 1.6, color: c.faint),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
