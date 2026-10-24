import 'skill.dart';

/// 技能库。
///
/// 用法跟本机 Claude Code 的 skills-radar 一个思路：**启动时把所有技能的
/// name + description 塞进 system prompt**，模型看到有合适的就调 `skill_read`
/// 拉全文。这样技能再多也不占多少上下文。
class SkillRegistry {
  SkillRegistry([Iterable<Skill> seed = const []]) {
    for (final s in seed) {
      register(s);
    }
  }

  final Map<String, Skill> _skills = {};

  /// 注册。同名覆盖——用户自装的技能可以盖掉内置的同名技能。
  void register(Skill skill) => _skills[skill.name] = skill;

  bool remove(String name) => _skills.remove(name) != null;

  List<Skill> get all {
    final list = _skills.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name)); // 确定性顺序，喂 prompt 用
    return list;
  }

  Skill? byName(String name) => _skills[name];

  int get length => _skills.length;

  bool get isEmpty => _skills.isEmpty;

  /// 生成给模型看的技能索引。
  ///
  /// 顺序排好且稳定，**这是 system prompt 的一部分，顺序一变提示缓存就全废**。
  String toIndexPrompt() {
    if (_skills.isEmpty) return '（当前没有可用技能）';
    final buffer = StringBuffer();
    for (final s in all) {
      buffer.writeln('- ${s.name}: ${s.description}');
    }
    return buffer.toString().trimRight();
  }

  /// 从「文件名 → 内容」加载。解析失败的文件会被跳过并记进 [failures]。
  static ({SkillRegistry registry, List<String> failures}) fromMarkdown(
    Map<String, String> sources,
  ) {
    final registry = SkillRegistry();
    final failures = <String>[];
    sources.forEach((path, markdown) {
      final skill = Skill.parse(markdown, sourcePath: path);
      if (skill == null) {
        failures.add(path);
      } else {
        registry.register(skill);
      }
    });
    return (registry: registry, failures: failures);
  }
}
