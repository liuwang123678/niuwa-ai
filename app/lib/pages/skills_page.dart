import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../providers/skills_provider.dart';
import '../theme.dart';

/// 技能页：N1 会哪些"成套的做法"。
///
/// 技能就是 `<appSupport>/skills/<名字>/SKILL.md`。这个页面只负责让用户**看见**
/// 有什么、以及文件在哪，不提供编辑——理由见 [SkillsProvider] 的类注释。
class SkillsPage extends StatelessWidget {
  const SkillsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SkillsProvider>();
    final open = p.open;

    return Scaffold(
      backgroundColor: N1Colors.of(context).bg,
      appBar: AppBar(
        title: Text(open == null ? '技能' : open.name),
        leading: open == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: p.closeDetail,
              ),
        actions: open == null
            ? [
                IconButton(
                  tooltip: '重新读取',
                  onPressed: p.loading ? null : () => p.reload(),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                const SizedBox(width: S.x2),
              ]
            : null,
      ),
      body: open == null ? _List(p: p) : _Detail(skill: open, p: p),
    );
  }
}

class _List extends StatelessWidget {
  const _List({required this.p});

  final SkillsProvider p;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    if (p.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(S.x6, S.x2, S.x6, S.x8),
          children: [
            _PathCard(dir: p.skillsDir),
            const SizedBox(height: S.x5),

            if (p.error != null) ...[
              Text(
                p.error!,
                style: n1Text(size: 13, height: 1.6, color: c.danger),
              ),
              const SizedBox(height: S.x4),
            ],

            if (p.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: S.x8),
                child: Center(
                  child: Text(
                    '一个技能都没有。',
                    style: n1Text(size: 14, height: 1.6, color: c.dim),
                  ),
                ),
              )
            else
              for (final s in p.skills)
                Padding(
                  padding: const EdgeInsets.only(bottom: S.x3),
                  child: _SkillCard(skill: s, onTap: () => p.show(s)),
                ),
          ],
        ),
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({required this.skill, required this.onTap});

  final Skill skill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: R.mdAll,
      child: Container(
        padding: const EdgeInsets.all(S.x5),
        decoration: c.surface(radius: R.md, outline: true),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    skill.name,
                    style: n1Text(
                      size: 15,
                      weight: 600,
                      height: 1.4,
                      color: c.ink,
                      mono: true,
                    ),
                  ),
                  const SizedBox(height: S.x2),
                  Text(
                    skill.description,
                    style: n1Text(size: 13.5, height: 1.6, color: c.dim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: S.x3),
            Icon(Icons.chevron_right, size: 18, color: c.faint),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.skill, required this.p});

  final Skill skill;
  final SkillsProvider p;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(S.x6, S.x2, S.x6, S.x8),
          children: [
            Text(
              skill.description,
              style: n1Text(size: 14.5, height: 1.7, color: c.dim),
            ),
            const SizedBox(height: S.x5),

            // 正文按 markdown 原样显示，**不做渲染**。
            // 这一页是给"我想知道它到底怎么写的"用的，渲染成好看的排版反而
            // 会盖掉 markdown 结构本身——而那个结构正是 `skill_read` 交给
            // 模型的东西，是这里唯一值得看的内容。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(S.x5),
              decoration: BoxDecoration(
                color: c.hasShadow
                    ? Color.alphaBlend(
                        Colors.black.withValues(alpha: 0.035),
                        c.bg,
                      )
                    : c.bg,
                borderRadius: R.smAll,
                border: Border.all(color: c.line),
              ),
              child: SelectableText(
                skill.body,
                style: n1Text(
                  size: 12.5,
                  height: 1.7,
                  color: c.dim,
                  mono: true,
                ),
              ),
            ),
            const SizedBox(height: S.x5),
            _PathCard(dir: p.pathOf(skill.name), label: '这个技能的文件'),
          ],
        ),
      ),
    );
  }
}

/// 文件路径卡片。点一下复制——路径很长，让用户手抄是不现实的。
class _PathCard extends StatelessWidget {
  const _PathCard({required this.dir, this.label = '技能放在这里'});

  final String dir;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: dir));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('路径已复制'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      borderRadius: R.smAll,
      child: Container(
        padding: const EdgeInsets.all(S.x4),
        decoration: BoxDecoration(
          color: c.accentWash,
          borderRadius: R.smAll,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.folder_outlined, size: 16, color: c.accentInk),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: n1Text(
                      size: 11.5,
                      height: 1.4,
                      color: c.accentInk,
                    ).n1W(600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    dir,
                    style: n1Text(
                      size: 11.5,
                      height: 1.5,
                      color: c.accentInk,
                      mono: true,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.copy, size: 14, color: c.accentInk),
          ],
        ),
      ),
    );
  }
}
