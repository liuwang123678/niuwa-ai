/// 任务清单里一条的状态。
///
/// 只有三种，刻意不做一个 `blocked`（被什么卡住了）之内的小状态：
/// 模型自己判断"卡住"经常是在逃避下一步，宁可让它老老实实写 `pending`。
enum TodoStatus {
  pending,
  inProgress,
  completed;

  /// 从模型给的字符串认回来。认不出返回 null——**不猜**。
  static TodoStatus? parse(Object? raw) {
    return switch (raw) {
      'pending' => TodoStatus.pending,
      'in_progress' => TodoStatus.inProgress,
      'completed' => TodoStatus.completed,
      _ => null,
    };
  }

  String get wire => switch (this) {
    TodoStatus.pending => 'pending',
    TodoStatus.inProgress => 'in_progress',
    TodoStatus.completed => 'completed',
  };

  String get icon => switch (this) {
    TodoStatus.pending => '☐',
    TodoStatus.inProgress => '▶',
    TodoStatus.completed => '☑',
  };
}

class TodoItem {
  const TodoItem({required this.content, required this.status});

  final String content;
  final TodoStatus status;
}

/// 这次会话的任务清单。
///
/// 挂在 [ToolContext] 上，跟着会话走：新对话从空开始，旧对话的清单不串过来。
/// 淘汰策略也不是做一个"任务系统"——模型每轮发完整清单，这里整份换掉，
/// 没有增量同步那一堆容易对不上的状态。
class TodoList {
  TodoList({this.maxItems = 30});

  final int maxItems;

  final List<TodoItem> _items = [];

  List<TodoItem> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  int get total => _items.length;

  int get doneCount =>
      _items.where((i) => i.status == TodoStatus.completed).length;

  TodoItem? get current {
    for (final item in _items) {
      if (item.status == TodoStatus.inProgress) return item;
    }
    return null;
  }

  /// 整份替换。校验不过就**原样不动**并返回一句给人看的话。
  ///
  /// 为什么要校验而不是"尽力接受"：一份有两个 `in_progress` 的清单，
  /// 模型自己下一次读的时候也分不清该做哪个；超过上限的清单会把 system
  /// prompt 和工具结果一起撑大。让它在错误里看到原因并重发，比存一份坏的强。
  String? replace(List<TodoItem> next) {
    if (next.length > maxItems) {
      return '清单最多 $maxItems 条，这次给了 ${next.length} 条。拆小一点，'
          '只保留这次真正要做的步骤。';
    }

    final active = next.where((i) => i.status == TodoStatus.inProgress).length;
    if (active > 1) {
      return '同时只能有 1 条 in_progress，这次给了 $active 条。'
          '把真正在做的那个标成 in_progress，其余写 pending。';
    }

    for (final item in next) {
      if (item.content.trim().isEmpty) {
        return '有一条 content 是空的。每一步都要写清楚做什么。';
      }
    }

    _items
      ..clear()
      ..addAll(next);
    return null;
  }

  void clear() => _items.clear();

  /// 渲染给模型看。模型每轮都看到这份清单，就知道自己走到哪了。
  String render() {
    if (_items.isEmpty) return '清单已清空。';

    final buffer = StringBuffer()
      ..writeln('任务清单（$doneCount/$total 完成）');
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      final icon = item.status.icon;
      final content = item.content;
      final suffix = item.status == TodoStatus.inProgress ? '  ← 正在做' : '';
      buffer.writeln('${i + 1}. $icon $content$suffix');
    }
    return buffer.toString().trimRight();
  }
}
