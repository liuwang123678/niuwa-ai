import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/message_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChatMessage _msg(
  String id, {
  Role role = Role.user,
  String content = '',
  int createdAt = 1000,
  List<ImagePart> images = const [],
  List<ToolCall>? toolCalls,
  String? toolCallId,
  String? toolName,
  String? reasoning,
  MessageOrigin origin = MessageOrigin.chat,
}) => ChatMessage(
  id: id,
  role: role,
  content: content,
  createdAt: createdAt,
  images: images,
  toolCalls: toolCalls,
  toolCallId: toolCallId,
  toolName: toolName,
  reasoning: reasoning,
  origin: origin,
);

/// 逐字段比。ChatMessage 没重写 `==`，而这里要的正是"每个字段都原样回来"，
/// 所以宁可啰嗦一点把每个字段点出来——少写一个断言就等于少钉死一个丢字段的坑。
void _expectSameMessage(ChatMessage actual, ChatMessage expected, String tag) {
  expect(actual.id, expected.id, reason: '$tag.id');
  expect(actual.role, expected.role, reason: '$tag.role');
  expect(actual.content, expected.content, reason: '$tag.content');
  expect(actual.createdAt, expected.createdAt, reason: '$tag.createdAt');
  expect(actual.reasoning, expected.reasoning, reason: '$tag.reasoning');
  expect(actual.toolCallId, expected.toolCallId, reason: '$tag.toolCallId');
  expect(actual.toolName, expected.toolName, reason: '$tag.toolName');
  expect(actual.origin, expected.origin, reason: '$tag.origin');

  expect(
    actual.images.map((i) => i.base64Data).toList(),
    expected.images.map((i) => i.base64Data).toList(),
    reason: '$tag.images.base64Data',
  );
  expect(
    actual.images.map((i) => i.mimeType).toList(),
    expected.images.map((i) => i.mimeType).toList(),
    reason: '$tag.images.mimeType',
  );

  expect(actual.toolCalls?.length, expected.toolCalls?.length, reason: '$tag.toolCalls');
  if (expected.toolCalls == null) return;
  for (var i = 0; i < expected.toolCalls!.length; i++) {
    final a = actual.toolCalls![i];
    final b = expected.toolCalls![i];
    expect(a.id, b.id, reason: '$tag.toolCalls[$i].id');
    expect(a.name, b.name, reason: '$tag.toolCalls[$i].name');
    expect(a.arguments, b.arguments, reason: '$tag.toolCalls[$i].arguments');
  }
}

