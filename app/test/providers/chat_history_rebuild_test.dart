import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/models/chat_item.dart';
import 'package:niuwa_ai/providers/chat_provider.dart';

/// 盯「重启之后还看不看得见工具痕迹」。
///
/// 为什么这件事值得单独一个文件：它是**「模型到底用没用技能」唯一的验证手段**。
/// 之前 `load()` 重建 assistant 时只带 text 和 reasoning，于是工具痕迹在重启
/// 之后全部消失——你没有别的办法回头看它上一条到底读没读技能、开没开网页，
/// 于是"模型不主动用技能"这件事既无法证伪也无法验证。reasoning 反倒留着，
/// 这个不对称一直没人注意。
ChatMessage userMsg(String id, String text) => ChatMessage.user(text);
// 用指定 id 造消息，方便和 tool_call_id 对上。

ChatMessage assistantWithCall(String callId, String toolName, String argsJson) =>
    ChatMessage.assistant(
      '',
      toolCalls: [
        ToolCall(
          id: callId,
          name: toolName,
          arguments: ToolCall.decodeArguments(argsJson),
        ),
      ],
    );

ChatMessage toolResult(String callId, String toolName, String content) =>
    ChatMessage.toolResult(
      toolCallId: callId,
      toolName: toolName,
      content: content,
    );

void main() {
  group('重建历史', () {
    test('assistant 的工具调用和它的结果配成一条痕迹', () {
      final items = ChatProvider.rebuildItems([
        userMsg('u1', '帮我查一下'),
        assistantWithCall('c1', 'skill_read', '{"name":"web-research"}'),
        toolResult('c1', 'skill_read', '# Web Research\n流程如下…'),
        ChatMessage.assistant('查到了'),
      ]);

      // tool 消息不单独占一条——内容挂在痕迹上，再画一遍是重复。
      expect(items, hasLength(3));
      expect(items[0], isA<UserItem>());

      final a = items[1] as AssistantItem;
      expect(a.tools, hasLength(1));
      expect(a.tools.single.call.name, 'skill_read');
      expect(a.tools.single.result, isNotNull, reason: '结果是空的会一直转圈');
      expect(a.tools.single.ok, isTrue);
      expect(a.tools.single.result!.content, contains('流程如下'));

      expect(items[2], isA<AssistantItem>());
    });

    test('这是「重启后还看得见它读过技能」的那条链', () {
      // 用户报的是「模型从不主动用技能」。要能验证这件事，就必须在重启之后
      // 还能看到 `读技能` 这一条。
      final items = ChatProvider.rebuildItems([
        userMsg('u1', '查查那个手机'),
        assistantWithCall('c1', 'skill_list', '{}'),
        toolResult('c1', 'skill_list', '- web-research：查资料'),
        assistantWithCall('c2', 'skill_read', '{"name":"web-research"}'),
        toolResult('c2', 'skill_read', '…'),
      ]);

      final names = items
          .whereType<AssistantItem>()
          .expand((a) => a.tools)
          .map((t) => t.call.name)
          .toList();
      expect(names, ['skill_list', 'skill_read']);
    });

    test('失败的调用重建出来还是失败，不会变成成功', () {
      // 存进库的是 `ToolResult.toModelText()` 的结果，不存 ok。重建要靠前缀
      // 把 ok 认回来——认不出来的话，界面上会把一次失败画成一个绿勾，
      // 那正是「它说做了其实没做」这一类误读。
      final items = ChatProvider.rebuildItems([
        assistantWithCall('c1', 'browser_open', '{"url":"https://a.com"}'),
        toolResult('c1', 'browser_open', '工具执行失败：打不开这个网址：超时'),
      ]);

      final trace = (items.single as AssistantItem).tools.single;
      expect(trace.ok, isFalse);
      expect(trace.result!.content, '打不开这个网址：超时', reason: '前缀要剥掉');
    });

    test('并行调用各配各的，不按顺序乱点鸳鸯', () {
      // 模型一次能发好几个调用，结果回来的顺序不保证。按顺序配对会错位。
      final items = ChatProvider.rebuildItems([
        ChatMessage.assistant(
          '',
          toolCalls: [
            ToolCall(id: 'a', name: 'get_time', arguments: const {}),
            ToolCall(id: 'b', name: 'memory_search', arguments: const {}),
          ],
        ),
        // **倒着**回来
        toolResult('b', 'memory_search', '找到两条'),
        toolResult('a', 'get_time', '2026-10-10'),
      ]);

      final tools = (items.single as AssistantItem).tools;
      expect(tools, hasLength(2));
      expect(tools[0].call.name, 'get_time');
      expect(tools[0].result!.content, '2026-10-10');
      expect(tools[1].call.name, 'memory_search');
      expect(tools[1].result!.content, '找到两条');
    });

    test('结果没留下来时也不能留空——留空界面上会一直转圈', () {
      // `ToolTrace.running` 的定义就是 `result == null`。
      final items = ChatProvider.rebuildItems([
        assistantWithCall('c1', 'browser_snapshot', '{}'),
        // 结果那条没写进库（写到一半被杀掉之类）
      ]);

      final trace = (items.single as AssistantItem).tools.single;
      expect(trace.running, isFalse);
      expect(trace.ok, isFalse);
      expect(trace.result!.content, contains('没留在记录里'));
    });

    test('工具调用的参数也重建出来了，不是空的', () {
      final items = ChatProvider.rebuildItems([
        assistantWithCall('c1', 'browser_type', '{"ref":"13","text":"牛蛙"}'),
        toolResult('c1', 'browser_type', '已填入'),
      ]);

      final args = (items.single as AssistantItem).tools.single.call.arguments;
      expect(args['ref'], '13');
      expect(args['text'], '牛蛙');
    });

    test('没调工具的 assistant 不会被塞上痕迹', () {
      final items = ChatProvider.rebuildItems([ChatMessage.assistant('就聊聊天')]);
      expect((items.single as AssistantItem).tools, isEmpty);
    });

    test('system 消息不进界面', () {
      final items = ChatProvider.rebuildItems([
        ChatMessage.system('你是牛蛙'),
        userMsg('u1', '在吗'),
      ]);
      expect(items, hasLength(1));
      expect(items.single, isA<UserItem>());
    });

    test('只有思考过程没有正文的那条要留着', () {
      // 不留的话，用户记得当时屏幕上明明有内容，重启后变成一个空气泡。
      final items = ChatProvider.rebuildItems([
        ChatMessage.assistant('', reasoning: '我在想'),
      ]);
      expect(items, hasLength(1));
      expect((items.single as AssistantItem).reasoning, '我在想');
    });

    test('空的 assistant 气泡不占位', () {
      final items = ChatProvider.rebuildItems([ChatMessage.assistant('')]);
      expect(items, isEmpty);
    });

    test('提醒响过留下的那条，重启后还带着"提醒"标记', () {
      // 不标的话，用户第二天打开会以为 N1 无缘无故自己说了一句话。
      final items = ChatProvider.rebuildItems([
        ChatMessage.assistant(
          '该交作业了',
          origin: MessageOrigin.reminder,
        ),
      ]);

      expect(items, hasLength(1));
      final item = items.single as AssistantItem;
      expect(item.text, '该交作业了');
      expect(item.fromReminder, isTrue);
    });
  });
}
