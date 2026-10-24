import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/models/attachment.dart';
import '../core/models/chat_message.dart';

/// 聊天记录的落库接口。
///
/// 跟 `MemoryStore`（`lib/core/memory/memory_store.dart`）故意分成两条线：
/// 记忆是"提炼过的长期事实"，按重要度检索、会被淘汰；聊天记录是"原样的对话流水"，
/// 只按时间取最近若干条、不淘汰。两者的排序规则和增长量级都不一样，
/// 硬塞进一张表迟早要互相迁就。
abstract class MessageStore {
  /// 最近 [limit] 条，**按时间正序**返回：最老的在前、最新的在后。
  /// 这个顺序是给 `AgentLoop.run(history: ...)` 直接用的，不要反。
  Future<List<ChatMessage>> recent({int limit = 200});

  /// 追加。id 重复时**幂等覆盖**，不要抛——同一批消息可能被重放。
  Future<void> append(List<ChatMessage> messages);

  Future<void> clear();

  Future<int> count();

  Future<void> close();
}

/// 纯内存实现。测试用，也可以当作数据库还没就绪时的兜底。
///
/// **排序语义必须跟 [SqliteMessageStore] 一字不差**——两边一旦分叉，
/// 绿的是测试里的内存版，乱的是用户手机上的 SQLite 版，而后者根本跑不进测试。
class InMemoryMessageStore implements MessageStore {
  InMemoryMessageStore([List<ChatMessage> seed = const []]) {
    for (final m in seed) {
      _messages[m.id] = m;
      _seq.putIfAbsent(m.id, () => _nextSeq);
    }
  }

  final Map<String, ChatMessage> _messages = {};

  /// 写入序号，跟 SQLite 那列的 `seq` 一一对应。
  ///
  /// 本来可以偷懒靠 `Map` 的插入顺序（Dart 的 LinkedHashMap 给已有 key 赋值
  /// **不会**改变位置，正好是 upsert 该有的语义）。但那样两边就是"靠一个语言
  /// 实现细节"对齐，而不是靠同一个规则——SQLite 那边 `INSERT OR REPLACE` 是
  /// delete+insert，物理位置一定会变。所以顺序只由 seq 决定，内存版照抄。
  final Map<String, int> _seq = {};

  int get _nextSeq =>
      _seq.values.fold(0, (a, b) => a > b ? a : b) + 1;

  @override
  Future<void> append(List<ChatMessage> messages) async {
    for (final m in messages) {
      // map 赋值天然就是"同 id 覆盖"，所以重放同一批消息不会变成两条。
      _messages[m.id] = m;
      // 已有 id 时闭包不会被调用 → 号不变，跟 SQL 里那个 COALESCE 的第一个
      // 分支等价。重放时若重新发号，那条消息就会跳到列表末尾，界面上表现为
      // "上一轮的回答突然跑到了最新一条下面"。
      //
      // 每次现算 max 而不是维护一个 _maxSeq 字段：删一条之后忘了重算，号就会
      // 一路飘高，跟 SQLite 又分叉。O(n) 无所谓。
      _seq.putIfAbsent(m.id, () => _nextSeq);
    }
  }

  @override
  Future<List<ChatMessage>> recent({int limit = 200}) async {
    // limit 为负时 SQLite 的 `LIMIT -1` 是"不限量"的意思，跟这里"取 0 条"会分叉，
    // 所以在两边都挡在最前面。正常的调用方传的是正数，这行只是把坑封掉。
    if (limit <= 0) return const [];

    final sorted = _messages.values.toList()..sort(_byOrder);
    // 取的是**最后** limit 条（最新的那批），不是开头 limit 条。
    // 写成 take(limit) 就是"最老的 200 条"，对话不超过 200 条时看不出来。
    final start = sorted.length > limit ? sorted.length - limit : 0;
    return sorted.sublist(start);
  }

  @override
  Future<void> clear() async {
    _messages.clear();
    _seq.clear();
  }

  @override
  Future<int> count() async => _messages.length;

  /// 内存版没有句柄要放，但接口得有——调用方不该关心自己拿到的是哪种实现。
  @override
  Future<void> close() async {}

  /// 写入顺序升序，并列时 id 升序兜底。规则跟 SQLite 的 `recentOrderBy` 是同一条。
  int _byOrder(ChatMessage a, ChatMessage b) {
    final bySeq = (_seq[a.id] ?? 0).compareTo(_seq[b.id] ?? 0);
    return bySeq != 0 ? bySeq : a.id.compareTo(b.id);
  }
}

