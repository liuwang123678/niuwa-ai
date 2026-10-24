import 'dart:convert';

import '../llm/llm_client.dart';
import '../models/chat_message.dart';
import 'memory_store.dart';

/// 聊完一段之后，把值得留下的东西自动收进记忆。
///
/// 为什么要有它：记忆工具全靠模型自觉——它觉得该记才会调 `memory_save`。
/// 实际用下来，聊了半小时一句没记是常事，而下一次开新会话它就什么都不记得了。
/// 摘要是那道兜底：**不指望它每次都自觉，但一段对话总得留下点东西。**
///
/// 三条设计约束：
/// - **失败绝不抛**。摘要是后台动作，调不通模型、返回格式不对，最多是这次
///   没记住，绝不能影响用户正在看的对话。
/// - **不覆盖、不删除**。写进去的每条都走 `saveSmart`，跟聊天里手动记的
///   共用同一套去重规则。
/// - **宁可少写**。模型一次给三条以上就只取前三条；内容不合格的整条丢掉。
///   记忆库被一堆"用户和助手进行了友好的交流"灌满是不可接受的。
class MemorySummarizer {
  const MemorySummarizer({required this.llm, required this.memory});

  final LlmClient llm;
  final MemoryStore memory;

  /// 对话太长时只把后半段发给模型。摘要是"这段时间聊了什么"，
  /// 开头几百字对结果影响很小，而 token 是实打实的钱。
  static const int maxTranscriptChars = 6000;

  /// 一次最多收几条。多了等于把整段对话抄进记忆库。
  static const int maxEntries = 3;

  static const String _systemPrompt =
      '你是一个记忆整理器。阅读下面这段对话，挑出**值得长期记住**的信息：'
      '用户的偏好、身份、在做的事、重要的人和日期、明确说过的结论。\n'
      '不要总结聊天过程，不要记"用户问了一个问题"这种话。\n'
      '只输出 JSON 数组，不要任何解释、不要代码块标记。格式：\n'
      '[{"content":"一句话，站在第三人称写","kind":"fact|preference|event|relation|summary",'
      '"subject":"关于谁/关于什么","importance":1到5的整数}]\n'
      '没有值得记的就输出 []。最多 3 条，每条不超过 60 个字。';

  /// 返回这次真正存进去（或合并进旧记忆）的条数。
  Future<int> summarize(List<ChatMessage> messages) async {
    final transcript = buildTranscript(messages);
    if (transcript.trim().isEmpty) return 0;

    final buffer = StringBuffer();
    try {
      await for (final chunk in llm.stream([
        ChatMessage.system(_systemPrompt),
        ChatMessage.user(transcript),
      ])) {
        if (chunk is TextChunk) buffer.write(chunk.text);
      }
    } catch (_) {
      // 网络断了、额度没了、模型挂了——都只当这次没摘要。
      return 0;
    }

    final items = parseSummary(buffer.toString());
    var saved = 0;
    for (final item in items) {
      try {
        await memory.saveSmart(
          MemoryEntry.create(
            kind: MemoryKind.parse(item.kind),
            content: item.content,
            subject: item.subject,
            importance: item.importance,
            now: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        saved++;
      } catch (_) {
        // 一条写不进去不该连累剩下的。
      }
    }
    return saved;
  }

  /// 把对话压成"用户/助手：…"的纯文本，只留后半段。
  static String buildTranscript(List<ChatMessage> messages) {
    final lines = <String>[];
    for (final m in messages) {
      final text = m.content.trim();
      if (text.isEmpty) continue;
      final who = switch (m.role) {
        Role.user => '用户',
        Role.assistant => '助手',
        Role.system => null,
        Role.tool => null,
      };
      if (who == null) continue;
      lines.add('$who：$text');
    }

    // 从后往前攒，攒够字数就停——这样保住的永远是最近发生的事。
    final kept = <String>[];
    var total = 0;
    for (final line in lines.reversed) {
      if (total + line.length > maxTranscriptChars) break;
      kept.insert(0, line);
      total += line.length;
    }
    return kept.join('\n');
  }

  /// 从模型输出里抠出 JSON 数组。
  ///
  /// 模型经常不听话：包个 ```json 围栏、前面加一句"好的"、或者给个对象
  /// 而不是数组。这里能容忍前两种，第三种直接当空——**猜错会往记忆里写垃圾**，
  /// 不如不写。
  static List<SummaryItem> parseSummary(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];

    Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];

    final out = <SummaryItem>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final content = (item['content'] as String?)?.trim() ?? '';
      if (content.isEmpty || content.length > 200) continue;

      final rawKind = item['kind'] as String?;
      if (rawKind != null && !MemoryKind.values.any((k) => k.name == rawKind)) {
        continue;
      }

      final importance = switch (item['importance']) {
        final int v => v.clamp(1, 5),
        final num v => v.round().clamp(1, 5),
        _ => 3,
      };

      out.add(
        SummaryItem(
          content: content,
          kind: rawKind ?? MemoryKind.fact.name,
          subject: (item['subject'] as String?)?.trim(),
          importance: importance,
        ),
      );
      if (out.length >= maxEntries) break;
    }
    return out;
  }
}

class SummaryItem {
  const SummaryItem({
    required this.content,
    required this.kind,
    this.subject,
    this.importance = 3,
  });

  final String content;
  final String kind;
  final String? subject;
  final int importance;
}

/// 什么时候该做一次摘要。
///
/// 规则就一句：**聊够 [after] 轮才开始，之后每 [every] 轮一次，一次会话最多
/// [maxRuns] 次。** 太勤会显得它一直在后台偷偷跑；太懒则一整个会话下来
/// 什么都没留下。
///
/// 单独一个类是为了能测。这些全是"第几轮"的算术，写错的表现只有两种——
/// 永远不摘要，或者每句话都摘要——**两种在界面上都看不出来**，
/// 只能靠数轮次验证。
class SummarySchedule {
  SummarySchedule({this.after = 10, this.every = 8, this.maxRuns = 3});

  final int after;
  final int every;
  final int maxRuns;

  int _turns = 0;
  int _lastAt = 0;
  int _runs = 0;

  /// 已经过去的轮数。给测试和日志看的。
  int get turns => _turns;

  /// 已经做了几次摘要。
  int get runs => _runs;

  /// 一轮对话结束了。返回 true 表示**现在**该派一次摘要。
  bool tick() {
    _turns++;
    if (_turns < after) return false;
    if (_turns - _lastAt < every) return false;
    if (_runs >= maxRuns) return false;
    _lastAt = _turns;
    _runs++;
    return true;
  }

  /// 新会话从头数。
  void reset() {
    _turns = 0;
    _lastAt = 0;
    _runs = 0;
  }
}
