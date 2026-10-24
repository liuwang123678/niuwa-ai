import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/n1_core.dart';
import '../models/chat_item.dart';
import '../services/message_store.dart';
import '../services/n1_runtime.dart';

/// 聊天页的状态。
///
/// 职责边界：这个类**只做三件事**——把用户的话发出去、把 agent 事件流翻译成
/// 能画的东西、把该留的留下来。它不做排版、不碰 widget，所以能脱离界面单测。
///
/// 事件流是这里最大的坑：`AgentLoop.run` 的收场有三种——正常跑完、被取消、
/// 出错终止——而三种收场对"历史"的要求完全不同，见 [_finish] 和 [_finishStopped]。
class ChatProvider extends ChangeNotifier {
  // 参数的公开名仍然是 `runtime` / `store`——Dart 会把 `this._x` 的公开名
  // 推导成去掉下划线的那个，跨库调用照旧写 `ChatProvider(runtime: ..., store: ...)`。
  ChatProvider({
    required this._runtime,
    required this._store,
    ReminderStore? reminderStore,
    this.clock,
    this.reminderTick = const Duration(seconds: 15),
  }) : _reminderStore = reminderStore ?? _runtime.reminders;

  final N1Runtime _runtime;

  /// 给设置页读 MCP 连接状态用（连上了哪几台、各自几个工具）。
  N1Runtime get runtime => _runtime;
  final MessageStore _store;

  /// 提醒的存储。默认就是运行时那一个；测试可以塞内存版进来，
  /// 不然跑一次单测会往用户真正的提醒表里写东西。
  final ReminderStore _reminderStore;

  /// 测试用的假时钟。生产上传 null = 用系统时间。
  final DateTime Function()? clock;

  /// 提醒轮询的间隔。
  final Duration reminderTick;

  ReminderScheduler? _scheduler;

  final List<ChatItem> _items = [];

  /// 已经确定下来的线格式历史。下一轮把它当 `history` 传给 agent。
  ///
  /// **它必须跟界面上看到的一一对应**，而且必须自洽。不自洽的后果不是"显示错"，
  /// 而是下一轮请求本身就非法——比如历史里有 assistant 带 tool_calls、却缺了
  /// 对应的 tool 结果，接口会直接 400。
  final List<ChatMessage> _wire = [];

  bool _running = false;
  bool get running => _running;

  bool _loading = true;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  /// 这一轮正在写的那条 assistant。事件都往它身上贴。
  AssistantItem? _streaming;

  /// 已经发出去、但还没被 [_finish] 确认收下的用户输入。
  ///
  /// 为什么单独留一份：正常跑完时它包含在 `RunComplete.produced` 里，但
  /// **中途取消**和**出错终止**这两条路上根本没有 `RunComplete`，用户那句话
  /// 就得靠这里补进历史。不补的话历史会变成「assistant 突然自说自话」。
  UserItem? _pending;

  StreamSubscription<AgentEvent>? _sub;
  N1Session? _session;

  /// 当前会话的任务清单。界面用它在输入框上方显示进度。
  ///
  /// 新会话从空开始；改设置/清空对话会重建会话，清单跟着没了——它是
  /// **这一次任务**的进度，不是跨对话的待办。
  List<TodoItem> get todos => _session?.context.todos.items ?? const [];
  bool _disposed = false;

  /// 欠着一笔"该换会话了"。见 [resetSession]。
  bool _resetWhenIdle = false;

  /// 自动摘要的节拍：这个会话里用户已经说了几句、上一次摘要是第几句、
  /// 一共摘过几次（封顶，避免长对话一直额外请求模型）。
  /// 隔几句做一次摘要。规则本身在 [SummarySchedule] 里，可以单独测。
  /// 10 / 8 是按"一次像样的聊天大约二十来句"定的。
  final SummarySchedule _summarySchedule = SummarySchedule();

  // ── 聊久了别忘前半场 ──

  /// 已经把 `_wire` 的前多少条压进 [_digestText]。
  ///
  /// **这个数只增不减**，因为 `_wire` 只追加不插入。清空对话时一起归零——
  /// 归零漏了的话，下一句会从一条根本不存在的下标开始带历史。
  int _digestCovered = 0;

  /// 压缩过的前半场。null = 还没压过，历史原样全带。
  String? _digestText;

  /// 这次会话压过几次。到 [DigestSchedule.maxRuns] 就停，别每轮都多打一次模型。
  int _digestRuns = 0;

  /// 正在压。同一时刻只允许一个——两个并发的摘要会互相覆盖，而且白花钱。
  bool _digesting = false;

  /// 清空/重载对话时 +1。
  ///
  /// 后台那次压缩可能正好在清空之后才回来，它攥着**上一条对话**的摘要和下标。
  /// 不认代数的话，它会把旧摘要贴到新对话上——症状是用户清空之后聊第一句，
  /// 它突然提起了上一段早就不存在的事，而且没有任何地方看得出为什么。
  int _digestGeneration = 0;

  static const DigestSchedule _digestSchedule = DigestSchedule();

  /// 正在等用户确认的那次工具调用。null = 没有在等。
  ToolApprovalRequest? _pendingApproval;
  ToolApprovalRequest? get pendingApproval => _pendingApproval;

