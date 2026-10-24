/// 「聊久了别把前半场忘掉」。
///
/// ## 它解决的是哪件事
///
/// 历史要么被工作强度的条数上限砍掉（`WorkLevel.historyMessages`），要么
/// 撞上输入预算被 `AgentLoop.fitToBudget` 丢掉最老的一段。两条路都**只减不补**
/// ——聊到第 60 句时，第一句说的事就真的没了。
///
/// 这一层把"正要被丢掉的那一段"先交给模型压成一段摘要，下一轮挂在 system
/// prompt 后面带着走。丢的是细节，留下的是"我们在做什么、做到哪了"。
///
/// ## 三条约束
///
/// - **失败只当没发生。** 摘要跑在后台，模型调不通、返回空、超时，最多是
///   这一次没压成，绝不能影响用户正在看的对话。旧摘要还在就继续用旧的。
/// - **只压用户发言边界之间的一整段。** 从中间切会把一条 tool 结果和它的
///   "爸爸"分开，那段历史发出去会被 `sanitizeHistory` 当孤儿丢掉——摘要说
///   "这段我收下了"，实际却少了半截。
/// - **有上限。** 一次会话最多压 [DigestSchedule.maxRuns] 次：这个功能是
///   给长对话兜底的，不是每轮都多打一次模型。
library;

import '../llm/llm_client.dart';
import '../models/chat_message.dart';

/// 什么时候该压、压哪一段。纯逻辑，能单测。
class DigestSchedule {
  const DigestSchedule({
    this.keepRecent = 16,
    this.minNew = 12,
    this.maxRuns = 8,
  });

  /// 最近的这么多条**永远不进摘要**。它们还在上下文里，压了反而多绕一层。
  final int keepRecent;

  /// 一次至少压这么多条才值得多打一次模型。太少的话摘要成本高于收益。
  final int minNew;

  /// 一次会话最多压几次。到顶之后摘要会停在某个时刻，但后面的消息还在
  /// 历史里——不是丢了，只是不再往下压。
  final int maxRuns;

  /// 返回该压缩的区间 `[start, end)`；null = 这一轮不用压。
  ///
  /// [covered] 是"已经压到第几条"（`start` 永远从这里开始），[runs] 是本次
  /// 会话已经压过几次。
  (int, int)? plan(
    List<ChatMessage> messages, {
    required int covered,
    required int runs,
  }) {
    if (runs >= maxRuns) return null;
    if (covered < 0 || covered > messages.length) return null;
    if (messages.length - covered < keepRecent + minNew) return null;

    var end = messages.length - keepRecent;
    // 切点往前挪到一句用户发言上。往前而不是往后：往后可能一路走到末尾，
    // 那样就变成"一条都不压"，摘要永远建不起来。
    while (end > covered && messages[end].role != Role.user) {
      end--;
    }
    if (end <= covered) return null;
    if (end - covered < minNew) return null;
    return (covered, end);
  }
}

/// 把一段对话压成摘要。
///
/// 跟 `MemorySummarizer` 是两个东西，别合并：
/// - 后者产出**一条条结构化记忆**（谁、什么偏好），进记忆库；
/// - 这个产出**一段连续的叙事**（我们在做什么、做到哪了），只活在这次对话里。
///
/// 前者的每一条都要能被检索、去重、淘汰；后者只是"上一集剧情简介"。
class ConversationDigester {
  const ConversationDigester({required this.llm});

  final LlmClient llm;

  /// 摘要正文的字数上限。超了直接截——它每轮都挂在 system prompt 里，
  /// 一段两千字的"背景"比丢了它更伤。
  static const int maxChars = 1200;

  /// 送给模型的对话正文上限。
  static const int transcriptChars = 6000;

  /// 单条消息进正文时最多留多少字。工具结果动辄几千字，全塞进去等于
  /// 花了钱让模型读一遍它本来就不要的细节。
  static const int perMessageChars = 600;

  static const String _systemPrompt =
      '你是一个对话压缩器。把下面这段对话压成一段摘要，供助手之后继续对话时当背景用。\n'
      '必须保留：用户是谁、正在做什么、已经做过的决定和结论、还没做完的事、'
      '用户的偏好和称呼、重要的路径/名字/数字。\n'
      '不要保留：寒暄、重复的客套、工具调用的过程（只留结果）。\n'
      '如果给了「已有摘要」，把新内容合并进去，输出一份完整的新摘要，'
      '不要分「旧」「新」两段，也不要说"上次提到"。\n'
      '只输出摘要正文，不要标题、不要 JSON、不要代码块标记，不超过 400 字。';

  /// 返回合并后的新摘要；失败或没内容时返回 null（调用方保留旧摘要）。
  Future<String?> digest({
    String? previous,
    required List<ChatMessage> chunk,
  }) async {
    final transcript = buildTranscript(chunk);
    if (transcript.trim().isEmpty) return null;

    final buffer = StringBuffer();
    if (previous != null && previous.trim().isNotEmpty) {
      buffer
        ..writeln('已有摘要：')
        ..writeln(previous.trim())
        ..writeln()
        ..writeln('新增对话：');
    }
    buffer.write(transcript);

    final out = StringBuffer();
    try {
      await for (final event in llm.stream([
        ChatMessage.system(_systemPrompt),
        ChatMessage.user(buffer.toString()),
      ])) {
        if (event is TextChunk) out.write(event.text);
      }
    } catch (_) {
      // 网络、额度、模型挂了——这次不压，旧摘要继续用。
      return null;
    }

    return clean(out.toString());
  }

  /// 把模型吐出来的东西收拾成能直接挂进 prompt 的一段。
  ///
  /// 模型偶尔会无视"不要代码块标记"，包一层 ``` 回来。不剥的话那三个
  /// 反引号会进 system prompt，下一轮它可能学着继续写代码块。
  static String? clean(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('```')) {
      final firstBreak = text.indexOf('\n');
      if (firstBreak >= 0) text = text.substring(firstBreak + 1);
      if (text.endsWith('```')) text = text.substring(0, text.length - 3);
      text = text.trim();
    }
    if (text.isEmpty) return null;
    if (text.length > maxChars) {
      text = '${text.substring(0, maxChars)}…';
    }
    return text;
  }

  /// 拼给模型的正文。
  ///
  /// 超长时**两头都留**：中间省略。只留开头会丢掉"最近做到哪了"，只留结尾
  /// 会丢掉"这事一开始是怎么说的"——而摘要恰恰要回答后者。
  static String buildTranscript(List<ChatMessage> messages) {
    final lines = <String>[];
    for (final m in messages) {
      if (m.role == Role.system) continue;
      final text = m.content.trim();
      if (text.isEmpty) continue;
      final who = switch (m.role) {
        Role.user => '用户',
        Role.assistant => '助手',
        Role.tool => '工具结果',
        Role.system => '',
      };
      final body = text.length > perMessageChars
          ? '${text.substring(0, perMessageChars)}…'
          : text;
      lines.add('$who：$body');
    }

    final all = lines.join('\n');
    if (all.length <= transcriptChars) return all;

    final half = transcriptChars ~/ 2;
    return '${all.substring(0, half)}\n…（中间略）…\n'
        '${all.substring(all.length - half)}';
  }
}