/// 落在 SQLite 上的聊天记录存储。
///
/// 这个类的活儿只有一件：把 [MessageStore] 的语义**一字不差**地翻译成 SQL 加
/// Dart 排序。任何"顺手优化"都会让真机和 `InMemoryMessageStore` 的行为分叉，
/// 而这种分叉最难查——测试全绿，用户手机上对话顺序却是乱的。
class SqliteMessageStore implements MessageStore {
  SqliteMessageStore._(this._db);

  static const String table = 'messages';

  /// 正序取用的排序规则：写入序号升序，`id ASC` 兜底。
  ///
  /// **不要改回按 `created_at` 排。** `created_at` 是毫秒时间戳，同一轮里产生的
  /// 几条消息（assistant 带 tool_calls、紧跟其后的 tool 结果……）几乎必然撞在
  /// 同一毫秒上，于是排序会退回到 id 兜底——而 id 的尾巴是 6 位随机数
  /// （`lib/core/util/ids.dart`），同微秒时**纯抛硬币**。掷输的那一次，tool 结果
  /// 会排到它爸爸前面，历史就不合法了，上游回
  ///   HTTP 400: Messages with role 'tool' must be a response to a
  ///             preceding message with 'tool_calls'
  /// 更糟的是这个顺序会被写死进库，重启后**每一句话**都发不出去。
  ///
  /// `seq` 由存储层在写入那一刻发放、之后永不改变，与 id 和时钟都无关，
  /// 所以不存在"抛硬币"这件事。
  ///
  /// 兜底的 `id` 还是不能省：`seq` 理论上唯一，但 `insertRawForTesting` 那种
  /// 绕过 append 直接插进来的脏行 seq 是 NULL，全 NULL 之间必须有确定性兜底
  /// （NULL 在 ASC 里排最前、DESC 里排最后，两边正好互为镜像）。
  static const String recentOrderBy = 'seq ASC, id ASC';

  /// 取"最近 N 条"用的倒序，**必须跟 [recentOrderBy] 严格互为镜像**。
  ///
  /// 先倒着取 N 条、再翻回正序，等于正序里的**最后** N 条，也就是"最近的 N 条"。
  /// 直接 `ORDER BY seq ASC LIMIT 200` 拿到的是**最老的** 200 条：
  /// 这是错的，而且对话不超过 200 条时完全看不出来。
  ///
  /// 两条排序都是 public 的，是为了让测试能**逐字断言**。光靠"跑一遍看顺序对不对"
  /// 抓不住漏写兜底：下面那个索引反着扫出来的顺序，恰好就是 `seq DESC, id DESC`，
  /// 于是漏写的时候行为看起来完全正确——直到某天 SQLite 换了个执行计划
  /// （改了数据量、跑了 ANALYZE、加了别的索引），兜底没了，顺序就开始飘。
  /// 所以那句 SQL 得能被测试一个字一个字地钉住。
  static const String recentOrderByDesc = 'seq DESC, id DESC';

  final Database _db;

  /// 直接用一个**已经打开的**库。生产入口是 `N1Runtime`。
  ///
  /// 为什么生产不走 [open]：同一个 `.db` 文件上如果两个 store 各自
  /// `openDatabase(path, version: 1, onCreate: ...)`，第二个会看到文件已经是
  /// version 1 而**跳过 onCreate**，这张表就永远建不出来。发作形态很阴：
  /// 首次启动一切正常，聊到第一次该落库的时候才炸「no such table: messages」。
  ///
  /// 所以生产上由 `N1Runtime` 开一次库、把两张表一起建好，再分给各个 store。
  factory SqliteMessageStore.fromDatabase(Database db) = SqliteMessageStore._;

  /// 建表。给共用同一个库的启动流程调用（见 [fromDatabase]）。
  static Future<void> createSchema(Database db) => _createSchema(db);