  Completer<ToolApprovalDecision>? _approvalCompleter;

  /// 等用户点弹窗的时限。
  ///
  /// 🩸 **必须是一个独立的、有限的时限**，不能靠 `ToolRegistry` 那个 30 秒
  /// 兜着：
  ///
  ///   - 30 秒太短。用户可能正在开会、在另一个窗口里，他回来点的时候
  ///     "操作已经被拒了"，而他自己什么都没点过。
  ///   - 更要紧的是**必须有个头**。审批等待挂在 `AgentLoop` 那个 `async*`
  ///     生成器的 `await` 上，而 `stop()` 走的是 `_sub.cancel()`——
  ///     生成器停在 await 上就不会被驱动到下一个 `yield`，`finally` 不执行、
  ///     `Completer` 泄漏。没有时限的话那一次 await 永远不会回来。
  ///
  /// 等一下为什么不用 `Future.timeout`：会用，见 [askUser]。
  static const Duration approvalTimeout = Duration(seconds: 120);

  List<ChatItem> get items => List.unmodifiable(_items);

  bool get canRetry => !_running && _error != null && _hasUserItem;

  bool get _hasUserItem => _items.any((i) => i is UserItem);

  void dismissError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  // ────────────────────────────────────────────────────────────────
  // 生命周期
  // ────────────────────────────────────────────────────────────────

  /// 启动时读回上次的对话。
  Future<void> load() async {
    _loading = true;
    _safeNotify();
    try {
      final history = await _store.recent();
      _wire
        ..clear()
        ..addAll(history);
      // 摘要活不了重启（它只活在这次对话里），下标也必须跟着归零。
      _resetDigest();
      _items
        ..clear()
        ..addAll(rebuildItems(history));
      _error = null;
    } catch (e) {
      _error = '读取聊天记录失败：$e';
    } finally {
      _loading = false;
      _safeNotify();
    }

    // 历史读完再开闹钟：补响的那条提醒要插在消息列表末尾，而不是被
    // `_items.clear()` 一并抹掉。
    _startReminders();
  }

  /// 把提醒的轮询支起来。重复调用是幂等的。
  void _startReminders() {
    if (_disposed) return;
    _scheduler ??= ReminderScheduler(
      store: _reminderStore,
      onFire: _onReminderFired,
      clock: clock,
      tick: reminderTick,
    );
    _scheduler!.start();
  }

