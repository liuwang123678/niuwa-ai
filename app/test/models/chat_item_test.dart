import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/models/chat_item.dart';

/// 盯 `AssistantItem.tools` 的**可变性**。
///
/// 这条看着像废话，但它是个真栽过的坑：`tools` 的默认值原来是 `const []`，
/// 而 `ChatProvider` 在流式过程中要 `item.tools.add(...)`。那句 add 抛
/// `Unsupported operation: Cannot add to an unmodifiable list`，而它发生在
/// **流事件回调里**——界面不报错、不崩，只是工具痕迹永远不出现。
///
/// 也就是说：**这个 App 里工具痕迹从来没有显示过**。用户说"模型从不主动用
/// 技能"——就算模型用了，他也永远看不见。这个 bug 能活这么久，正是因为它
/// 唯一的症状是"没有反应"：没有异常界面、没有红色文字、没有崩溃日志。
void main() {
  ToolTrace trace(String id, String name) =>
      ToolTrace(ToolCall(id: id, name: name, arguments: const {}));

  test('新建的 item 能往里加工具痕迹', () {
    final item = AssistantItem('a1');
    expect(() => item.tools.add(trace('c1', 'skill_read')), returnsNormally);
    expect(item.tools, hasLength(1));
  });

  test('每条消息各是各的列表，不串味', () {
    final a = AssistantItem('a1');
    final b = AssistantItem('b1');
    a.tools.add(trace('c1', 'skill_list'));
    expect(b.tools, isEmpty);
  });

  test('外面传进来的列表会被拷一份，之后外面改它不影响我们', () {
    // 重建历史时是拿着一个临时 list 构造的，那个 list 的生命周期不归 item 管。
    final outside = [trace('c1', 'get_time')];
    final item = AssistantItem('a1', tools: outside);
    outside.clear();
    expect(item.tools, hasLength(1));
  });

  test('有痕迹的 item 不算空——不能被"空 assistant 气泡不占位"那条吃掉', () {
    final item = AssistantItem('a1');
    expect(item.isEmpty, isTrue);
    item.tools.add(trace('c1', 'browser_open'));
    expect(item.isEmpty, isFalse);
  });
}
