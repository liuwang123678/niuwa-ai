import 'dart:async';
import 'dart:convert';

import '../llm/llm_client.dart';
import '../memory/memory_store.dart';
import '../models/chat_message.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_context.dart';
import 'agent_event.dart';
import 'prompt_builder.dart';

/// 累积中的工具调用。
///
/// 协议要求：流式响应里 tool_call 是碎片，首块带 id + name，后续块只有
/// `arguments` 的字符串碎片。必须按 index 把碎片拼起来，拼完才是合法 JSON。
class _PendingCall {
  _PendingCall(this.index);

  final int index;
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  void absorb(ToolCallChunk chunk) {
    if (chunk.id != null) id = chunk.id;
    if (chunk.name != null) name = chunk.name;
    if (chunk.argumentsFragment != null) {
      arguments.write(chunk.argumentsFragment);
    }
  }

  ToolCall toToolCall() => ToolCall(
    id: id ?? 'call_$index',
    name: name ?? '',
    arguments: ToolCall.decodeArguments(arguments.toString()),
  );
}

/// agent 主循环。
///
/// 一次 [run] = 用户发一句话到 N1 说完为止，中间可能穿插任意多次工具调用。
class AgentLoop {
  AgentLoop({
    required this.llm,
    required this.tools,
    required this.context,
    required this.promptBuilder,
    this.maxTurns = 8,
    this.maxInputTokens = 96000,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LlmClient llm;
  final ToolRegistry tools;
  final ToolContext context;
  final PromptBuilder promptBuilder;

  /// 注入"现在几点"用的时钟。测试里换成固定值，就能断言注入的位置和格式。
  final DateTime Function() _clock;

  /// 单次请求的输入预算（估算值）。超过就先压缩再发。
  ///
  /// 这不是"省 token"的旋钮——工作强度才管那个。这是**兜底**：真超了上下文
  /// 上限，上游会回一句 `context length exceeded`，整轮直接废掉，用户之前
  /// 聊的、跑的全白费。裁掉一点老内容，总比一个字都发不出去强。
  ///
  /// 默认 96k 是冲着主流国内模型（128k 左右）留的余量。本地小模型只有 8k
  /// 的话，靠这里救不了，得用户自己配一个更小的 [maxInputTokens]
  /// ——但那属于"选了个小模型"，报错本身是如实的。
  final int maxInputTokens;

  /// 一轮对话里最多让模型"思考 + 调工具"几次。
  /// 防的是模型陷入"调工具 → 不满意 → 再调"的死循环，那会烧钱。
  ///
  /// **不是 final**：浏览器任务天然要更多回合（一次 open/click/看页面就是
  /// 一轮），而浏览器是**会话建好之后**才就绪的——那时候 `AgentLoop` 早就
  /// 构造完了。8 轮会被一个普通的网页任务吃满，然后停在最要紧的那一步。
  /// 所以让 [N1Session.installBrowserTools] 能把它调大。
  int maxTurns;

  /// 把历史修成协议合法的样子再发出去。
  ///
  /// **这是防线，不是根因修复。** 根因是排序：消息表原本按 `created_at` 排，
  /// 而它只有毫秒精度，同一轮产生的 `assistant(带 tool_calls)` 和紧跟的
  /// `tool` 结果必然同毫秒，于是排序退回到 id 兜底——id 的尾巴是 6 位随机数，
  /// 同微秒时纯抛硬币。掷输的那一次，tool 结果排到了它爸爸前面。
  /// 根因已由 `messages.seq`（单调写入序号）修掉。
  ///
  /// 这一层防的是别的事：**万一**库里再出现不自洽的历史（用户导入、手改、
  /// 旧版本写坏、以后新加的功能有 bug），后果应该是"少一段上下文"，
  /// 而不是"整个对话永久废掉"。上游的原话一点都不含糊：
  ///
  ///   HTTP 400: Messages with role 'tool' must be a response to a
  ///             preceding message with 'tool_calls'
  ///
  /// 三条规则：
  ///   1. 前面没有声明过这个 `tool_call_id` 的 tool 消息 → 丢；
  ///   2. `tool_call_id` 为 null 的 tool 消息 → 丢
  ///      （`toWire()` 会把 null 原样吐出去，上游看到的是个没归属的结果）；
  ///   3. assistant 声明的 `tool_calls` 里没等到结果的那几个 → 剥掉，
  ///      一个都不剩就把整个 `tool_calls` 置空。
  ///
  /// **只看前面**：一条 tool 只认在它之前出现过的声明。声明在它后面的照样算
  /// 孤儿——那正是排序颠倒时的样子，也正是要清掉的那种。
  ///
  /// 只丢不合法的那些行，其余历史原样保留：一条坏行不该让用户整段对话失忆。
  static List<ChatMessage> sanitizeHistory(List<ChatMessage> history) {
    // 第一遍：认下合法配对，顺手把孤儿 tool 挑出去。
    //
    // 两个集合缺一不可：`declared` 是"走到当前位置为止声明过的"，
    // `answered` 是"已经有结果回来的"。合成一个的话，第二遍就没法区分
    // "声明了但没结果"（要剥掉）和"声明了也有结果"（要留着）。
    final declared = <String>{};
    final answered = <String>{};
    final kept = <ChatMessage>[];

    for (final m in history) {
      if (m.role == Role.tool) {
        final id = m.toolCallId;
        // 规则 1、2。声明在**后面**的也算孤儿——此刻 declared 里还没有它，
        // 而这正是"顺序被排颠倒了"的样子。
        if (id == null || !declared.contains(id)) continue;
        answered.add(id);
        kept.add(m);
      } else {
        if (m.role == Role.assistant && m.toolCalls != null) {
          for (final c in m.toolCalls!) {
            declared.add(c.id);
          }
        }
        kept.add(m);
      }
    }

    // 第二遍：把没等到结果的声明拆掉。
    for (var i = 0; i < kept.length; i++) {
      final m = kept[i];
      if (m.role != Role.assistant || m.toolCalls == null) continue;
      final live = [
        for (final c in m.toolCalls!)
          if (answered.contains(c.id)) c,
      ];
      if (live.length == m.toolCalls!.length) continue; // 全都有结果，别动
      kept[i] = m.withToolCalls(live.isEmpty ? null : live);
    }
    return kept;
  }

  /// 按上限砍掉太老的一段历史。[limit] 为 null 表示不限，原样返回。
  ///
  /// 这是工作强度里的省 token 旋钮之一（`WorkLevel.historyMessages`），
  /// 和 [sanitizeHistory] 是一对：**一个管少带点，一个管带得合法**。
  ///
  /// ## 窗口一定要落在"一句用户输入"上
  ///
  /// 从中间硬切的话，切点后面往往紧跟一条 `tool` 结果，而它的"爸爸"
  /// （那条带 `tool_calls` 的 assistant）正好被切掉了。这种孤儿会被
  /// [sanitizeHistory] 丢掉，于是**实际带的历史比设定的还少**，而且少得没规律
  /// ——调这个旋钮的人会发现"调到 40 条怎么比 30 条记得还少"。
  ///
  /// 所以从切点**往前**找到最近的一句用户输入，从那儿开始带。往前找而不是
  /// 往后找，是因为往后找在"一长串工具调用"里可能一路走到末尾，那样就变成
  /// 一句历史都不带了——比多带点糟得多。往前找最坏的结果是**多带**一段
  /// （切点前面正好是一整个长任务），那是安全的方向。
  static List<ChatMessage> trimHistory(
    List<ChatMessage> history,
    int? limit,
  ) {
    // limit <= 0 当成"不限"而不是"一条都不带"：一个说"带 0 条"的配置项
    // 只会是写错了，按字面执行的话模型会凭空失忆。
    if (limit == null || limit <= 0) return history;
    if (history.length <= limit) return history;

    var start = history.length - limit;
    while (start > 0 && history[start].role != Role.user) {
      start--;
    }
    return history.sublist(start);
  }

  /// 写给模型的"现在"。
  ///
  /// 格式故意压得很短：它每一轮都要重发一次（拼在最后一条用户消息里），
  /// 多一个装饰字都是白烧的 token。
  static String clockLine(DateTime now) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final w = weekdays[now.weekday - 1];
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return '（现在是 ${now.year} 年 ${now.month} 月 ${now.day} 日 星期$w $hh:$mm）';
  }

  /// 按话题现捞出来的旧记忆，拼成一段附在**最后一条用户消息**末尾。
  ///
  /// 为什么不塞进 system prompt：那份索引是固定按重要度取的（缓存友好），
  /// 而这一份是**跟着用户这句话现查的**——每句话都可能不一样。写进 system
  /// prompt 等于每轮把整段历史的缓存作废，为了几行字付整段对话的钱。
  ///
  /// 也不放在用户原话前面：那样会插进「用户在说什么」和「它想回什么」中间，
  /// 读起来像是用户自己补的一句。放末尾，语义上是"顺带想起来的"。
  static String recallBlock(List<MemoryEntry> entries, {int max = 8}) {
    final lines = <String>[];
    for (final e in entries.take(max)) {
      var line = e.toIndexLine();
      if (line.length > 120) line = '${line.substring(0, 120)}…';
      lines.add(line);
    }
    if (lines.isEmpty) return '';
    return '\n\n（这些是以前记下的、跟你这句话有关的事。不一定都还用得上，'
        '自己判断——别当成任务清单：\n${lines.join('\n')}\n）';
  }

  /// 把压缩过的前半场挂到 system prompt 末尾。
  ///
  /// 空摘要原样返回，一个字都不加——没压缩过的人看到的 prompt 跟以前完全一样。
  static String _withSummary(String systemPrompt, String? summary) {
    final digest = summary?.trim() ?? '';
    if (digest.isEmpty) return systemPrompt;
    return '$systemPrompt\n\n# 更早的对话\n\n'
        '（这段对话更早的部分已经压缩成下面这段，细节不在上下文里了。'
        '需要具体内容就查记忆、翻文件，或者直接问用户。）\n\n'
        '$digest';
  }

  /// 把"现在几点了"和"跟这句话相关的旧记忆"拼进**最后一条用户消息**。
  ///
  /// 为什么不放 system prompt：缓存按**前缀**命中，而 system prompt 是整段
  /// 历史的前缀。时间写在那儿，每分钟变一次，等于每分钟把整段对话的缓存
  /// 全部作废。放到末尾的这条消息里，变的是最后一个 token 之后的部分，
  /// 前面的历史照旧命中。相关记忆同理——它每句话都在变。
  ///
  /// 返回新列表：`messages` 是这一轮的真相，注入只影响"发什么"。
  List<ChatMessage> _decorate(
    List<ChatMessage> messages,
    List<MemoryEntry> recalled,
  ) {
    var index = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == Role.user) {
        index = i;
        break;
      }
    }
    // 一条用户消息都没有（几乎不可能）就跳过，不为一行时间破坏一轮对话。
    if (index < 0) return messages;