  /// 一条提醒到点了：落一条消息、放进列表、通知界面。
  ///
  /// 返回消息 id，调度器会把它记回提醒行上（通知点进来要能跳到这条）。
  Future<String?> _onReminderFired(Reminder reminder) async {
    final message = ChatMessage.assistant(
      reminder.message,
      origin: MessageOrigin.reminder,
    );

    // 先落库。落库失败也照样显示——用户此刻更需要在屏幕上看到这句话，
    // 而不是"因为没存上所以它没响"。
    try {
      await _store.append([message]);
    } catch (e) {
      debugPrint('提醒消息落库失败：$e');
    }

    if (_disposed) return message.id;

    _wire.add(message);
    _items.add(
      AssistantItem(
        message.id,
        text: reminder.message,
        streaming: false,
        fromReminder: true,
        at: reminder.firedAt ?? DateTime.now(),
      ),
    );
    _safeNotify();
    return message.id;
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _settleApproval();
    _sub?.cancel();
    _session?.dispose();
    // `dispose()` 只取消一个 Timer，不需要 await。
    unawaited(_scheduler?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────
  // 审批
  // ────────────────────────────────────────────────────────────────

  /// 交给内核的确认通道。`N1Runtime.newSession(approver: ...)` 就是它。
  ///
  /// ⚠️ **同一时刻只会有一次**：`AgentLoop` 是 `for (final call in calls) await
  /// tools.invoke(...)`，工具调用串行执行，所以这里用一个槽位就够了。
  /// 哪天改成并行（`Future.wait`）的话，这里必须跟着改成队列——
  /// 症状会是"两个弹窗互相覆盖，点哪个都不对"。
  Future<ToolApprovalDecision> askUser(ToolApprovalRequest request) async {
    // 已经收摊了就别再弹窗了——弹出来也没人能处理。
    if (_disposed) return const ToolApprovalDecision.denied('这个界面已经关掉了');

    // 自动模式。**每次现读设置**，所以用户在设置里关掉的那一秒就恢复弹窗，
    // 不用重建会话、不用等下一轮。
    //
    // 判定本身在 `AutoApprovalPolicy` 里（能单测）；这里只负责"放行并留痕"。
    // 审计日志那边会把它记成 `auto-ran`，跟用户点过同意的 `ran` 分得开。
    final auto = AutoApprovalPolicy(
      enabled: _runtime.settings.autoApprove,
    ).decide(request);
    if (auto != null) {
      debugPrint('[审批] 自动模式放行：${request.tool}（${request.reason}）');
      return auto;
    }

    final completer = Completer<ToolApprovalDecision>();
    _pendingApproval = request;
    _approvalCompleter = completer;
    _safeNotify();

    final decision = await Future.any(<Future<ToolApprovalDecision>>[
      completer.future,
      // 超时不是"报错"，是一个**正常结局**：内核那边会把它翻成一句
      // "等用户确认超时了，这次没执行"，模型看得懂，用户也不会觉得崩了。
      Future<ToolApprovalDecision>.delayed(
        approvalTimeout,
        () => const ToolApprovalDecision.timedOut(),
      ),
    ]);

    // 只有还挂着的是这一次才清。超时先到、用户后点的话，
    // 这一次已经清过了，别去动下一次的槽位。
    if (identical(_approvalCompleter, completer)) {
      _pendingApproval = null;
      _approvalCompleter = null;
      _safeNotify();
    }
    return decision;
  }

  /// 界面上那个弹窗的回调。
  ///
  /// [approved] 为 false 时 [note] 是用户附带的说明（现在没做输入框，
  /// 留给"点外面/按返回键"那种含糊的拒绝）。
  void resolveApproval({required bool approved, String? note}) {
    final completer = _approvalCompleter;
    if (completer == null || completer.isCompleted) return;

    _pendingApproval = null;
    _approvalCompleter = null;
    completer.complete(
      approved
          ? const ToolApprovalDecision.approved()
          : ToolApprovalDecision.denied(note),
    );
    _safeNotify();
  }

  /// 把挂着的审批收掉（按拒绝）。
  ///
  /// 三个地方要调：`stop()`、出错收摊、`dispose()`。不收的话那个 `await`
  /// 永远不回来，`AgentLoop` 生成器就悬在半空——订阅已经取消了，
  /// 它那点收尾（`finally`）永远不会执行。
  void _settleApproval() {
    final completer = _approvalCompleter;
    if (completer == null) return;
    _pendingApproval = null;
    _approvalCompleter = null;
    if (!completer.isCompleted) {
      completer.complete(const ToolApprovalDecision.denied('这一轮已经停了'));
    }
  }

  /// 设置变过（人设 / 供应商 / 模型 / 温度）之后调。丢掉旧会话，下次发消息时重建。
  ///
  /// **不重建的后果**：`PromptBuilder` 攥着人设的快照、`OpenAiCompatClient`
  /// 攥着接口地址和模型名，改完不重建的话要等 App 重启才生效，用户会以为设置没保存。
  ///
  /// 但正在跑的时候**只记账，不当场丢**：会话底下挂着一条正在读的流，此刻
  /// `dispose()` 会关掉 `ToolContext` 里那个 http.Client，手上这一轮直接断在
  /// 半路——用户只是在设置页点了个供应商，等半天的回复就没了。等这一轮收完摊
  /// 再丢（[_finish] / [_finishStopped] 都会来兑现这笔账）。
  void resetSession() {
    if (_running) {
      _resetWhenIdle = true;
      return;
    }
    _session?.dispose();
    _session = null;
    _resetSummaryClock();
  }

  /// 换了会话就重新数。计数器跟着**这一次会话**走，不是跟着 App 走——
  /// 否则聊了五十句之后新建一个会话，它第一句话说完就立刻做摘要。
  void _resetSummaryClock() => _summarySchedule.reset();

  /// 设置页的「重新连接」：不管配置变没变，都重新起一遍 MCP 服务器。
  ///
  /// 平时走的是 [_run] 里那个按配置指纹判重的 [N1Runtime.ensureMcpReady]；
  /// 这里要的是**重试**——用户可能刚把某个服务器的依赖装好，配置一字没动。
  Future<void> reloadMcp() async {
    await _runtime.ensureMcpReady(force: true);
    _safeNotify();
  }

  /// 兑现 [resetSession] 欠下的那笔。一轮收完摊时调。
  void _dropSessionIfPending() {
    if (!_resetWhenIdle) return;
    _resetWhenIdle = false;
    _session?.dispose();
    _session = null;
    _resetSummaryClock();
  }

  // ────────────────────────────────────────────────────────────────
  // 发送
  // ────────────────────────────────────────────────────────────────

  Future<void> send(
    String text, {
    List<ImagePart> images = const [],
    List<Attachment> attachments = const [],
  }) async {
    final trimmed = text.trim();
    // 图、附件、字**都**空才拦。发一张图或一个文件不写字是合法的。
    if ((trimmed.isEmpty && images.isEmpty && attachments.isEmpty) ||
        _running) {
      return;
    }

    // Key 在**落下这条消息之前**检查。先记后查的话，没有 key 时用户的话会
    // 留在界面上（还进了历史），但他其实一个字都没发出去。
    final key = await _requireKey();
    if (key == null) return;

    final msg = ChatMessage.user(
      trimmed,
      images: images,
      attachments: attachments,
    );
    _pending = UserItem(
      msg.id,
      text: trimmed,
      images: images,
      attachments: attachments,
    );
    _items.add(_pending!);
    _error = null;
    _safeNotify();

    await _run(msg, key);
  }

  /// 重发最后一条用户消息。
  ///
  /// 界面上要把这条及其之后的东西全抹掉——包括那些半截的、失败的回复。
  /// 不抹的话会出现"同一个问题下面挂着两条不同答案"。
  Future<void> retry() async {
    if (_running) return;

    final idx = _items.lastIndexWhere((i) => i is UserItem);
    if (idx < 0) return;
    final old = _items[idx] as UserItem;

    final key = await _requireKey();
    if (key == null) return;

    _items.removeRange(idx, _items.length);

    // 线格式一并回退。找不到就说明它压根没进过历史，那就不用退。
    final wireIdx = _wire.indexWhere((m) => m.id == old.id);
    if (wireIdx >= 0) _wire.removeRange(wireIdx, _wire.length);

    // **重造一条**而不是复用被切掉的那条：复用的话它的 id 已经不在历史里了，
    // 再失败一次时"回退到这条"就会找不到目标。
    final msg = ChatMessage.user(
      old.text,
      images: old.images,
      attachments: old.attachments,
    );
    _pending = UserItem(
      msg.id,
      text: old.text,
      images: old.images,
      attachments: old.attachments,
    );
    _items.add(_pending!);
    _error = null;
    _safeNotify();

    await _run(msg, key);
  }

  /// 停掉当前这一轮。
  ///
  /// 只是取消订阅——`AgentLoop` 那边靠流的取消来收摊，不用额外通知。
  void stop() {
    if (!_running) return;
    // **先**把等着的审批收掉：那一轮可能正卡在弹窗上。直接 cancel 的话
    // 生成器停在 `await approver(...)` 里，永远走不到收尾。
    _settleApproval();
    _sub?.cancel();
    _sub = null;
    _finishStopped();
  }

  Future<void> clear() async {
    // `stop()` 会走 `_finishStopped()`，那里把"被取消的半截话"异步落库
    // （`unawaited(_persist(extra))`）。**不用等它**：`_persist` 里
    // `_store.append` 之前没有任何 await，所以那笔写是在这一行**之前**
    // 同步提交给 sqflite 的，而 sqflite 对同一个库按提交顺序串行执行——
    // 先 append、后 clear，最后是空的。
    //
    // 这条依赖有测试钉着（`message_store_test.dart` 里"先提交 append、
    // 再提交 clear"）。**别在 `_persist` 的 append 之前加 await**，
    // 加了的话那半句话就会落在清空之后，用户下次启动会发现它自己长回来。
    if (_running) stop();
    _items.clear();
    _wire.clear();
    _resetDigest();
    _error = null;
    await _store.clear();
    _safeNotify();
  }

  // ────────────────────────────────────────────────────────────────
  // 内部
  // ────────────────────────────────────────────────────────────────

  /// 拿 key。没有就置错误并返回 null。
  Future<String?> _requireKey() async {
    try {
      final key = await _runtime.loadApiKey();
      if (key != null && key.isNotEmpty) return key;
      _error = '还没设置 API Key。去「设置」里填一个就能开始聊了。';
    } catch (e) {
      _error = '读不到 API Key（$e）。去「设置」里重新填一次。';
    }
    _safeNotify();
    return null;
  }

  Future<void> _run(ChatMessage input, String apiKey) async {
    _running = true;
    _safeNotify();

    // 浏览器**不在这里预热**：预热会开一个看得见的 Edge 窗口，而发一句
    // "在吗"根本用不上浏览器。工具注册不再依赖"已经热好"（看
    // `BrowserDriver.supportsWarmUp`），真要用的时候由 `browser_open` 那一层
    // 现热。这里只等解释器。
    // 探解释器一般几十毫秒，boot 时就后台开始探了，走到这儿基本已经好了。
    await _runtime.ensureCodeRunnerReady();
    // 连 MCP 服务器。只在配置变过的那一轮真的去连，之后是一次字符串比较。
    // 连不上的服务器不会抛——它会记进 `mcpErrors`，设置页能看到原因。
    await _runtime.ensureMcpReady();
    if (_disposed) return;
    // 连完刷一下：设置页要在这一轮之后显示连上了几个工具、哪台没连上。
    _safeNotify();
    // 用户在等预热的那一下按了"停"：`stop()` 已经把 `_running` 收掉了，
    // 这时候要是接着往下跑，这一轮的事件会喂给一个已经收过摊的 provider。
    if (!_running) return;

    _session ??= _runtime.newSession(apiKey: apiKey, approver: askUser);
    final session = _session!;

    // 这个会话可能是**之前**建的（那会儿浏览器还没热好），所以每一轮都补一次。
    // 幂等，补过了就是一次 bool 判断。不补的话，第一句话之后建的会话会
    // 永远看不见 browser_* 工具，模型只能说"做不到"——正是用户报的那个症状。
    session.installBrowserTools(_runtime.browser);
    // 跑代码那边同理，而且它更依赖这个"每轮补一次"：解释器探测是异步的，
    // 第一轮建会话时**多半还没探完**，`run_code` 要等预热结束才补得进来。
    //
    // ⚠️ `allowed` 必须每一轮都**照现在的设置**传（不能只靠 newSession 那次）：
    // `installCodeTools` 是"没装过就装"，会装在**旧会话**上。用户关掉总开关
    // 之后 `resetSession()` 是异步兑现的（正在跑的时候只记账），这中间任何
    // 一轮补装都会把工具塞回一个本该没有它们的会话里。
    final allowed = _runtime.settings.allowCodeTools;
    session.installCodeTools(_runtime.codeRunner, allowed: allowed);
    // 文件工具。安卓上 `fileAccess` 是 null——那是"这个平台上不给"，不是错误。
    final fs = _runtime.fileAccess;
    if (fs != null) {
      session.installFileTools(
        paths: fs.paths,
        policy: fs.policy,
        backups: fs.backups,
        allowed: allowed,
      );
    }
    // MCP 工具每一轮补一次：会话可能是上一轮建的，那会儿服务器还没连完。
    session.installMcpTools(_runtime.mcpConnections);

    // id 单独生成，**不复用用户那条的**。复用会让 ListView 里两条记录撞 key，
    // 而且"这条 assistant 到底对应哪句用户输入"以后就没法靠 id 追了。
    final item = AssistantItem(newId('ui'), at: DateTime.now());
    _streaming = item;
    _items.add(item);
    _safeNotify();

    // 按这一句话去记忆库里捞相关的事。**等它**——本地 SQLite，几十毫秒，
    // 而它直接影响这一轮的回答质量。捞失败就算了，不能因此不发消息。
    final recalled = await _recallFor(input);
    if (!_running) return;

    // 聊长了就在后台压一次前半场。**不 await**：这一轮用现有摘要（可能还没有），
    // 压完下一轮自然带上。多等一次模型调用才回话是不可接受的。
    _maybeDigest(session);

    // history 里不能含这条 input——loop 自己会把它接在最后。
    //
    // 已经压进摘要的那一段**不再重发**：摘要就是它的替身。注意要在
    // `pruneOldImages` **之前**切——那个函数会整条丢掉"只有图、没有字"的
    // 老消息，先切后切的下标对不上，会漏掉或多带几条。
    final covered = _digestText == null
        ? 0
        : _digestCovered.clamp(0, _wire.length);
    final visible = covered == 0 ? _wire : _wire.sublist(covered);

    // 只带最近 3 组带图的消息：图是这条链路上最贵的东西，而更早那些图
    // **再也不会被发出去了**。库里的一个字都不动——用户往上翻还能看见。
    //
    // 再按工作强度砍掉太老的一段。标准档是"不限"，所以这一步默认什么都不做：
    // 加这个旋钮之前的行为一个字都没变。
    final history = List<ChatMessage>.unmodifiable(
      AgentLoop.trimHistory(
        pruneOldImages(visible),
        _runtime.settings.workLevel.historyMessages,
      ),
    );

    // 裁剪是个看不见的行为（界面不变、库里也不变），而它没有单测。
    // 所以留一条日志，让真跑能验证它。连发纯图时，这里打印的**带图条数**
    // 是 min(k-1, 3)：第 1 次是 0（本条还没进历史），之后 1 → 2 → 3，
    // 从第 4 次起封顶 3、不再涨。
    //
    // 上面那个"带图条数"只数**历史**里的，不含本轮这一张——所以一次请求
    // 实际可能带 4 张图（3 张历史 + 本轮 1 张）。要盯的是"封顶 3"，不是总数。
    debugPrint(
      '[chat] 发出历史 ${history.length} 条，其中带图 '
      '${history.where((m) => m.images.isNotEmpty).length} 条',
    );

    final done = Completer<void>();
    _sub = _session!.loop
        .run(
          history: history,
          input: input,
          recalled: recalled,
          conversationSummary: _digestText,
        )
        .listen(
      _onEvent,
      onError: (Object e, StackTrace _) {
        _fail('出了点问题：$e');
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    await done.future;

    // 这一轮结束了。摘要放在后面**不 await**：它要再请求一次模型，
    // 等它会让"忙碌"的状态多挂好几秒，或者用户已经接着问下一句了。
    //
    // 用局部的 [session] 而不是 `_session`：这一轮里用户可能刚改过设置，
    // `_dropSessionIfPending` 已经把引用置空了，但手上这份还能用。
    _maybeSummarize(session.summarizer);
  }

  /// 攒够一段对话就让模型回头挑几条值得记的。
  ///
  /// 这件事只能发生在**这一轮彻底结束之后**：摘要要读完整对话，
  /// 而在流式过程中 `_wire` 还是半截的。
  ///
  /// 失败、超时、模型不听话，全都只当这次没发生——见 [MemorySummarizer]。
  void _maybeSummarize(MemorySummarizer? summarizer) {
    if (summarizer == null) return;
    if (!_summarySchedule.tick()) return;

    // 拷一份再交出去：摘要跑着的时候用户可能接着聊，`_wire` 会继续长，
    // 而 `await for` 遍历一个正在被改的列表是未定义行为。
    final transcript = List<ChatMessage>.of(_wire);
    unawaited(_summarize(summarizer, transcript));
  }

  Future<void> _summarize(
    MemorySummarizer summarizer,
    List<ChatMessage> transcript,
  ) async {
    try {
      final saved = await summarizer.summarize(transcript);
      if (saved > 0) debugPrint('[记忆] 自动摘要收下了 $saved 条');
    } catch (e) {
      // 摘要器自己已经吞了异常；这里是最后一道，防止以后有人改坏它。
      debugPrint('[记忆] 自动摘要出错：$e');
    }
  }

  /// 按用户刚说的这句话去记忆库里捞相关旧事。
  ///
  /// 为什么不能只靠 system prompt 里那份索引：索引是**固定按重要度取的**，
  /// 永远就那几条。用户一句"我妈下周过生日"，真正该浮出来的是三个月前记的
  /// "妈妈有糖尿病，不吃甜的"——而它多半不在前 20 条里。
  ///
  /// 已经在索引里的**不再重复注入**：同一句话在 system prompt 和用户消息里
  /// 各出现一次，白花 token，还让模型觉得这事特别重要。
  Future<List<MemoryEntry>> _recallFor(ChatMessage input) async {
    final query = input.content.trim();
    if (query.isEmpty) return const [];
    try {
      final level = _runtime.settings.workLevel;
      if (level.recallLimit <= 0) return const [];
      final known = (await _runtime.memory.index(
        limit: level.memoryIndexLimit,
      )).map((e) => e.id).toSet();
      final hits = await _runtime.memory.search(
        query,
        limit: level.recallLimit + known.length,
      );
      final fresh = hits.where((e) => !known.contains(e.id));
      final picked = fresh.take(level.recallLimit).toList();
      if (picked.isNotEmpty) {
        debugPrint('[记忆] 按这句话捞到 ${picked.length} 条相关旧事');
      }
      return picked;
    } catch (e) {
      // 捞记忆失败不该让这句话发不出去。
      debugPrint('[记忆] 按话题捞记忆失败：$e');
      return const [];
    }
  }

  // ────────────────────────────────────────────────────────────────
  // 聊久了别忘前半场
  // ────────────────────────────────────────────────────────────────

  /// 条件够了就在后台压一次前半场。**不阻塞任何东西**。
  void _maybeDigest(N1Session session) {
    if (_digesting || _disposed) return;
    final plan = _digestSchedule.plan(
      _wire,
      covered: _digestCovered,
      runs: _digestRuns,
    );
    if (plan == null) return;

    final (start, end) = plan;
    // 拷一份再交出去：压的过程中用户可能接着聊，`_wire` 会继续长。
    final chunk = List<ChatMessage>.of(_wire.sublist(start, end));
    _digesting = true;
    unawaited(
      _runDigest(
        ConversationDigester(llm: session.loop.llm),
        chunk: chunk,
        covered: end,
        generation: _digestGeneration,
      ),
    );
  }

  Future<void> _runDigest(
    ConversationDigester digester, {
    required List<ChatMessage> chunk,
    required int covered,
    required int generation,
  }) async {
    try {
      final text = await digester.digest(previous: _digestText, chunk: chunk);
      if (text == null || _disposed) return;
      // 这期间用户清空或重载过对话：这份摘要是上一条对话的，扔掉。
      if (generation != _digestGeneration) return;
      _digestText = text;
      _digestCovered = covered;
      debugPrint('[对话] 前 $covered 条已压成 ${text.length} 字摘要');
    } catch (e) {
      // 压不成就算了，旧摘要继续用——这是后台动作，不许影响对话。
      debugPrint('[对话] 压缩前半场失败：$e');
    } finally {
      // **尝试次数也算进上限**：模型一直返回空或者网络一直断的话，
      // 不数它就会每一轮都多打一次模型，白烧钱还没有进展。
      _digestRuns++;
      _digesting = false;
    }
  }

  /// 清空对话时一起归零。漏掉的话，下一句会从一个不存在的下标开始带历史。
  void _resetDigest() {
    _digestText = null;
    _digestCovered = 0;
    _digestRuns = 0;
    _digesting = false;
    _digestGeneration++;
  }

  /// 事件入口。**只管兜底**，真正的处理在 [_applyEvent]。
  ///
  /// 为什么要多这一层：事件回调里抛的异常**没有任何人接**。`main.dart` 里
  /// 没有 `runZonedGuarded`，也没有 `PlatformDispatcher.onError`；而
  /// `StreamSubscription` 对 `onData` 里抛的异常一律丢给根 zone 就完事，
  /// 既不调 `onError`、也不取消订阅。release 包里的表现是**彻底静默**——
  /// 界面不报错、不刷新，只是"这一个事件没发生过"。
  ///
  /// 这不是假想的防线：`AssistantItem.tools` 那个 `const []` 的坑就是这么活
  /// 下来的，而它吃掉的恰好是**全部工具痕迹**。用户看到的只是"它好像什么都
  /// 没干"，于是"模型从不主动用技能"这句话既没法证伪也没法验证。
  ///
  /// 兜底不等于吞掉——打出来，并且**照样 notify**（原来那句 `_safeNotify()`
  /// 写在 switch 后面，异常一抛就整个跳过，界面连刷新都没有了）。
  void _onEvent(AgentEvent event) {
    if (_disposed) return;
    try {
      _applyEvent(event);
    } catch (e, stack) {
      debugPrint('[chat] 处理 ${event.runtimeType} 时出错：$e');
      debugPrintStack(stackTrace: stack);
    }
    // 正文/思考的增量一秒来几十上百条，压一下；其余事件立刻刷。
    if (event is TextDelta || event is ReasoningDelta) {
      _notifySoon();
    } else {
      _safeNotify();
    }
  }

  void _applyEvent(AgentEvent event) {
    final item = _streaming;

    switch (event) {
      // 工具跑完接着跑的那一轮，界面上不该多出一个新气泡。
      case TurnStarted():
        break;

      case TextDelta(:final text):
        if (item != null) item.text += text;

      case ReasoningDelta(:final text):
        if (item != null) item.reasoning += text;

      case ToolCallStarted(:final call):
        item?.tools.add(ToolTrace(call));

      case ToolCallFinished(:final invocation):
        // 按 id 找对应的那条，而不是取最后一条——模型一次可以并行发多个工具
        // 调用，回填顺序不保证。
        for (final t in item?.tools ?? const <ToolTrace>[]) {
          if (t.call.id == invocation.call.id) {
            t.finish(invocation);
            break;
          }
        }

      case UsageReported(:final usage):
        if (item != null) item.usage = usage;

      case ContextTrimmed():
        if (item != null) item.contextTrimmed = true;

      // 一轮说完。**不在这里收摊**——后面可能还有续跑的轮次。
      // 落库统一等 RunComplete，因为它给的 produced 才是完整的一串。
      case TurnComplete():
        break;

      case RunComplete(:final produced, :final stopReason):
        _finish(produced: produced, stopReason: stopReason);

      case AgentFailed(:final message):
        _fail(message);
    }
  }

  /// 正常跑完。
  void _finish({
    required List<ChatMessage> produced,
    required String? stopReason,
  }) {
    final item = _streaming;
    if (item != null) {
      item.streaming = false;
      item.stopReason = stopReason;
    }

    // produced 是这一轮产生的**全部**消息（用户输入 + assistant + tool 结果），
    // 直接用它落库，不要自己去拼——拼出来的很可能跟 agent 实际发出去的不一样。
    _wire.addAll(produced);

    _pending = null;
    _streaming = null;
    _running = false;
    _sub = null;

    // 收摊之后才动会话。这一刻 RunComplete 已经推出来了，生成器只剩一句 return，
    // 关掉 http.Client 不会截断任何还没吐完的东西。
    _dropSessionIfPending();

    unawaited(_persist(produced.where(_storable).toList()));
    _safeNotify();
  }

  /// 中途被取消 / 出错终止。
  ///
  /// 这两种情况都没有 `RunComplete`，拿不到 `produced`，只能自己把半截现场
  /// 补成一段**合法的**历史：
  ///
  /// - 用户那句话要补进去，否则历史变成 assistant 自说自话；
  /// - 半截正文只有在非空时才补，而且**不带 tool_calls**。
  ///
  /// 剥掉 tool_calls 的理由很实在：协议要求 assistant 的每个 tool_call 后面
  /// 必须紧跟一条对应的 tool 结果。取消发生在工具执行中的话，结果永远不会来了，
  /// 带着 tool_calls 的这条消息会让下一轮请求直接 400。
  void _finishStopped() {
    // 这一条是给"出错终止"那条路兜的（`stop()` 里已经收过一次）。
    // 弹窗还挂在那儿、用户还在读那段命令的时候这一轮就没了——不收回来的话,
    // 他点下去的时候一切都结束了，而弹窗自己不会消失。
    _settleApproval();

    final item = _streaming;
    if (item != null) {
      item.streaming = false;
      item.stopReason = 'stopped';
    }

    final extra = <ChatMessage>[];

    final pending = _pending;
    if (pending != null) {
      final user = _wire.lastWhere(
        (m) => m.id == pending.id,
        orElse: () =>
            ChatMessage.user(pending.text, images: pending.images),
      );
      _wire.add(user);
      extra.add(user);
    }

    final text = item?.text.trim() ?? '';
    if (text.isNotEmpty) {
      final partial = ChatMessage.assistant(text);
      _wire.add(partial);
      extra.add(partial);
    }

    if (extra.isNotEmpty) unawaited(_persist(extra));

    _pending = null;
    _streaming = null;
    _running = false;
    _sub = null;

    // 被取消 / 出错收的摊，同样得把欠的那笔兑现——否则用户"停止"之后再改设置，
    // 下一句还是拿旧会话旧的接口地址发出去。
    _dropSessionIfPending();

    _safeNotify();
  }

  void _fail(String message) {
    // 已经收过摊了（比如 RunComplete 之后 onError 又补了一枪）就不要再动历史。
    if (!_running) return;
    _error = message;
    _finishStopped();
  }

  static bool _storable(ChatMessage m) => m.role != Role.system;

  /// 把存下来的历史**连工具痕迹一起**重建出来。
  ///
  /// 为什么要专门做这件事：[_visible] 把 `Role.tool` 滤掉了（这没错——内容已经
  /// 挂在对应的 assistant 痕迹上，再画一遍是重复），而 [_toItem] 重建 assistant
  /// 时只带 text 和 reasoning。于是**重启之后工具痕迹全没了**：回头看不见它上
  /// 一次读过哪个技能、开过哪个网页、点了什么。reasoning 反倒留着，这个不对称
  /// 一直没人注意。
  ///
  /// 而现在「模型到底用没用技能」唯一的验证手段就是这个痕迹。它不能是一次性的。
  ///
  /// 配对靠 `tool_call_id`，**不靠顺序**：模型一次可以并行发好几个调用，结果
  /// 回来的顺序不保证，中间还可能夹着别的消息。
  ///
  /// 写成公开的 static 是为了**不 boot 整个运行时就能测它**：`ChatProvider`
  /// 的构造要一个 `N1Runtime`，那东西在单测里起不来（插件、磁盘、rootBundle），
  /// 于是这个类是零覆盖的。而这段偏偏是"重启后还看不看得见工具痕迹"的全部实现。
  @visibleForTesting
  static List<ChatItem> rebuildItems(List<ChatMessage> history) {
    final recorded = <String, ChatMessage>{};
    for (final m in history) {
      if (m.role == Role.tool && m.toolCallId != null) {
        recorded[m.toolCallId!] = m;
      }
    }

    final out = <ChatItem>[];
    for (final m in history) {
      if (!_visible(m)) continue;
      final item = _toItem(m);

      final calls = m.role == Role.assistant ? m.toolCalls : null;
      if (item is AssistantItem && calls != null) {
        for (final call in calls) {
          final trace = ToolTrace(call);
          final result = recorded[call.id];
          trace.result = result == null
              // 结果没留下来（写到一半被杀掉之类）。**不能留空**：
              // `ToolTrace.running` 的定义就是 `result == null`，留空的话
              // 界面上那个转圈会一直转下去，比直说"没记下结果"误导得多。
              ? const ToolResult.fail('这次调用的结果没留在记录里')
              : ToolResult.fromModelText(result.content);
          item.tools.add(trace);
        }
      }

      out.add(item);
    }
    return out;
  }

  /// tool 消息不单独显示——内容已经挂在对应的 [ToolTrace] 上了，再画一遍是重复。
  static bool _visible(ChatMessage m) => switch (m.role) {
    Role.user => true,
    // 思考过程也要留着，否则重启后那一条会变成空气泡——用户明明记得
    // 当时有内容，现在没了。
    Role.assistant =>
      m.content.trim().isNotEmpty ||
      (m.reasoning ?? '').trim().isNotEmpty ||
      // 一个字的正文都没有、只调了工具的那一轮，**也必须留着**。
      //
      // 这条原本是漏的，而且漏得很关键：带 tool_calls 的 assistant 大多正文为空
      // （模型先发调用、拿到结果才开口），滤掉它就等于把它的工具痕迹一起扔掉。
      // 而"它读没读技能、开没开网页"恰恰只记在这些痕迹里——滤掉之后重启一次
      // 就什么都看不见了，连"模型到底用没用技能"都无从判断。
      m.toolCalls?.isNotEmpty == true,
    Role.tool || Role.system => false,
  };

  static ChatItem _toItem(ChatMessage m) {
    switch (m.role) {
      case Role.user:
        return UserItem(
          m.id,
          text: m.content,
          images: m.images,
          attachments: m.attachments,
        );

      case Role.assistant:
        return AssistantItem(
          m.id,
          text: m.content,
          reasoning: m.reasoning ?? '',
          streaming: false,
          fromReminder: m.origin == MessageOrigin.reminder,
          at: DateTime.fromMillisecondsSinceEpoch(m.createdAt),
        );

      case Role.tool:
      case Role.system:
        // _visible 已经滤掉了，这里只是 switch 要穷尽。真漏进来一条，
        // 显示个空气泡也比崩掉强。
        return AssistantItem(m.id, streaming: false);
    }
  }

  Future<void> _persist(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    try {
      await _store.append(messages);
    } catch (e) {
      // 存不上不该打断对话——用户还在聊。但要说一声，不然下次启动发现
      // 记录缺了一段会莫名其妙。
      debugPrint('聊天记录落库失败：$e');
      _error = '聊天记录没能保存，重启后这一段会丢。';
      _safeNotify();
    }
  }

  void _safeNotify() {
    if (_disposed) return;
    // 有一笔拖延中的刷新就作废它：马上要刷的这次已经是更新的状态了。
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _lastNotify = DateTime.now();
    notifyListeners();
  }

  /// 流式输出时把刷新压到约两帧一次。
  ///
  /// 每个 token 都 notify 的话，一秒能有几十上百次 `setState`：整条消息列表
  /// 重新构建、markdown 重新解析、布局重新算。界面看起来不是"更快"，
  /// 而是更卡、更烫。压到 32ms 肉眼分辨不出来，构建次数却降一个量级。
  ///
  /// **只用在正文/思考的增量上**。工具开始/结束、这一轮收尾、报错这些
  /// 都要立刻反映出来——那些本来就没几次。
  void _notifySoon() {
    if (_disposed || _notifyTimer != null) return;
    const minGap = Duration(milliseconds: 32);
    final since = DateTime.now().difference(_lastNotify);
    if (since >= minGap) {
      _lastNotify = DateTime.now();
      notifyListeners();
      return;
    }
    _notifyTimer = Timer(minGap - since, () {
      _notifyTimer = null;
      _lastNotify = DateTime.now();
      if (!_disposed) notifyListeners();
    });
  }

  Timer? _notifyTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
}
