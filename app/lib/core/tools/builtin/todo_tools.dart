import '../../todo/todo_list.dart';
import '../n1_tool.dart';
import '../tool_context.dart';

/// 维护这次任务的分步清单。
///
/// 与 Claude Code 的 TodoWrite 同一套用法：模型每次发**完整清单**，覆盖旧的。
/// 不发增量。增量意味着"删哪条、改哪条"要靠 id，而模型记 id 经常记错，
/// 最后清单和现实对不上；整份覆盖最坏也只是多几个字。
class TodoWriteTool extends N1Tool {
  const TodoWriteTool();

  @override
  bool get runsInParallel => false;

  @override
  String get name => 'todo_write';

  @override
  String get description =>
      '维护这次任务的分步清单。**要办的事超过两步**（尤其是要调好几个工具、'
      '跑好几轮）时先用它把步骤写出来，让用户看得见进度。每次调用都发完整的'
      '清单，不是改动量。开始做某一步时把它标成 in_progress，做完立刻标成 '
      'completed——不要等全部做完再回头补。简单的一问一答不要用。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'todos': {
        'type': 'array',
        'description': '完整清单。传空数组等于清空。',
        'items': {
          'type': 'object',
          'properties': {
            'content': {'type': 'string', 'description': '这一步具体做什么'},
            'status': {
              'type': 'string',
              'enum': ['pending', 'in_progress', 'completed'],
            },
          },
          'required': ['content', 'status'],
        },
      },
    },
    'required': ['todos'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final raw = input['todos'];
    if (raw is! List) {
      return ToolResult.fail('todos 必须是数组，收到的是 ${raw.runtimeType}。');
    }

    final parsed = <TodoItem>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map<String, Object?>) {
        return ToolResult.fail('第 ${i + 1} 条不是对象。每条要有 content 和 status。');
      }
      final content = item['content'];
      if (content is! String) {
        return ToolResult.fail('第 ${i + 1} 条缺少 content。');
      }
      final status = TodoStatus.parse(item['status']);
      if (status == null) {
        return ToolResult.fail(
          '第 ${i + 1} 条的 status 是 `${item['status']}`，'
          '只能是 pending / in_progress / completed。',
        );
      }
      parsed.add(TodoItem(content: content.trim(), status: status));
    }

    final error = ctx.todos.replace(parsed);
    if (error != null) return ToolResult.fail(error);

    return ToolResult.ok(
      ctx.todos.render(),
      meta: {'total': ctx.todos.total, 'done': ctx.todos.doneCount},
    );
  }
}
