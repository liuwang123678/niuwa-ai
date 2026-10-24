import '../n1_tool.dart';
import '../tool_context.dart';

/// 列出可用技能。
///
/// system prompt 里已经有技能索引了，这个工具存在的意义是"索引可能被截断"或者
/// 用户中途装了新技能时能重新看一眼。
class SkillListTool extends N1Tool {
  const SkillListTool();

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'skill_list';

  @override
  String get description => '列出当前可用的全部技能及其用途。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    if (ctx.skills.isEmpty) return ToolResult.ok('当前没有可用技能。');
    return ToolResult.ok(ctx.skills.toIndexPrompt());
  }
}

/// 读一个技能的完整内容。
class SkillReadTool extends N1Tool {
  const SkillReadTool();

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'skill_read';

  @override
  String get description =>
      '读取某个技能的完整说明（操作流程、注意事项）。'
      '决定用某个技能之后，先读它再照着做，不要凭名字猜流程。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': '技能名，如 web-research'},
    },
    'required': ['name'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final name = N1Tool.requireString(input, 'name');
    final skill = ctx.skills.byName(name);

    if (skill == null) {
      final available = ctx.skills.all.map((s) => s.name).join('、');
      return ToolResult.fail(
        '没有叫 `$name` 的技能。可用的是：${available.isEmpty ? '（无）' : available}',
      );
    }

    return ToolResult.ok(
      '# ${skill.name}\n\n${skill.body}',
      meta: {'skill': skill.name},
    );
  }
}