    final original = messages[index];
    final buffer = StringBuffer()
      ..writeln(clockLine(_clock()))
      ..write(original.content);
    final recall = recallBlock(recalled);
    if (recall.isNotEmpty) buffer.write(recall);

    final out = List<ChatMessage>.of(messages);
    out[index] = original.copyWith(content: buffer.toString());
    return out;
  }

  /// 估算这些消息会占多少 token。
  ///
  /// 手上没有 tokenizer（各家分词不同，也不值得为此往安装包里塞几 MB 词表），
  /// 只能按字符数拍。中文一字约 0.6 token、英文一字符约 0.3 token，这里
  /// **一律按 0.6/字** 算——宁可高估。高估的代价是早一点裁掉老内容，
  /// 低估的代价是请求被上游一句 `context length exceeded` 打回。
  static int estimateTokens(Iterable<ChatMessage> messages) =>
      messages.fold(0, (sum, m) => sum + _estimateOne(m));

  static int _estimateOne(ChatMessage m) {
    var chars = m.content.length;
    for (final call in m.toolCalls ?? const <ToolCall>[]) {
      chars += call.name.length + jsonEncode(call.arguments).length;
    }
    // 每条消息有几个 token 的结构开销；图片按一张 1600 估，这是低分辨率的
    // 常见值，分辨率越高只会越贵。
    return (chars * 0.6).ceil() + 4 + m.images.length * 1600;
  }

  /// 把消息压到 [budget] 以内。没超就原样返回，不做无谓拷贝。
  ///
  /// 两步，从轻到重：
  ///
  /// 1. **只压缩老的工具结果正文**，消息一条不删。协议要求 tool 消息必须有
  ///    个带 `tool_calls` 的 assistant 爸爸，整条删掉会连带把爸爸的声明剥掉
  ///    ——那是拆承重墙。换掉正文，结构完好。
  /// 2. 还不够就按**用户发言**为界整段丢最老的一段。绝不在一段中间切，
  ///    理由和 [trimHistory] 一样：切点后面往往紧跟 tool 结果，它的爸爸被
  ///    切掉的话，[sanitizeHistory] 会把它当孤儿丢掉。
  ///
  /// 最近的 [keepRecent] 条一律不动：那是模型眼下最需要的东西，
  /// 压它等于让它忘了自己刚刚在干什么。
  static List<ChatMessage> fitToBudget(
    List<ChatMessage> messages, {
    required int budget,
    int keepRecent = 8,
  }) {
    if (budget <= 0) return messages;
    var total = estimateTokens(messages);
    if (total <= budget) return messages;

    final out = List<ChatMessage>.of(messages);
    final recentStart = out.length - keepRecent;

    // 第一步：老的工具结果正文换成一行说明。
    for (var i = 0; i < recentStart && total > budget; i++) {
      final m = out[i];
      if (m.role != Role.tool || m.content.length <= 200) continue;
      final before = _estimateOne(m);
      final compressed = m.copyWith(
        content: '（这条工具结果早先已经给过你，为了省上下文略去了，原文 '
            '${m.content.length} 字）',
      );
      out[i] = compressed;
      total -= before - _estimateOne(compressed);
    }

    // 第二步：从最老的整段丢，切点必须落在用户发言上。
    // system 永远留着——它是这一轮的全部身份和规矩。
    final head = out.isNotEmpty && out.first.role == Role.system ? 1 : 0;
    var start = head;
    while (total > budget) {
      var next = start + 1;
      while (next < out.length && out[next].role != Role.user) {
        next++;
      }
      // 只剩最后一段就别丢了：再丢会把用户这次说的话也扔掉。
      if (next >= out.length) break;
      for (var i = start; i < next; i++) {
        total -= _estimateOne(out[i]);
      }
      start = next;
    }

    if (start == head) return out;
    return [
      if (head == 1) out.first,
      ...out.sublist(start),
    ];
  }

  /// 跑一轮。
  ///
  /// [history] 是之前的所有消息（**不含 system**，system 由 [promptBuilder] 现拼）。
  /// [input] 是用户这次说的话。
  /// [recalled] 是调用方按**这一句话**现查出来的旧记忆。
  ///
  /// [conversationSummary] 是太长之后被压缩掉的前半场。它**进 system prompt**，
  /// 因为那是"整段对话的背景"，不是某一句的补充；代价是摘要一变、这一段之后
  /// 的缓存就作废——而摘要每几十条消息才更新一次，这个代价是划算的。
  /// 反过来把它塞进最后一条用户消息，就等于模型每次只看得到"最近这一句的
  /// 背景"，多轮工具调用时它就忘了自己前面在干什么。
  Stream<AgentEvent> run({
    required List<ChatMessage> history,
    required ChatMessage input,
    List<MemoryEntry> recalled = const [],
    String? conversationSummary,
  }) async* {
    final String systemPrompt;
    try {
      systemPrompt = _withSummary(
        await promptBuilder.build(
          toolNames: tools.specs.map((s) => s.name),
        ),
        conversationSummary,
      );
    } catch (e) {
      yield AgentFailed('准备上下文失败：$e', error: e);
      return;
    }

    final messages = <ChatMessage>[
      ChatMessage.system(systemPrompt),
      ...sanitizeHistory(history),
      input,
    ];
    final produced = <ChatMessage>[input];

    for (var turn = 0; turn < maxTurns; turn++) {
      yield TurnStarted(turn, isContinuation: turn > 0);

      final content = StringBuffer();
      final reasoning = StringBuffer();
      final pending = <int, _PendingCall>{};
      String? finishReason;

      // 发之前过一遍预算。裁的是副本，`messages` 本身完整留着——
      // 界面上和存进库里的记录一个字都不该因为"上下文不够"而变少。
      final visible = fitToBudget(messages, budget: maxInputTokens);
      if (!identical(visible, messages)) {
        yield ContextTrimmed(
          droppedMessages: messages.length - visible.length,
          approxTokens: estimateTokens(visible),
        );
      }
      final stream = llm.stream(
        _decorate(visible, recalled),
        tools: tools.specs,
      );
      // 注意：`await for` 本身不能挂 `on ... catch`，错误处理要包一层 try。
      try {
        await for (final chunk in stream) {
          switch (chunk) {
            case TextChunk(:final text):
              content.write(text);
              yield TextDelta(text);
            case ReasoningChunk(:final text):
              reasoning.write(text);
              yield ReasoningDelta(text);
            case ToolCallChunk():
              pending
                  .putIfAbsent(chunk.index, () => _PendingCall(chunk.index))
                  .absorb(chunk);
            case UsageChunk():
              yield UsageReported(chunk);
            case DoneChunk(finishReason: final fr):
              // 别把模式变量也命名成 finishReason——会遮蔽外层那个，赋值等于白做
              finishReason = fr ?? finishReason;
          }
        }
      } on LlmException catch (e) {
        yield AgentFailed(e.message, error: e);
        return;
      } catch (e) {
        yield AgentFailed('请求模型时出错：$e', error: e);
        return;
      }

      final calls = (pending.values.toList()
            ..sort((a, b) => a.index.compareTo(b.index)))
          .map((p) => p.toToolCall())
          .where((c) => c.name.isNotEmpty)
          .toList();

      final assistant = ChatMessage.assistant(
        content.toString(),
        toolCalls: calls.isEmpty ? null : calls,
        reasoning: reasoning.isEmpty ? null : reasoning.toString(),
      );
      messages.add(assistant);
      produced.add(assistant);
      yield TurnComplete(assistant);

      if (calls.isEmpty) {
        yield RunComplete(
          produced: produced,
          // 撞上长度上限要如实报出来，否则用户会以为话说完了
          stopReason: finishReason == 'length' ? 'length' : 'stop',
        );
        return;
      }

      // 分批执行：连续的一串"只读且不需要审批"的工具同时跑，其余串行。
      //
      // 并行只影响**执行**，不影响消息顺序：结果按 calls 的原顺序回填，
      // 因为协议要求 tool 消息和 assistant 的 tool_calls 一一对应。模型
      // 一次发三个 `read_file` 时，三个同时读，但回给它的顺序还是它写的顺序。
      for (final batch in _batchCalls(calls)) {
        if (batch.length == 1) {
          final call = batch.single;
          yield ToolCallStarted(call);
          final invocation = await tools.invoke(call, context);
          yield ToolCallFinished(invocation);
          _appendToolResult(messages, produced, invocation);
          continue;
        }

        // 先把"开始"全发出去，界面会同时显示几条转圈——这是如实的：
        // 它们确实在同时跑。
        for (final call in batch) {
          yield ToolCallStarted(call);
        }

        final invocations = await Future.wait(
          batch.map((call) => tools.invoke(call, context)),
        );
        for (final invocation in invocations) {
          yield ToolCallFinished(invocation);
          _appendToolResult(messages, produced, invocation);
        }
      }
    }

    yield RunComplete(produced: produced, stopReason: 'max_turns');
  }

  /// 把一次模型返回的工具调用分组。
  ///
  /// 连续的一段"可并行"调用合成一批，其余单个一组。**不跨过有副作用的调用
  /// 去合并**——否则「读 A → 写 B → 读 A」里的两个读会跑到写前面，模型看到的
  /// 顺序就和它想的不一样了。分组只破坏不了这种依赖关系。
  List<List<ToolCall>> _batchCalls(List<ToolCall> calls) {
    final batches = <List<ToolCall>>[];
    var current = <ToolCall>[];

    void flush() {
      if (current.isEmpty) return;
      batches.add(current);
      current = [];
    }

    for (final call in calls) {
      if (_canRunInParallel(call)) {
        current.add(call);
      } else {
        flush();
        batches.add([call]);
      }
    }
    flush();
    return batches;
  }

  bool _canRunInParallel(ToolCall call) {
    final tool = tools.byName(call.name);
    if (tool == null || !tool.runsInParallel) return false;
    // 审批要弹窗，两个弹窗叠在一起用户没法判断该先看哪个。宁可串行。
    return tool.approvalReason(call.arguments) == null;
  }

  static void _appendToolResult(
    List<ChatMessage> messages,
    List<ChatMessage> produced,
    ToolInvocation invocation,
  ) {
    final call = invocation.call;
    final toolMessage = ChatMessage.toolResult(
      toolCallId: call.id,
      toolName: call.name,
      content: invocation.result.toModelText(),
    );
    messages.add(toolMessage);
    produced.add(toolMessage);
  }
}
