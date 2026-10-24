/// 一个技能：`SKILL.md` 解析后的结果。
///
/// 格式沿用本机 Claude Code 的既有约定，**别发明新字段**：
/// frontmatter 只有 `name` 和 `description` 两个键，触发完全靠 description。
class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.body,
    this.sourcePath,
  });

  final String name;
  final String description;

  /// 去掉 frontmatter 的正文。agent 用 `skill_read` 拿到的是这一部分。
  final String body;

  /// 从哪加载的。排查"为什么这个技能没生效"时用。
  final String? sourcePath;

  /// 解析一份 SKILL.md。
  ///
  /// 容错取向：**能解析出来就用，解析不了返回 null 而不是抛**。
  /// 用户手改技能文件改坏了，不该让整个 App 起不来。
  static Skill? parse(String markdown, {String? sourcePath}) {
    final text = markdown.replaceAll('\r\n', '\n');
    if (!text.startsWith('---')) return null;

    final end = text.indexOf('\n---', 3);
    if (end < 0) return null;

    final frontmatter = text.substring(3, end);
    final body = text.substring(end + 4).trim();

    String? name;
    String? description;
    for (final line in frontmatter.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final colon = trimmed.indexOf(':');
      if (colon <= 0) continue;
      final key = trimmed.substring(0, colon).trim();
      var value = trimmed.substring(colon + 1).trim();
      // 允许值被引号包着
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      switch (key) {
        case 'name':
          name = value;
        case 'description':
          description = value;
      }
    }

    // 两个字段缺一不可：没有 name 挂不上，没有 description 模型不知道什么时候用。
    if (name == null || name.isEmpty) return null;
    if (description == null || description.isEmpty) return null;

    return Skill(
      name: name,
      description: description,
      body: body,
      sourcePath: sourcePath,
    );
  }
}
