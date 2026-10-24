import '../../memory/memory_store.dart';
import '../n1_tool.dart';
import '../tool_context.dart';

/// 存一条长期记忆。
class MemorySaveTool extends N1Tool {
  const MemorySaveTool();

  @override
  String get name => 'memory_save';

  @override
  String get description =>
      '把值得长期记住的信息存进记忆。用户提到自己的偏好、习惯、身份、在做的项目、'
      '重要日期，或者明确说"记住"时使用。一次只记一件事，用一句话写清。'
      '判断标准：这条信息两周后、在另一场对话里还有用吗？\n'
      '同一件事说了新的版本（比如以前不吃香菜、现在吃了），把旧记忆的 id 填进 '
      'replace_id，不要留下两条互相打脸的记忆。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'content': {
        'type': 'string',
        'description': '一句话说清这件事。写"用户不吃香菜"，不要写"用户说他不喜欢吃香菜"。',
      },
      'kind': {
        'type': 'string',
        'enum': ['fact', 'preference', 'event', 'relation', 'summary'],
        'description':
            'fact=客观事实, preference=偏好, event=发生过的事, '
            'relation=人际关系, summary=会话摘要',
      },
      'subject': {
        'type': 'string',
        'description': '关于谁/关于什么。如"用户本人""用户的猫""用户的考研计划"',
      },
      'importance': {
        'type': 'integer',
        'description': '重要度 1-5。日常偏好 2-3，重要身份或长期计划 4，用户强调的 5',
      },
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': '关键词标签，方便以后检索',
      },
      'replace_id': {
        'type': 'string',
        'description':
            '要取代的旧记忆 id。只在"这条新信息推翻了某条旧记忆"时填，'
            'id 从 memory_search 的结果里拿。普通的补充不要填。',
      },
    },
    'required': ['content', 'kind'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final content = N1Tool.requireString(input, 'content');
    final kind = N1Tool.requireString(input, 'kind');
    final subject = N1Tool.optionalString(input, 'subject');
    final importance = N1Tool.optionalInt(input, 'importance', fallback: 3);
    final replaceId = N1Tool.optionalString(input, 'replace_id');

    if (!MemoryKind.values.any((k) => k.name == kind)) {
      throw ToolInputException(
        '`kind` 只能是 ${MemoryKind.values.map((k) => k.name).join('/')}，收到的是 "$kind"',
      );
    }

    final rawTags = input['tags'];
    final tags = rawTags is List
        ? rawTags.whereType<String>().take(6).toList()
        : const <String>[];

    final entry = MemoryEntry.create(
      kind: MemoryKind.parse(kind),
      content: content,
      subject: subject,
      tags: tags,
      importance: importance,
    );
    final result = await ctx.memory.saveSmart(entry, replaceId: replaceId);

    // 回给模型的文本刻意简短。记忆是后台动作，不影响对话节奏。
    final message = switch (result.action) {
      MemorySaveAction.created => '已记住。',
      MemorySaveAction.updated => '已更新原来那条记忆。',
      MemorySaveAction.needsReview =>
        '已记住。但库里有一条可能重复的：${result.similar!.id}「${result.similar!.content}」。'
            '如果这次说的就是同一件事的新版本，带 replace_id 再存一次把那两条合成一条。',
    };
    return ToolResult.ok(
      message,
      meta: {'memory_id': result.entry.id, 'action': result.action.name},
    );
  }
}

/// 检索记忆。
class MemorySearchTool extends N1Tool {
  const MemorySearchTool();

  @override
  String get name => 'memory_search';

  @override
  String get description =>
      '在长期记忆里搜索细节。system prompt 里只有记忆的摘要索引，'
      '需要更完整的内容、或者想确认某件事之前是否聊过时用这个。'
      '搜到的每条都带 id，要更新某条旧记忆时用得上。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': '搜索关键词。留空则返回最重要的若干条。',
      },
      'limit': {'type': 'integer', 'description': '最多返回几条，默认 8'},
    },
    'required': ['query'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final query = (input['query'] as String?)?.trim() ?? '';
    final limit = N1Tool.optionalInt(input, 'limit', fallback: 8).clamp(1, 30);

    final hits = await ctx.memory.search(query, limit: limit);
    if (hits.isEmpty) {
      return ToolResult.ok('没找到相关记忆。');
    }

    final buffer = StringBuffer();
    for (final e in hits) {
      final who = e.subject == null ? '' : '[${e.subject}] ';
      final when = formatDay(e.updatedAt);
      buffer.writeln(
        '${e.id}  ${when.isEmpty ? '' : '$when '}'
        '$who${e.content}  (${e.kind.name}, 重要度 ${e.importance})',
      );
    }
    return ToolResult.ok(buffer.toString().trimRight());
  }
}