  /// 打开（或首次创建）数据库文件。
  ///
  /// ⚠️ 生产路径**不要**直接用它——同一个文件上只能有一个 store 走这条路，
  /// 理由见 [fromDatabase]。测试里每个用例是独立的内存库，所以那里没问题。
  static Future<SqliteMessageStore> open(String path) async {
    // 首次启动时 <appSupport>/ 下的目录可能还不存在，而 sqflite 只管建库文件、
    // 不管建父目录，不补这一下会以"unable to open database file"失败
    // （报错里不会提"目录不存在"，查起来要绕一圈）。
    if (path != inMemoryDatabasePath) {
      final dir = Directory(p.dirname(path));
      if (!await dir.exists()) await dir.create(recursive: true);
    }
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => _createSchema(db),
    );
    return SqliteMessageStore._(db);
  }

  /// 内存库。测试用——每个测试拿到的是**全新**的一个库，
  /// 所以测试之间不会互相看见对方写的消息。
  static Future<SqliteMessageStore> forTesting() => open(inMemoryDatabasePath);

  /// 建表建索引。**全部写成 IF NOT EXISTS**，因为迁移那条路也会调它
  /// （加完列之后用它把索引换成新形态），而跑第二遍不许炸。
  static Future<void> _createSchema(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $table (
  id TEXT PRIMARY KEY,
  role TEXT,
  content TEXT,
  created_at INTEGER,
  reasoning TEXT,
  images TEXT,
  attachments TEXT,
  tool_calls TEXT,
  tool_call_id TEXT,
  tool_name TEXT,
  origin TEXT,
  seq INTEGER
)
''');
    // recent() 每一轮对话都要走一遍（要拼进 history），条数上去以后
    // "全表排序 + 临时 B 树"会很明显。索引直接拿 [recentOrderBy] 来建，
    // 不是再抄一遍字面量——抄的话哪天排序规则改了而这里忘了改，
    // 症状是查询突然开始走临时 B 树（慢），但顺序还是对的，所以没人会发现。
    // B 树反着扫就是 [recentOrderByDesc]，取最近 N 条那条路照样顺着走。
    //
    // 注意别指望它兜住排序：索引刚好能"顺便"把一个漏写 id 兜底的 ORDER BY
    // 排成正确的样子（反扫 = seq DESC, id DESC），于是 bug 被藏起来，
    // 只在换个执行计划时才现形。排序规则该写全还是得写全。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_${table}_recent ON $table($recentOrderBy)',
    );
  }

  @override
  Future<void> close() => _db.close();

  /// 测试钩子：直接看落盘的行，用来验证 reasoning / images 是真的各占一列
  /// （而不是走了线格式被悄悄丢掉——那种错误读回来才发现，而且只有第二次启动才炸）。
  @visibleForTesting
  Future<List<Map<String, Object?>>> rawRowsForTesting() => _db.query(table);

  /// 测试钩子：绕过模型直接插一行，用来模拟用户导入/旧版本升级留下的脏数据。
  @visibleForTesting
  Future<void> insertRawForTesting(Map<String, Object?> row) =>
      _db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> append(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    // 一轮对话通常只追加一条，为它开一个 batch 事务不值得，单独走一条 insert。
    if (messages.length == 1) {
      final (sql, args) = _upsertOf(messages.single);
      await _db.rawInsert(sql, args);
      return;
    }
    // 一次对话回填就是几十上百条，逐条 await 就是上百次跨 isolate 往返。
    // batch 把它们塞进一个事务：快，而且中途挂掉不会只落一半——
    // 半批消息比没落更糟，那会让 history 里的 tool_calls 配不上对。
    //
    // 一个事务、一条连接、按顺序执行，所以第二条的 MAX(seq) 已经看得见第一条
    // 刚插进去的行，同批不会重号。
    final batch = _db.batch();
    for (final m in messages) {
      final (sql, args) = _upsertOf(m);
      batch.rawInsert(sql, args);
    }
    await batch.commit(noResult: true);
  }

  /// seq 的取值表达式：**已经存在就沿用，不存在才发新号**。
  ///
  /// 两个子查询在**算 VALUES 的那一刻**求值，而 `INSERT OR REPLACE` 是先算
  /// VALUES 再解冲突，所以第一个子查询读到的是**被覆盖前那一行**的 seq。
  /// 这一行是整个方案里最险的一处，正确性靠 `message_store_test.dart` 里
  /// "同 id 重放之后号和位置都不许变"钉着。
  ///
  /// 为什么不给 seq 加 `UNIQUE` 约束：`INSERT OR REPLACE` 解决的是**任何**唯一
  /// 索引上的冲突，不只主键。万一日后两条行算出同一个号（改了发号规则、外部
  /// 导入），那个约束会让新行**把另一条无关的消息删掉**——把一个"顺序错乱"的
  /// 毛病升级成"消息凭空消失"。唯一性由"单连接 MAX+1"这个构造保证，用测试钉。
  static const String _seqExpr =
      'COALESCE((SELECT seq FROM $table WHERE id = ?), '
      '(SELECT IFNULL(MAX(seq), 0) + 1 FROM $table))';

  /// 一条 upsert 语句加它的参数。
  ///
  /// 列名从 [_rowOf] 的结果**现推**，绝不手抄列表：手抄的话，哪天 [_rowOf] 加了
  /// 一列而这里忘了，症状是"那个字段存进去就没了"——不报错、不崩溃，
  /// 直到某次重启才发现思考过程或图片不见了。
  ///
  /// 参数顺序：先是各列的值（按 `row.keys` 的顺序，跟拼进 SQL 的那份是同一份），
  /// 然后是 [_seqExpr] 里两个子查询唯一用到的那个 id（第二个子查询没有占位符）。
  static (String, List<Object?>) _upsertOf(ChatMessage m) {
    final row = _rowOf(m);
    final cols = row.keys.join(', ');
    final marks = List.filled(row.length, '?').join(', ');
    return (
      'INSERT OR REPLACE INTO $table ($cols, seq) VALUES ($marks, $_seqExpr)',
      [...row.values, m.id],
    );
  }

  @override
  Future<List<ChatMessage>> recent({int limit = 200}) async {
    // 见 InMemoryMessageStore.recent：负数在 SQLite 这里是"不限量"。
    if (limit <= 0) return const [];

    final rows = await _db.query(
      table,
      orderBy: recentOrderByDesc,
      limit: limit,
    );
    // 上面查出来的是"最新的 limit 条，新的在前"，整个翻过来才是接口要的正序。
    return rows
        .map(_messageOf)
        .whereType<ChatMessage>()
        .toList()
        .reversed
        .toList();
  }

  @override
  Future<void> clear() async {
    await _db.delete(table);
  }

  @override
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) FROM $table');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  // ---------------------------------------------------------------- 内部

  /// 一条消息 → 一行。
  ///
  /// **不要图省事用 `ChatMessage.toWire()` / `fromWire()`**。那两个是发给
  /// 模型的**线格式**，不是通用序列化：`toWire()` 按协议故意丢掉 `reasoning`
  /// （接口明确不收把思考塞回上下文），还把 `images` 摊平进了 content 数组。
  /// 拿它当存储格式的话，重启后思考过程和图片会**无声无息地消失**——
  /// 不报错、不崩溃，只是用户某天发现"昨天发的那张图不见了，你也没在想什么"。
  /// 所以这里手写映射，模型上的字段一个不落地各占一列。
  static Map<String, Object?> _rowOf(ChatMessage m) => {
    'id': m.id,
    'role': m.role.name,
    'content': m.content,
    'created_at': m.createdAt,
    'reasoning': m.reasoning,
    // images 在模型里是 List<ImagePart>，在库里是一列 JSON。
    // 字段名沿用模型自己的（base64Data / mimeType），少一层翻译少一次搞错。
    'images': jsonEncode([
      for (final i in m.images)
        {'base64Data': i.base64Data, 'mimeType': i.mimeType},
    ]),
    // 跟 images 一样：附件正文可能很长，但它是这条消息的一部分，
    // 不能只留个文件名——下次启动要照样能把它交给模型。
    'attachments': Attachment.encodeList(m.attachments),
    // null 和 [] 是两回事，得存得出区别来：取回来要跟存进去的逐字段相等。
    'tool_calls': m.toolCalls == null
        ? null
        : jsonEncode([
            for (final c in m.toolCalls!)
              {'id': c.id, 'name': c.name, 'arguments': c.arguments},
          ]),
    'tool_call_id': m.toolCallId,
    'tool_name': m.toolName,
    'origin': m.origin.name,
  };

  /// 一行 → 一条消息。**解析不出来就整行跳过，不许"半解析"**。
  ///
  /// 库文件在应用目录里，用户导入/手改/旧版本升级都可能留下一行脏数据，
  /// 一行坏数据不该让整个对话（甚至 App 启动）崩掉——这点跟 `SqliteMemoryStore`
  /// 一个态度。但这里还多一条：半条消息比没有更糟。一条丢了 tool_calls 的
  /// assistant 消息会被原样塞回 `AgentLoop` 发给接口，上游回一句笼统的
  /// "参数错误"，而那句话里一个字都不会提到本地库——查起来能把人查死。
  ///
  /// role 认不出时也返回 null，**不猜**：猜成 user 等于把脏数据合法化，
  /// 后果同上。
  static ChatMessage? _messageOf(Map<String, Object?> row) {
    final id = (row['id'] as String?) ?? '';
    final role = _roleOf(row['role'] as String?);
    if (id.isEmpty || role == null) {
      debugPrint('聊天记录行缺 id 或 role 认不出，已跳过：$row');
      return null;
    }

    final List<ToolCall>? toolCalls;
    final List<ImagePart> images;
    try {
      toolCalls = _readToolCalls(row['tool_calls']);
      images = _readImages(row['images']);
    } on FormatException catch (e) {
      debugPrint('聊天记录行的 JSON 列坏掉了，整行跳过：$e');
      return null;
    }
    // 附件列坏掉**不丢整行**：它不是协议的一部分（tool_calls/images 坏了
    // 会让历史不合法），丢的只是一段附加信息，用户那句话还得留住。
    final attachments = _readAttachments(row['attachments']);

    return ChatMessage(
      id: id,
      role: role,
      content: (row['content'] as String?) ?? '',
      createdAt: (row['created_at'] as int?) ?? 0,
      images: images,
      attachments: attachments,
      toolCalls: toolCalls,
      toolCallId: row['tool_call_id'] as String?,
      toolName: row['tool_name'] as String?,
      reasoning: row['reasoning'] as String?,
      // origin 认不出时是 chat，**不是 null**——跟上面 role 认不出就丢整行的
      // 态度相反。role 错了这条消息回传给接口会被拒（协议层不合法），
      // 而 origin 只是个界面上的装饰标记，为它丢掉用户的一句原话不划算。
      // 版本 1 升级上来的老行这一列是 NULL，走的也是这条路。
      origin: MessageOrigin.parse(row['origin'] as String?),
    );
  }

  /// 不认识的 role 一律返回 null。不用 `firstWhere(orElse:)`——那正是"猜一个"。
  static Role? _roleOf(String? raw) {
    for (final r in Role.values) {
      if (r.name == raw) return r;
    }
    return null;
  }

  /// 形状不对就抛 [FormatException]（由 `_messageOf` 整行跳过），**不许挑挑拣拣**：
  /// 少一条 tool_call、少一张图，都是"半解析"，比整行丢掉更难查——
  /// 半条 assistant 消息回传给接口会因为 tool_calls 配不上对被拒，
  /// 而报错里只会说"参数错误"。
  ///
  /// 列是 NULL / 空串时另当别论，那是"没有"，不是"坏了"，返回 null。
  static List<ToolCall>? _readToolCalls(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('tool_calls 列不是 JSON 数组');
    }
    return [
      for (final item in decoded)
        if (item is Map)
          ToolCall(
            id: (item['id'] as String?) ?? '',
            name: (item['name'] as String?) ?? '',
            // arguments 交给模型自己的容错：库里存的是解好的 Map，但万一哪天
            // 有人按线格式（JSON 字符串）写进来，这里照样读得出，不用整行报废。
            arguments: ToolCall.decodeArguments(item['arguments']),
          )
        else
          throw const FormatException('tool_calls 里混进了不是对象的东西'),
    ];
  }

  /// 同 [_readToolCalls]：形状不对就抛，由调用方整行跳过。
  static List<ImagePart> _readImages(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('images 列不是 JSON 数组');
    }
    return [
      for (final item in decoded)
        if (item is Map)
          ImagePart(
            base64Data: (item['base64Data'] as String?) ?? '',
            mimeType: (item['mimeType'] as String?) ?? 'image/png',
          )
        else
          throw const FormatException('images 里混进了不是对象的东西'),
    ];
  }

  /// 附件列：坏了就当没有，**不抛**（见 `_messageOf` 里的说明）。
  static List<Attachment> _readAttachments(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return Attachment.decodeList(decoded);
    } on FormatException catch (e) {
      debugPrint('附件列坏掉了，这条消息按没有附件处理：$e');
      return const [];
    }
  }
}