/// 同一套测试跑遍所有实现。
///
/// 不这么写就等着分叉：SQLite 版是用户手机上真正跑的那份，内存版只在测试里活着。
/// 各写一套测试的话，两边的语义会慢慢飘开，而飘开的那天测试还是绿的。
void _runSharedTests(String name, Future<MessageStore> Function() open) {
  group(name, () {
    late MessageStore store;

    setUp(() async {
      store = await open();
    });

    tearDown(() => store.close());

    test('空库：recent / count / clear / append 都安安静静，不炸', () async {
      expect(await store.count(), 0);
      expect(await store.recent(), isEmpty);
      await store.append(const []);
      expect(await store.count(), 0);
      await store.clear();
      expect(await store.count(), 0);
    });

    test('往返保真：reasoning / images / toolCalls / tool_call_id 一个都不许丢', () async {
      // 这四条合起来覆盖 ChatMessage 的全部字段，尤其是线格式会吃掉的那两个
      // （reasoning、images）——存进去再读出来必须逐字段相等。
      final fixtures = [
        _msg('sys', role: Role.system, content: '你是 N1。', createdAt: 100),
        _msg(
          'u1',
          content: '我今天有点累',
          createdAt: 200,
          images: const [
            ImagePart(base64Data: 'aW1n', mimeType: 'image/jpeg'),
            ImagePart(base64Data: 'cG5n'),
          ],
        ),
        _msg(
          'a1',
          role: Role.assistant,
          content: '',
          createdAt: 300,
          reasoning: '先接住情绪，别急着给建议',
          toolCalls: const [
            ToolCall(id: 'call_1', name: 'search_memory', arguments: {'q': '累'}),
          ],
        ),
        _msg(
          't1',
          role: Role.tool,
          content: '{"hits":[]}',
          createdAt: 400,
          toolCallId: 'call_1',
          toolName: 'search_memory',
        ),
      ];

      await store.append(fixtures);

      final restored = await store.recent();
      expect(restored.length, fixtures.length);
      for (var i = 0; i < fixtures.length; i++) {
        _expectSameMessage(restored[i], fixtures[i], '第 $i 条');
      }
    });

    test('消息来源（origin）往返保真', () async {
      final fixtures = [
        _msg('u-plain', content: '普通的一句', createdAt: 10),
        _msg(
          'a-reminder',
          role: Role.assistant,
          content: '三点了，作业交了没？',
          createdAt: 11,
          origin: MessageOrigin.reminder,
        ),
      ];

      await store.append(fixtures);

      final restored = await store.recent();
      expect(restored[0].origin, MessageOrigin.chat);
      expect(restored[1].origin, MessageOrigin.reminder);
      expect(restored[1].content, '三点了，作业交了没？');
    });

    test('没写 origin 的消息默认是正常对话', () async {
      expect(ChatMessage.user('你好').origin, MessageOrigin.chat);
    });

    test('copyWith 不会把 origin 弄丢', () async {
      // origin 有默认值 chat，所以 copyWith 漏传它**不会报错、也不会掉字段**，
      // 只是把提醒消息悄悄变成普通消息——那行「提醒 · 15:00」莫名消失，
      // 而且只在"提醒消息被 copyWith 过一次"时才出现。加上 origin 时就踩到过。
      final reminder = ChatMessage.assistant(
        '三点了',
        origin: MessageOrigin.reminder,
      );

      expect(reminder.copyWith(content: '改过的').origin, MessageOrigin.reminder);
      expect(
        reminder.copyWith(reasoning: '想一下').origin,
        MessageOrigin.reminder,
      );
    });

    test('没值的字段读回来还是"没有"，不是空串也不是空数组', () async {
      // null 被写成 '' 或 [] 是那种"看起来没事"的损坏：界面上思考过程变成一条
      // 空白、传回接口时又多出一个空的 tool_calls。所以要钉死。
      await store.append([
        _msg('bare', content: '就一句话', createdAt: 1),
        _msg('empty-calls', role: Role.assistant, content: '嗯', createdAt: 2, toolCalls: const []),
      ]);

      final bare = (await store.recent()).first;
      expect(bare.reasoning, isNull);
      expect(bare.toolCalls, isNull);
      expect(bare.toolCallId, isNull);
      expect(bare.toolName, isNull);
      expect(bare.images, isEmpty);

      // 空列表跟 null 是两回事，别在序列化的时候被抹平成一个
      final emptyCalls = (await store.recent()).last;
      expect(emptyCalls.toolCalls, isNotNull);
      expect(emptyCalls.toolCalls, isEmpty);
    });

    test('同 id 幂等覆盖，不抛（同一批消息会被重放）', () async {
      await store.append([_msg('dup', content: '旧内容', createdAt: 1)]);
      await store.append([_msg('dup', content: '新内容', createdAt: 1)]);

      expect(await store.count(), 1);
      expect((await store.recent()).single.content, '新内容');

      // 整批重放：内容一模一样，落库结果也必须一模一样
      final batch = [
        _msg('x', content: '一', createdAt: 1),
        _msg('y', content: '二', createdAt: 2),
      ];
      await store.append(batch);
      await store.append(batch);
      expect(await store.count(), 3);
    });

    test('clear 之后干干净净，而且还能接着写', () async {
      await store.append([
        _msg('a', content: '一', createdAt: 1),
        _msg('b', content: '二', createdAt: 2),
        _msg('c', content: '三', createdAt: 3),
      ]);
      expect(await store.count(), 3);

      await store.clear();
      expect(await store.count(), 0);
      expect(await store.recent(), isEmpty);

      await store.append([_msg('after', content: '清完之后还得能写', createdAt: 9)]);
      expect(await store.count(), 1);
      expect((await store.recent()).single.content, '清完之后还得能写');
    });

    test('count 跟着条数走', () async {
      expect(await store.count(), 0);
      await store.append([_msg('a', createdAt: 1)]);
      expect(await store.count(), 1);
      await store.append([_msg('b', createdAt: 2), _msg('c', createdAt: 3)]);
      expect(await store.count(), 3);
    });

    test('同一毫秒的消息按**写入顺序**返回，跟 id 的字典序无关', () async {
      // 真实场景：一轮里 assistant（带 tool_calls）和紧跟的 tool 结果几乎必然
      // 落在同一毫秒。这时排序**只能**靠一个单调的写入序号。
      //
      // 这里故意让 id 的字典序和写入顺序**相反**，把"按 id 兜底"那条路钉死：
      // 一旦实现回退到 created_at + id，这个断言立刻红。
      final ids = [
        for (var i = 0; i < 20; i++) 'id${i.toString().padLeft(2, '0')}',
      ];
      final writeOrder = ids.reversed.toList(); // 逆序写进去
      await store.append([
        for (final id in writeOrder) _msg(id, content: id, createdAt: 5000),
      ]);

      expect(
        (await store.recent()).map((m) => m.id).toList(),
        writeOrder,
        reason: 'created_at 全并列时必须按写入顺序，不是 id 升序',
      );

      for (var round = 0; round < 5; round++) {
        expect(
          (await store.recent()).map((m) => m.id).toList(),
          writeOrder,
          reason: '第 $round 次取，顺序必须一模一样',
        );
      }
    });

    test('同一毫秒的 assistant(tool_calls) 必须排在自己的 tool 结果前面', () async {
      // 这条是那个线上 bug 的最小复现（用户库里 rowid 12/13 的形状）：
      // 两条 created_at 完全相同，而 id 的字典序把 tool 排到了 assistant 前面。
      // 那样的历史发出去，上游直接回
      //   HTTP 400: Messages with role 'tool' must be a response to a
      //             preceding message with 'tool_calls'
      // 而且顺序写死在库里，重启后**每一句话**都失败。
      const ts = 1790328686231;
      const call = ToolCall(
        id: 'call_00_6zLRf9EsefGJmvRK6AWX6649',
        name: 'skill_read',
        arguments: {'name': 'browser-task'},
      );
      final assistant = _msg(
        // 字典序故意大：'p...' > '9...'，按 id 排就会被 tool 挤到后面
        'msg_aaa_hmm9n6v5iqp61efh',
        role: Role.assistant,
        createdAt: ts,
        toolCalls: const [call],
      );
      final toolResult = _msg(
        // 字典序故意小
        'msg_aaa_hmm9n6v5iq9ukupo',
        role: Role.tool,
        content: '# browser-task',
        createdAt: ts,
        toolCallId: call.id,
        toolName: call.name,
      );

      // 按真实产生的顺序写入：先 assistant，再它的 tool 结果
      await store.append([assistant, toolResult]);

      final back = await store.recent();
      expect(back.map((m) => m.id).toList(), [assistant.id, toolResult.id]);
      expect(back.first.role, Role.assistant);
      expect(back.first.toolCalls, isNotNull);
      expect(back.last.toolCallId, call.id);
    });

    test('recent 取的是**最近**的 N 条，不是最老的 N 条', () async {
      // 这条只有对话超过 200 条之后才会暴露：写错成 ORDER BY created_at ASC LIMIT 200
      // 的话，用户看到的是"很久以前的开头"，而且一重启就少掉最近的对话。
      const total = 250;
      final all = [
        for (var i = 0; i < total; i++)
          _msg(
            'm${i.toString().padLeft(3, '0')}',
            content: '第 $i 条',
            createdAt: 1000 + i,
          ),
      ];
      await store.append(all);

      final recent = await store.recent(); // 默认 limit = 200
      expect(recent.length, 200);
      expect(recent.first.id, 'm050', reason: '应该是第 51 条（0 基下标 50），不是第 1 条');
      expect(recent.last.id, 'm249');
      expect(
        recent.map((m) => m.id).toList(),
        all.skip(total - 200).map((m) => m.id).toList(),
      );

      expect((await store.recent(limit: 1)).single.id, 'm249');
      expect(
        (await store.recent(limit: 10)).map((m) => m.id).toList(),
        all.skip(total - 10).map((m) => m.id).toList(),
      );
      expect((await store.recent(limit: total)).length, total);
      expect((await store.recent(limit: total + 500)).length, total);
    });
  });
}

