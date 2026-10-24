import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 只回正文的一轮。
List<LlmChunk> textTurn(String text) => [
  TextChunk(text),
  const DoneChunk('stop'),
];

/// 发起一次工具调用的一轮。参数按碎片给，模拟真实流式响应。
List<LlmChunk> toolTurn({
  required int index,
  required String id,
  required String name,
  required List<String> argFragments,
}) => [
  ToolCallChunk(index: index, id: id, name: name),
  ...argFragments.map(
    (f) => ToolCallChunk(index: index, argumentsFragment: f),
  ),
  const DoneChunk('tool_calls'),
];

void main() {
  late ToolRegistry registry;
  late ToolContext context;

  setUp(() {
    registry = ToolRegistry();
    context = testContext();
  });

  AgentLoop buildLoop(LlmClient llm, {int maxTurns = 8}) => AgentLoop(
    llm: llm,
    tools: registry,
    context: context,
    promptBuilder: testPromptBuilder(),
    maxTurns: maxTurns,
    // 固定时钟：`_withClock` 会把现在这一行拼进最后一条用户消息，
    // 不钉住的话任何断言正文的用例都会在跨分钟时偶发变红。
    clock: () => testNow,
  );

  group('纯文本回答', () {
    test('发出 开始 → 文本增量 → 说完 → 结束 的事件序列', () async {
      final llm = FakeLlmClient([
        [const TextChunk('你好'), const TextChunk('呀'), const DoneChunk('stop')],
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('在吗'))
          .toList();

      expect(events.whereType<TurnStarted>().length, 1);
      expect(
        events.whereType<TextDelta>().map((e) => e.text).join(),
        '你好呀',
      );
      expect(events.whereType<TurnComplete>().length, 1);

      final done = events.whereType<RunComplete>().single;
      expect(done.stopReason, 'stop');
      // 用户输入 + assistant 回复
      expect(done.produced.length, 2);
      expect(done.produced.first.role, Role.user);
      expect(done.produced.last.role, Role.assistant);
      expect(done.produced.last.content, '你好呀');
    });

    test('system prompt 排在消息列表最前面', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: [ChatMessage.user('之前说过的话')],
            input: ChatMessage.user('现在'),
          )
          .toList();

      final sent = llm.lastMessages;
      expect(sent.first.role, Role.system);
      expect(sent[1].content, '之前说过的话');
      // 最后一条用户消息前面会拼一行"现在"，见下面的「时间」组。
      expect(sent.last.content, endsWith('\n现在'));
    });

    test('时间拼在最后一条用户消息上，system prompt 里没有', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: [ChatMessage.user('很久以前说的话')],
            input: ChatMessage.user('现在几点'),
          )
          .toList();

      final sent = llm.lastMessages;

      // system prompt 是整段历史的前缀，它一变缓存全灭。
      expect(sent.first.content, isNot(contains('星期五')));
      expect(sent.first.content, isNot(contains('14:30')));

      // 只给**最后一条**用户消息加时间；老的那条一个字不动。
      expect(sent[1].content, '很久以前说的话');
      expect(sent.last.content, startsWith('（现在是 2026 年 9 月 25 日 星期五 14:30）'));
      expect(sent.last.content, endsWith('现在几点'));
    });

    test('时间只影响"发出去的那份"，不污染这一轮的真话', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('在吗'))
          .toList();

      // 存进库、显示在界面上的应该是用户原话，不带那行时间。
      final produced = events.whereType<RunComplete>().single.produced;
      expect(produced.first.content, '在吗');
    });

    test('多轮工具调用里，时间在每一轮都还在（而且只在末条用户消息上）', () async {
      final probe = ProbeTool('echo', result: const ToolResult.ok('好'));
      registry.register(probe);

      final llm = FakeLlmClient([
        toolTurn(
          index: 0,
          id: 'call_1',
          name: 'echo',
          argFragments: ['{}'],
        ),
        textTurn('办完了'),
      ]);

      await buildLoop(llm)
          .run(
            history: [ChatMessage.user('早前的一句')],
            input: ChatMessage.user('帮我看看'),
          )
          .toList();

      final sent = llm.lastMessages;
      // 第二轮请求末尾是 tool 结果，用户消息要在里头找。
      final userMsg = sent.lastWhere((m) => m.role == Role.user);
      // 时间还得在——否则模型在第一轮工具调用之后就把"现在"忘了。
      expect(userMsg.content, endsWith('帮我看看'));
      expect(userMsg.content, startsWith('（现在是'));
      // 历史那条依旧干净。
      expect(sent[1].content, '早前的一句');
    });

    test('思考内容单独成流，不混进正文', () async {
      final llm = FakeLlmClient([
        [
          const ReasoningChunk('用户'),
          const ReasoningChunk('在打招呼'),
          const TextChunk('在的'),
          const DoneChunk('stop'),
        ],
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('在吗'))
          .toList();

      expect(
        events.whereType<ReasoningDelta>().map((e) => e.text).join(),
        '用户在打招呼',
      );

      final assistant = events.whereType<TurnComplete>().single.message;
      expect(assistant.content, '在的');
      expect(assistant.reasoning, '用户在打招呼');
    });
  });

  group('工具调用', () {
    test('碎片参数能拼成完整的 JSON', () async {
      final probe = ProbeTool(
        'echo',
        schema: const {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
        },
      );
      registry.register(probe);

      final llm = FakeLlmClient([
        toolTurn(
          index: 0,
          id: 'call_1',
          name: 'echo',
          // 真实响应就是这样一个字符一个字符推过来的
          argFragments: ['{', '"ci', 'ty"', ': ', '"北', '京"', '}'],
        ),
        textTurn('查到了'),
      ]);

      await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('查北京'))
          .toList();

      expect(probe.receivedInputs.single['city'], '北京');
    });

    test('工具结果回填后接着跑第二轮，消息顺序正确', () async {
      registry.register(
        ProbeTool('echo', result: const ToolResult.ok('工具说：晴')),
      );

      final llm = FakeLlmClient([
        toolTurn(index: 0, id: 'call_1', name: 'echo', argFragments: ['{}']),
        textTurn('北京今天晴。'),
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('天气'))
          .toList();

      expect(llm.calls, 2, reason: '应该有第二轮请求');
      expect(events.whereType<TurnStarted>().length, 2);
      expect(events.whereType<ToolCallStarted>().single.call.name, 'echo');
      expect(events.whereType<ToolCallFinished>().length, 1);

      final produced = events.whereType<RunComplete>().single.produced;
      expect(
        produced.map((m) => m.role).toList(),
        [Role.user, Role.assistant, Role.tool, Role.assistant],
      );
      expect(produced[2].content, '工具说：晴');
      expect(produced[2].toolCallId, 'call_1');
      expect(produced.last.content, '北京今天晴。');
    });

    test('一次返回多个工具调用时按 index 顺序依次执行', () async {
      final a = ProbeTool('a', result: const ToolResult.ok('A'));
      final b = ProbeTool('b', result: const ToolResult.ok('B'));
      registry
        ..register(a)
        ..register(b);

      final llm = FakeLlmClient([
        [
          ToolCallChunk(index: 1, id: 'c2', name: 'b'),
          const ToolCallChunk(index: 1, argumentsFragment: '{}'),
          ToolCallChunk(index: 0, id: 'c1', name: 'a'),
          const ToolCallChunk(index: 0, argumentsFragment: '{}'),
          const DoneChunk('tool_calls'),
        ],
        textTurn('都做完了'),
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('都做'))
          .toList();

      expect(
        events.whereType<ToolCallStarted>().map((e) => e.call.name).toList(),
        ['a', 'b'],
      );
    });

    test('工具超时会转成失败文本，而不是把整轮带崩', () async {
      registry.register(
        ProbeTool(
          'slow',
          delay: const Duration(milliseconds: 300),
        ),
        timeout: const Duration(milliseconds: 50),
      );

      final llm = FakeLlmClient([
        toolTurn(index: 0, id: 'c1', name: 'slow', argFragments: ['{}']),
        textTurn('那个工具超时了'),
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('跑个慢的'))
          .toList();

      final finished = events.whereType<ToolCallFinished>().single;
      expect(finished.invocation.result.ok, isFalse);
      expect(finished.invocation.result.content, contains('超时'));

      // 关键：超时之后 agent 还能接着说
      expect(events.whereType<RunComplete>().single.stopReason, 'stop');
    });

    test('工具抛异常会被吃掉，回填失败文本', () async {
      registry.register(ProbeTool('boom', throwThis: StateError('炸了')));

      final llm = FakeLlmClient([
        toolTurn(index: 0, id: 'c1', name: 'boom', argFragments: ['{}']),
        textTurn('失败了'),
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('炸一下'))
          .toList();

      final result = events
          .whereType<ToolCallFinished>()
          .single
          .invocation
          .result;
      expect(result.ok, isFalse);
      expect(result.content, contains('炸了'));
    });

    test('调了不存在的工具会明确报错并列出可用的', () async {
      registry.register(ProbeTool('real'));

      final llm = FakeLlmClient([
        toolTurn(index: 0, id: 'c1', name: 'ghost', argFragments: ['{}']),
        textTurn('哦'),
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('调个不存在的'))
          .toList();

      final result = events
          .whereType<ToolCallFinished>()
          .single
          .invocation
          .result;
      expect(result.ok, isFalse);
      expect(result.content, contains('ghost'));
      expect(result.content, contains('real'));
    });

    test('模型吐出坏 JSON 参数时报错，不崩', () async {
      registry.register(ProbeTool('echo'));

      final llm = FakeLlmClient([
        // 少个引号
        toolTurn(index: 0, id: 'c1', name: 'echo', argFragments: ['{bad json']),
        textTurn('收到'),
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('坏的'))
          .toList();

      final result = events
          .whereType<ToolCallFinished>()
          .single
          .invocation
          .result;
      expect(result.ok, isFalse);
      expect(result.content, contains('JSON'));
    });
  });

  group('守卫', () {
    test('模型一直调工具时，撞上 maxTurns 会停下', () async {
      registry.register(ProbeTool('loop'));

      // 脚本给 5 轮工具调用，但 maxTurns 只允许 2 轮
      final llm = FakeLlmClient([
        for (var i = 0; i < 5; i++)
          toolTurn(
            index: 0,
            id: 'c$i',
            name: 'loop',
            argFragments: ['{}'],
          ),
      ]);

      final events = await buildLoop(llm, maxTurns: 2)
          .run(history: const [], input: ChatMessage.user('转圈'))
          .toList();

      expect(llm.calls, 2);
      expect(events.whereType<RunComplete>().single.stopReason, 'max_turns');
    });

    test('模型报错时发 AgentFailed 并终止', () async {
      final events = await buildLoop(FailingLlmClient('余额不足'))
          .run(history: const [], input: ChatMessage.user('你好'))
          .toList();

      final failed = events.whereType<AgentFailed>().single;
      expect(failed.message, '余额不足');
      expect(events.whereType<RunComplete>(), isEmpty);
      // 出错前的 TurnStarted 已经发出去了，界面不用自己造状态
      expect(events.whereType<TurnStarted>().length, 1);
    });

    test('finish_reason 是 length 时如实标出来', () async {
      final llm = FakeLlmClient([
        [const TextChunk('被截断了'), const DoneChunk('length')],
      ]);

      final events = await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('写长的'))
          .toList();

      expect(events.whereType<RunComplete>().single.stopReason, 'length');
    });
  });

  group('发出去的工具声明', () {
    test('注册表里的工具会带进请求', () async {
      registry
        ..register(ProbeTool('alpha', description: '第一个'))
        ..register(ProbeTool('beta', description: '第二个'));

      final llm = FakeLlmClient([textTurn('好')]);
      await buildLoop(llm)
          .run(history: const [], input: ChatMessage.user('看工具'))
          .toList();

      expect(
        llm.lastTools.map((t) => t.name).toList(),
        ['alpha', 'beta'],
        reason: '工具声明顺序必须稳定，否则提示缓存会失效',
      );
    });
  });

  // --------------------------------------------------------------------------
  // 发送前的净化。
  //
  // 这是**防线不是根因修复**：根因是排序（消息表按 created_at 排，同毫秒时
  // 靠 id 的随机尾巴抛硬币，掷输就把 tool 结果排到它的 assistant 前面）。
  // 根因由 `messages.seq` 修掉了，这一层管的是别的事：**万一**库里再出现
  // 不自洽的历史（用户导入、手改、旧版本写坏、以后加的新功能有 bug），
  // 后果应该是"少一段上下文"，而不是"整个对话永久废掉、每句话都 400"。
  //
  // 上游的原话是这个，一个字都不含糊：
  //   HTTP 400: Messages with role 'tool' must be a response to a preceding
  //             message with 'tool_calls'
  // --------------------------------------------------------------------------
  group('发送前净化历史', () {
    ChatMessage toolMsg({
      required String id,
      String? callId,
      String content = '结果',
      int createdAt = 2,
    }) => ChatMessage(
      id: id,
      role: Role.tool,
      content: content,
      createdAt: createdAt,
      toolCallId: callId,
      toolName: 'probe',
    );

    ChatMessage assistantWithCalls({
      required String id,
      required List<ToolCall> calls,
      int createdAt = 1,
    }) => ChatMessage(
      id: id,
      role: Role.assistant,
      content: '',
      createdAt: createdAt,
      toolCalls: calls,
    );

    test('前面没有带这个 tool_call_id 的 assistant，那条 tool 就不发', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      final events = await buildLoop(llm)
          .run(
            history: [
              ChatMessage.user('你好'),
              toolMsg(id: 't1', callId: 'call_谁也没声明过'),
            ],
            input: ChatMessage.user('在吗'),
          )
          .toList();

      expect(
        llm.lastMessages.where((m) => m.role == Role.tool),
        isEmpty,
        reason: '孤儿 tool 发出去，上游必然回 400，整轮对话就废了',
      );
      // 净化只该丢那一行，别把整段历史清了。
      // （最后一条用户消息前面会拼一行"现在"，所以按结尾匹配。）
      final contents = llm.lastMessages.map((m) => m.content).toList();
      expect(contents, contains('你好'));
      expect(contents.last, endsWith('\n在吗'));
      // 而且这一轮要能正常跑完，不是静悄悄失败。
      expect(events.whereType<RunComplete>(), hasLength(1));
    });

    test('tool_call_id 是 null 的 tool 也不发', () async {
      // `toWire()` 会把 null 原样吐出去，上游看到的是一个没有归属的 tool 结果。
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: [toolMsg(id: 't1', callId: null)],
            input: ChatMessage.user('在吗'),
          )
          .toList();

      expect(llm.lastMessages.where((m) => m.role == Role.tool), isEmpty);
    });

    test('assistant 声明了 tool_calls 却没有结果，就剥掉 tool_calls 再发', () async {
      // 半条历史同样非法（这次的根因 bug 就是它反过来那一面）。
      // 但这条消息本身是用户看得见的"我说过的话"，所以要留着，只拆掉声明。
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: [
              assistantWithCalls(
                id: 'a1',
                calls: const [
                  ToolCall(id: 'c1', name: 'probe', arguments: {}),
                ],
              ),
            ],
            input: ChatMessage.user('在吗'),
          )
          .toList();

      final sentAssistant = llm.lastMessages.singleWhere(
        (m) => m.role == Role.assistant,
      );
      expect(sentAssistant.toolCalls, isNull);
      expect(sentAssistant.id, 'a1', reason: '剥的是声明，消息本身要留着');
    });

    test('配对完整的一对原样发出去，不误伤', () async {
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: [
              assistantWithCalls(
                id: 'a1',
                calls: const [
                  ToolCall(id: 'c1', name: 'probe', arguments: {}),
                ],
              ),
              toolMsg(id: 't1', callId: 'c1'),
            ],
            input: ChatMessage.user('在吗'),
          )
          .toList();

      final sent = llm.lastMessages;
      expect(
        sent.singleWhere((m) => m.role == Role.assistant).toolCalls,
        hasLength(1),
        reason: '配对是好的，净化器不许乱动',
      );
      expect(sent.singleWhere((m) => m.role == Role.tool).toolCallId, 'c1');
    });

    test('一次声明多个调用、只回了一半结果：只保留有结果的那个', () async {
      // 一个 assistant 可以同时声明多个 tool_calls。只回了一半的话，
      // 整条声明发出去仍然是非法（少一个 tool 结果），但**不能**把整个
      // assistant 的声明都剥掉——那样连有结果的那个也一起丢了。
      final llm = FakeLlmClient([textTurn('嗯')]);

      await buildLoop(llm)
          .run(
            history: [
              assistantWithCalls(
                id: 'a1',
                calls: const [
                  ToolCall(id: 'c1', name: 'probe', arguments: {}),
                  ToolCall(id: 'c2', name: 'probe', arguments: {}),
                ],
              ),
              toolMsg(id: 't1', callId: 'c1'),
            ],
            input: ChatMessage.user('在吗'),
          )
          .toList();

      final sentAssistant = llm.lastMessages.singleWhere(
        (m) => m.role == Role.assistant,
      );
      expect(
        sentAssistant.toolCalls?.map((c) => c.id).toList(),
        ['c1'],
        reason: 'c2 没有结果，留着就是非法历史；c1 有结果，丢了是白丢',
      );
    });

    test('正经的多轮工具历史一条都不动', () async {
      // 回归防线：净化器最容易的错法是"顺手多删"。这里放一段带两轮工具调用的
      // 完整历史，逐条断言原样通过。
      final llm = FakeLlmClient([textTurn('嗯')]);

      final history = [
        ChatMessage.user('第一句'),
        assistantWithCalls(
          id: 'a1',
          calls: const [ToolCall(id: 'c1', name: 'probe', arguments: {})],
        ),
        toolMsg(id: 't1', callId: 'c1'),
        ChatMessage(
          id: 'a2',
          role: Role.assistant,
          content: '查到了',
          createdAt: 3,
        ),
        ChatMessage.user('第二句'),
      ];

      await buildLoop(llm)
          .run(history: history, input: ChatMessage.user('第三句'))
          .toList();

      expect(
        llm.lastMessages.map((m) => m.id).where((id) => id.startsWith('a') || id.startsWith('t')).toList(),
        ['a1', 't1', 'a2'],
      );
      expect(
        llm.lastMessages.singleWhere((m) => m.id == 'a1').toolCalls,
        hasLength(1),
      );
    });
  });
}