void main() {
  // sqflite 只有移动端有原生实现，桌面/CI 上跑测试得换成 FFI 版的工厂。
  // 这两行写在 setUpAll 里（而不是 setUp）：初始化一次就够，重复设也没意义。
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  _runSharedTests(
    'SqliteMessageStore',
    () => SqliteMessageStore.forTesting(),
  );

  _runSharedTests('InMemoryMessageStore', () async => InMemoryMessageStore());

  group('SqliteMessageStore 专属', () {
    late SqliteMessageStore store;

    setUp(() async {
      store = await SqliteMessageStore.forTesting();
    });

    tearDown(() => store.close());

    test('origin 认不出时当成正常对话，不丢整条消息', () async {
      await store.insertRawForTesting({
        'id': 'msg_weird',
        'role': 'assistant',
        'content': '从未来版本存下来的',
        'created_at': 1,
        'origin': '从火星来的',
      });

      final back = await store.recent();
      expect(back, hasLength(1));
      expect(back.single.origin, MessageOrigin.chat);
      expect(back.single.content, '从未来版本存下来的');
    });

    test('老行的 origin 是 NULL，读出来当成正常对话', () async {
      // 版本 1 的库里没有这一列，升级时 ALTER TABLE 加出来的列对老行全是 NULL。
      // 这一条钉的是「老用户升级后翻旧对话不崩、也不丢消息」。
      await store.insertRawForTesting({
        'id': 'msg_v1',
        'role': 'user',
        'content': '升级前说的话',
        'created_at': 1,
      });

      final back = await store.recent();
      expect(back.single.origin, MessageOrigin.chat);
      expect(back.single.content, '升级前说的话');
    });

    test('先提交 append、再提交 clear（append 不 await）→ 最后是空的', () async {
      // 这条钉的是 `ChatProvider.clear()` 依赖的一个**隐含契约**。
      //
      // 那边的写法是：先 stop()（它会 unawaited(_persist(extra))，把"被取消的
      // 半截话"异步落库），紧接着 await _store.clear()。如果两次写不是按提交
      // 顺序执行，那句半截话就会落在清空**之后**——用户看到"清空了"，
      // 下次启动那半句又冒回来了。
      //
      // 它现在是对的，靠的是两件事：`_persist` 里 `_store.append` 之前没有
      // 任何 await（所以是同步提交的），以及 sqflite 对同一个库按提交顺序串行
      // 执行。**任何一条被改掉，这里就会红**——那正是它存在的意义。
      final pending = store.append([_msg('m1', content: '被取消的半截话')]);
      await store.clear();
      await pending;

      expect(
        await store.count(),
        0,
        reason: 'clear 在 append 之后提交，就该赢；不然就是"清空了又自己长回来"',
      );
      expect(await store.recent(), isEmpty);
    });

    test('SQL 里的排序规则写死成两条，id 兜底一个字都不许少', () {
      // 这两条断言看着像在复述代码，但它们是这个坑**唯一**守得住的地方。
      //
      // 一条是防退回 created_at：按毫秒排必然同毫秒碰撞，碰撞后靠 id 的随机
      // 尾巴抛硬币，掷输就把 tool 排到它爸爸前面 → 整轮历史 400。
      // 另一条是防漏写 id 兜底：索引反着扫的顺序恰好就是 seq DESC, id DESC，
      // 于是漏写的时候排序结果依然正确、测试照样全绿，直到底层换了个执行计划
      // （改了数据量、跑了 ANALYZE、加了别的索引）才开始飘。
      // 所以别删这两行去"简化"测试。
      expect(SqliteMessageStore.recentOrderBy, 'seq ASC, id ASC');
      expect(SqliteMessageStore.recentOrderByDesc, 'seq DESC, id DESC');
    });

    test('落盘格式：thinking 和图片各占一列，没被线格式吃掉', () async {
      // 用 toWire() 当存储格式的话，reasoning 会整个消失、images 会被摊平进
      // content。这里直接看落盘的行，把"哪一列存什么"钉死。
      await store.append([
        _msg(
          'm1',
          role: Role.assistant,
          content: '在的',
          createdAt: 1,
          reasoning: '用户可能只是随口问问',
        ),
        _msg(
          'm2',
          content: '看看这个',
          createdAt: 2,
          images: const [ImagePart(base64Data: 'AAAA', mimeType: 'image/jpeg')],
        ),
        _msg(
          'm3',
          role: Role.assistant,
          content: '',
          createdAt: 3,
          toolCalls: const [
            ToolCall(id: 'c1', name: 'search', arguments: {'q': '猫'}),
          ],
        ),
      ]);

      final rows = {
        for (final r in await store.rawRowsForTesting()) r['id']: r,
      };

      expect(rows['m1']!['reasoning'], '用户可能只是随口问问');
      expect(rows['m1']!['role'], 'assistant');
      expect(
        rows['m2']!['images'],
        '[{"base64Data":"AAAA","mimeType":"image/jpeg"}]',
      );
      // arguments 存的是对象本身，不是线格式里那个被 jsonEncode 过的字符串
      expect(
        rows['m3']!['tool_calls'],
        '[{"id":"c1","name":"search","arguments":{"q":"猫"}}]',
      );
    });

    test('一行脏数据不会让整次加载崩掉，但也不会半解析', () async {
      await store.append([_msg('good', content: '好的一条', createdAt: 1)]);

      // 用户导入 / 旧版本升级 / 手改库文件都可能留下这种东西
      await store.insertRawForTesting({
        'id': 'broken-role',
        'role': '乱写的角色',
        'content': 'role 认不出来',
        'created_at': 2,
      });
      await store.insertRawForTesting({
        'id': 'broken-json',
        'role': 'user',
        'content': 'images 不是 JSON',
        'created_at': 3,
        'images': '这不是 JSON',
      });
      await store.insertRawForTesting({
        'id': '',
        'role': 'user',
        'content': '连 id 都没有',
        'created_at': 4,
      });
      await store.insertRawForTesting({
        'id': 'half-parsed',
        'role': 'assistant',
        'content': '工具调用少了一条也得整行丢掉',
        'created_at': 5,
        'tool_calls': '[{"id":"c1","name":"search","arguments":{}}, 42]',
      });

      expect((await store.recent()).map((m) => m.id).toList(), ['good']);
      expect(await store.count(), 5); // 脏行还在库里，只是被跳过了
    });
  });

  group('两个实现的顺序必须一模一样', () {
    // 参数化的那套测试是各自对着"正确答案"断言；这一条是让两个实现直接对撞，
    // 时间戳成组并列（一轮对话的真实样子）时最容易分叉。
    late SqliteMessageStore sqlite;
    late InMemoryMessageStore memory;

    setUp(() async {
      sqlite = await SqliteMessageStore.forTesting();
      memory = InMemoryMessageStore();
    });

    tearDown(() => sqlite.close());

    test('同一批数据（含并列时间戳）取出来的顺序逐条相同', () async {
      final fixtures = [
        for (var i = 0; i < 250; i++)
          _msg(
            'm${i.toString().padLeft(3, '0')}',
            content: '第 $i 条',
            // 每 3 条共用一毫秒：assistant + tool_call + tool 结果就是这种样子
            createdAt: 1000 + i ~/ 3,
          ),
      ];

      await sqlite.append(fixtures);
      await memory.append(fixtures);

      for (final limit in [1, 2, 3, 199, 200, 201, 250, 999]) {
        expect(
          (await sqlite.recent(limit: limit)).map((m) => m.id).toList(),
          (await memory.recent(limit: limit)).map((m) => m.id).toList(),
          reason: 'limit=$limit 时 SQLite 版和内存版的顺序必须一致',
        );
      }
    });
  });
}
