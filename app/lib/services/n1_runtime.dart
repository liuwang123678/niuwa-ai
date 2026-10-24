import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
// 只取 ffi 那两样。整个 import 进来的话，`sqflite_ffi` 会把 sqflite 的东西
// 再导出一遍，跟上面那行撞成 "unnecessary_import"。
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show sqfliteFfiInit, databaseFactoryFfi;

import '../core/n1_core.dart';
import 'browser/browser_driver_factory.dart';
import 'code/code_runner_factory.dart';
import 'db.dart';
import 'db_schema.dart';
import 'fs/file_access.dart';
import 'fs/local_code_audit_log.dart';
import 'message_store.dart';
import 'reminder_store.dart';
import 'secure_store.dart';
import 'skill_loader.dart';

/// 一台已经连上的 MCP 服务器。
typedef McpConnection = ({
  McpServerConfig config,
  McpClient client,
  List<McpToolInfo> tools,
});

/// 把内核需要的依赖装好，交给界面。
///
/// 界面**不该自己 new 内核里的东西**——想跑一轮对话就问这里要 [N1Session]。
/// 这样换存储、换模型、加工具都只改这一个文件，不会牵到页面里去。
///
/// 生命周期：进程内一个。`main()` 里 boot 一次，塞进 `Provider`。
class N1Runtime {
  N1Runtime._({
    required this.secure,
    required this.settings,
    required this.memory,
    required this.messages,
    required this.reminders,
    required this.skillLoader,
    required this.browser,
    required this.codeRunner,
    required this.fileAccess,
    required this.auditLog,
  });

  final SecureStore secure;
  final SettingsStore settings;
  final SqliteMemoryStore memory;

  /// 聊天记录。
  final SqliteMessageStore messages;

  /// 提醒。跟聊天记录共用同一个打开的库。
  final SqliteReminderStore reminders;

  final SkillLoader skillLoader;
  final BrowserDriver browser;

  /// 代码执行器。Windows 上是真起子进程，安卓上是借 WebView 跑 JS。
  final CodeRunner codeRunner;

  /// 文件工具的依赖。**null = 这个平台上不给文件工具**（现在就是安卓）。
  ///
  /// 成因见 `createFileAccess` 的文档：安卓的存储模型下绝大多数路径读写不了。
  final FileAccess? fileAccess;

  /// 跑命令 / 动文件的流水账。桌面和手机都记——手机上跑的是 JS，一样是
  /// "在用户设备上执行东西"。
  final CodeAuditLog auditLog;

  /// 当前技能表。用户在技能页改过文件后调 [reloadSkills] 刷新。
  SkillRegistry skills = SkillRegistry();

  String _builtInPersona = '你是 N1。';

  String get builtInPersona => _builtInPersona;

  /// 当前生效的人设：用户覆盖优先，否则用内置的。
  String get persona {
    final override = settings.personaOverride.trim();
    return override.isEmpty ? _builtInPersona : override;
  }

  bool get hasApiKey => _cachedKey != null;
  String? _cachedKey;

  /// 缓存的是哪一家的 Key。换了供应商就得作废——各家 Key 不是一回事，
  /// 拿着上一家的去请求新那家，只会换回一个 401。
  String? _cachedKeyProvider;

  /// 从安全存储里读一次 key 并缓存。改了 key 或换了供应商之后要调 [refreshApiKey]。
  ///
  /// 缓存是因为聊天页每次发消息都要用，而安全存储在某些安卓机型上是真的慢
  /// （要过一次 Keystore）。一个进程里 key 不会自己变。
  Future<String?> loadApiKey() async {
    final current = settings.providerId;
    if (_cachedKeyProvider != current) {
      _cachedKey = null;
      _cachedKeyProvider = current;
    }
    _cachedKey ??= await secure.readApiKey(providerId: current);
    return _cachedKey;
  }

  Future<void> refreshApiKey() async {
    final current = settings.providerId;
    _cachedKeyProvider = current;
    _cachedKey = await secure.readApiKey(providerId: current);
  }

  /// 桌面端必须先换成 FFI 工厂，否则后面 `openDatabase` 会直接抛
  /// "databaseFactory not initialized"——那句话里一个字都不会提"平台不对"，
  /// 而且它在**安卓上永远不会发生**，所以只跑安卓是发现不了的。
  ///
  /// 只在桌面换：[databaseFactoryFfi] 会去加载系统里的 libsqlite3，
  /// 而安卓根本没有这个 so（它用的是框架自带的 SQLite），覆盖了就是等着崩。
  static void _configureDatabaseFactory() {
    if (kIsWeb) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  /// 启动。
  static Future<N1Runtime> boot() async {
    _configureDatabaseFactory();

    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);

    // 记忆和聊天记录共用 `n1.db`。**必须只开一次**——两个 store 各自
    // `openDatabase(path, version: 1, onCreate: ...)` 的话，第二个会看到文件
    // 已经是 version 1 而跳过 onCreate，它那张表永远建不出来。发作形态很阴：
    // 首次启动一切正常，聊到第一次该落库时才炸 "no such table"。
    // 所以库和表都在这里一次建好，再分给各个 store。
    final db = await _openDatabase(p.join(support.path, 'n1.db'));

    final runtime = N1Runtime._(
      secure: SecureStore(),
      settings: await SettingsStore.open(),
      memory: SqliteMemoryStore.fromDatabase(db),
      messages: SqliteMessageStore.fromDatabase(db),
      reminders: SqliteReminderStore.fromDatabase(db),
      skillLoader: await SkillLoader.forApp(),
      // Windows 会给一个 CDP 驱动（拉起临时 Edge），Android 现在还是一句
      // "还没做"——见工厂里的说明。**仍然是"不可用就不注册工具"这个约定**：
      // isAvailable=false 时模型看不见 browser_*，不会去反复试。
      browser: createBrowserDriver(),
      // 跑代码。Windows 上会起子进程，所以它也是"预热完才知道能用什么"。
      codeRunner: createCodeRunner(),
      // 文件工具。**安卓上是 null**（不给就是不注册，见 createFileAccess）。
      fileAccess: await createFileAccess(appSupport: support),
      // 明文一行一条，追加写。用户在设置页看不到它，但它是"事后能查"的
      // 唯一手段——前面几层拦的都是当下。
      auditLog: LocalCodeAuditLog(
        file: File(p.join(support.path, 'code-audit.log')),
      ),
    );

    runtime._builtInPersona = await _loadPersona();
    await runtime.reloadSkills();

    // **浏览器不在这里预热。** 预热在 Windows 上会拉起一个看得见的 Edge
    // 窗口（`about:blank`），于是每次打开 App 都弹一个网页出来——用户根本
    // 还没打算上网。改成"模型第一次真要用浏览器"时由工具自己预热
    // （`_BrowserTool.withDriver`），聊天路径上一分钱不花。
    //
    // 探解释器比拉浏览器快得多（两次 `--version`），而且完全不可见，
    // 所以照旧后台热，一样不挡首帧。
    unawaited(runtime.ensureCodeRunnerReady());

    return runtime;
  }

  /// 浏览器预热的状态。第一次调用触发 [BrowserDriver.warmUp]，之后只等
  /// 同一个 future——**幂等是硬要求**，重复调不能拉起第二个浏览器。
  Future<void>? _warming;

  /// 确保浏览器就绪，返回它现在能不能用。**不抛异常**（失败只表现为
  /// 返回 false），因为它在发消息的路径上，不该把一轮对话拦下来。
  Future<bool> ensureBrowserReady() async {
    _warming ??= browser
        .warmUp()
        // 驱动自己承诺不抛，但这是契约不是保证：真抛了就在这里吞掉。
        // 不放这儿的话它就是个 unhandled async error，直接打崩 zone。
        .catchError((Object e) => debugPrint('[browser] 预热失败：$e'));
    await _warming;
    return browser.isAvailable;
  }

  /// 探解释器的状态。跟浏览器那套一样，**幂等**，重复调等的是同一个 future。
  Future<void>? _warmingCode;

  /// 确保代码执行器就绪，返回它现在能不能跑脚本。
  ///
  /// **不抛异常**，理由跟 [ensureBrowserReady] 一样：它在发消息的路径上，
  /// 不该把一轮对话拦下来。
  ///
  /// ⚠️ 返回 false **不代表 `run_command` 也不能用**——那个跟解释器没关系，
  /// 只看 `supportsCommand`。
  Future<bool> ensureCodeRunnerReady() async {
    _warmingCode ??= codeRunner
        .warmUp()
        .catchError((Object e) => debugPrint('[code] 预热失败：$e'));
    await _warmingCode;
    return codeRunner.isAvailable;
  }

  /// 重新从磁盘加载技能。用户在技能页改过 `SKILL.md` 之后调。
  ///
  /// 解析失败的文件由 [SkillLoader.load] 自己打日志跳过，这里不用管。
  Future<void> reloadSkills({bool forceRefresh = false}) async {
    skills = await skillLoader.load(forceRefresh: forceRefresh);
  }

  /// 无条件注册的内置工具。
  ///
  /// **抽出来是为了能测**：`newSession` 要 boot 整个运行时（插件、磁盘、
  /// rootBundle），单测里起不来，于是「提醒工具到底注册了没有」就成了一句
  /// 没法验证的话——真出问题时的症状是「N1 说它设好了，其实没设」。
  /// 让 newSession 和测试走同一个函数，就不存在「代码里注册了、测试测的是
  /// 另一份抄来的清单」这种假绿。
  ///
  /// 浏览器工具**不在这里**：它们按 [BrowserDriver.isAvailable] 决定注不注册，
  /// 见 [N1Session.installBrowserTools]。
  ///
  /// 顺序无所谓——`ToolRegistry.specs` 按名字排，发给模型的工具表是稳定的。
  static List<N1Tool> alwaysOnTools() => [
    GetTimeTool(),
    const HttpFetchTool(),
    const MemorySaveTool(),
    const MemorySearchTool(),
    const SkillListTool(),
    const SkillReadTool(),
    const TodoWriteTool(),
    ReminderCreateTool(),
    const ReminderListTool(),
  ];

  /// 浏览器工具注册时用的超时。
  ///
  /// `ToolRegistry` 默认 30 秒，而"打开一个慢站 + 等它稳定"很容易撞线。
  /// 撞线的症状是模型收到"超时了"——它会以为这个站打不开，然后放弃。
  static const browserToolTimeout = Duration(seconds: 60);

  /// 跑代码的工具超时。
  ///
  /// ⚠️ **必须比执行器自己的硬上限（`ProcessCodeRunner.maxTimeout`，120 秒）宽**。
  /// 反过来就是注册表先超时：执行器那边进程还活着、看门狗还没响，而模型已经
  /// 收到一句注册表的"超时"——那句话既不说是谁超时、也不说进程杀没杀。
  /// 最里面那层先到点，说的才是人话（「超时了，进程已经被杀掉」）。
  ///
  /// 所以这一层是**兜底**，正常情况下永远轮不到它。
  static const codeToolTimeout = Duration(seconds: 150);

  /// MCP 工具的超时。
  ///
  /// 比默认的 30 秒宽：外面那些服务器可能连数据库、调远程接口，慢是正常的。
  /// 但也不能无限等——注册表这一层超时了，模型至少还能收到一句话。
  static const mcpToolTimeout = Duration(seconds: 60);

  /// 子代理的超时。
  ///
  /// 它内部要跑好几轮模型调用加工具调用，30 秒连一次像样的调研都跑不完。
  /// 五分钟是个上限而不是预期——正常任务通常一两分钟就回来了。
  static const subagentToolTimeout = Duration(minutes: 5);

  /// 开一次会话。
  ///
  /// 每次开都新造工具表和 context，而不是全局复用一份：这两样都跟着"当前技能
  /// 是什么"走，而技能是可以在运行时重载的。旧的要 [N1Session.dispose]——
  /// [ToolContext] 里攥着一个 `http.Client`，不关就是连接泄漏。
  ///
  /// [approver] 是"这个危险操作要不要做"的确认通道。**不传就等于没有通道**：
  /// 内核遇到需要审批的调用会按**拒绝**处理，不是放行。见 `ToolContext.approver`。
  N1Session newSession({required String apiKey, ToolApprover? approver}) {
    final level = settings.workLevel;

    // 总开关。关掉 = 文件类和代码类工具**一个都不注册**。
    // 不注册而不是"注册了再返回不支持"：模型看不见就不会去调，也不会在
    // 说不了话的时候编一个"我做不到"出来。开关改完要重建会话才生效。
    final allowed = settings.allowCodeTools;

    final tools = ToolRegistry()
      // 工作强度里唯一跟"注册表"有关的一项：单条工具结果能回喂多少字。
      // 设在这里而不是 invoke 里现取——`invoke` 是纯内核，不认识设置。
      ..resultChars = level.toolResultChars
      // 记账的口子挂在注册表上，见 `ToolRegistry.audit`。
      ..audit = auditLog;
    for (final tool in alwaysOnTools()) {
      tools.register(tool);
    }

    final context = ToolContext(
      memory: memory,
      skills: skills,
      browser: browser,
      reminders: reminders,
      approver: approver,
      logger: (m) => debugPrint('[tool] $m'),
    );

    // 接哪家、用哪个模型，全从设置里现取。这里不写死任何一家——
    // 用户在设置页改完就开新会话，下一句就是新配置。
    final llm = OpenAiCompatClient(
      apiKey: apiKey,
      baseUrl: settings.effectiveBaseUrl,
      model: settings.effectiveModel,
      temperature: settings.temperature,
    );

    final session = N1Session(
      tools: tools,
      context: context,
      level: level,
      summarizer: MemorySummarizer(llm: llm, memory: memory),
      loop: AgentLoop(
        llm: llm,
        tools: tools,
        context: context,
        maxTurns: level.maxTurns,
        promptBuilder: PromptBuilder(
          persona: persona,
          skills: skills,
          memory: memory,
          memoryIndexLimit: level.memoryIndexLimit,
        ),
      ),
    );

    // 子代理。它要用同一个模型客户端，所以只能在 llm 建好之后注册；
    // 工具表本身是引用，后面补进来的浏览器/代码/MCP 工具它调用时都看得见。
    tools.register(
      RunSubagentTool(llm: llm, parentTools: tools),
      timeout: N1Runtime.subagentToolTimeout,
    );

    // 会话建好之后再补浏览器工具：这样"建会话"和"浏览器就绪"谁先谁后
    // 都不影响结果，也就不用在一个同步方法里 await 一个异步探测。
    session.installBrowserTools(browser);
    session.installCodeTools(codeRunner, allowed: allowed);
    // 文件工具（安卓上是 null，直接不给）。
    final fs = fileAccess;
    if (fs != null) {
      session.installFileTools(
        paths: fs.paths,
        policy: fs.policy,
        backups: fs.backups,
        allowed: allowed,
      );
    }
    // MCP 工具。这里可能还是空的——连接是异步的，见 `ensureMcpReady`。
    // 调用方在每一轮之前会补一次，所以第一轮赶不上也没关系。
    session.installMcpTools(_mcpConnections);
    return session;
  }

  // ────────────────────────────────────────────────────────────────
  // MCP
  // ────────────────────────────────────────────────────────────────

  final List<McpConnection> _mcpConnections = [];

  /// 已经连上的服务器。给会话补工具用。
  List<McpConnection> get mcpConnections => List.unmodifiable(_mcpConnections);

  /// 当前连着的这批服务器对应的配置指纹。配置一改（加、删、改命令、开关）
  /// 就对不上，下次 [ensureMcpReady] 会整批重连。
  String _mcpSignature = '';

  Future<void>? _mcpBooting;

  /// 每台服务器最近一次的连接错误，键是服务器显示名。
  ///
  /// 存下来是给设置页看的：连不上时用户得知道是"命令不存在"还是
  /// "握手超时"，不然只能看到工具莫名其妙没出现。
  final Map<String, String> mcpErrors = {};

  /// 连上（或重连）所有启用的 MCP 服务器。**幂等**，每一轮之前无脑调。
  ///
  /// 连不上的服务器只记账、不抛：一台配错了不该把整个对话拦下来。
  Future<void> ensureMcpReady({bool force = false}) {
    final servers =
        settings.mcpServers.where((s) => s.enabled).toList(growable: false);
    final signature = McpServerConfig.encodeList(servers);

    if (!force && signature == _mcpSignature) return Future<void>.value();
    final booting = _mcpBooting;
    if (booting != null) return booting;

    final future = _connectAll(servers, signature);
    _mcpBooting = future;
    return future.whenComplete(() => _mcpBooting = null);
  }

  Future<void> _connectAll(
    List<McpServerConfig> servers,
    String signature,
  ) async {
    await _closeMcpConnections();
    mcpErrors.clear();

    for (final server in servers) {
      McpClient? client;
      try {
        final transport = await StdioMcpTransport.start(
          command: server.command,
          args: server.args,
          // 子进程按一行一条 JSON 说话；不显式给编码的话，中文描述在
          // Windows 上会按 GBK 解成乱码。
          environment: {'PYTHONIOENCODING': 'utf-8'},
        );
        client = McpClient(transport: transport);
        await client.connect(serverName: server.name).timeout(
          const Duration(seconds: 20),
        );
        final tools = await client.listTools().timeout(
          const Duration(seconds: 20),
        );
        _mcpConnections.add((
          config: server,
          client: client,
          tools: tools,
        ));
      } on Object catch (e) {
        mcpErrors[server.name] = _describe(e);
        // 半截的门要自己关上，不然子进程一直挂着。
        await client?.close();
      }
    }

    // **只有整批跑完才认这个指纹。** 中途把指纹记下来、然后某台服务器
    // 连失败了，下次调用就会因为"指纹没变"而不再重试，那台服务器就永远
    // 连不上了——而用户看到的是"工具表里少了几个，重启 App 也没用"。
    _mcpSignature = signature;
  }

  static String _describe(Object error) {
    if (error is McpException) return error.message;
    if (error is TimeoutException) return '连接超时（20 秒没握手成功）';
    if (error is ProcessException) {
      return '起不来这个命令：${error.message}';
    }
    return '$error';
  }

  Future<void> _closeMcpConnections() async {
    final closing = List<McpConnection>.of(_mcpConnections);
    _mcpConnections.clear();
    for (final conn in closing) {
      try {
        await conn.client.close();
      } catch (_) {
        // 对面可能早就没了。关不上不是错误。
      }
    }
  }

  Future<void> dispose() async {
    await _closeMcpConnections();
    await memory.close();
    await browser.dispose();
    await codeRunner.dispose();
    settings.dispose();
  }

  /// 开库并把**所有**表建齐。见 [boot] 里的说明。
  static Future<Database> _openDatabase(String path) async {
    // 首次启动时 <appSupport>/ 下的目录可能还不存在，而 sqflite 只管建库文件、
    // 不管建父目录，不补这一下会以 "unable to open database file" 失败
    // （报错里一个字都不提"目录不存在"，查起来要绕一圈）。
    if (path != inMemoryDatabasePath) {
      final dir = Directory(p.dirname(path));
      if (!await dir.exists()) await dir.create(recursive: true);
    }

    return openDatabase(
      path,
      version: DbSchema.version,
      onCreate: (db, version) => DbSchema.createAll(db),
      onUpgrade: DbSchema.upgrade,
    );
  }

  /// 读内置人设。
  ///
  /// 用 `rootBundle` 而不是 `DefaultAssetBundle.of(context)`：boot 发生在
  /// 建树之前，那时候根本没有 context。而 asset bundle 本身就是进程级的，
  /// 跟哪个 widget 无关，所以直接取根 bundle 才是对的做法。
  static Future<String> _loadPersona() async {
    const fallback = '你是 N1，一只安静的牛蛙。';
    try {
      final raw = await rootBundle.loadString('assets/persona/default.md');
      final trimmed = raw.trim();
      return trimmed.isEmpty ? fallback : trimmed;
    } catch (e) {
      // 人设文件丢了不该让 App 起不来。给一句能用的，日志留痕。
      debugPrint('读人设失败，用兜底：$e');
      return fallback;
    }
  }
}

/// 一次会话要用的三件套。
///
/// 打包成一个对象是为了让"用完要释放"这件事有个明确的落点——散着放的话
/// 调用方很容易只拿走 `loop`，然后那个 `ToolContext` 里的 http.Client
/// 就永远没人关了。
class N1Session {
  N1Session({
    required this.tools,
    required this.context,
    required this.loop,
    this.level = WorkLevel.standard,
    this.summarizer,
  });

  final ToolRegistry tools;
  final ToolContext context;
  final AgentLoop loop;

  /// 自动摘要。为 null 时表示这次会话不做摘要——测试里裸造 `N1Session`
  /// 的那些地方不受影响，行为跟加这个功能之前一模一样。
  final MemorySummarizer? summarizer;

  /// 这次会话的工作强度。默认 [WorkLevel.standard]——**等于加这个功能之前的
  /// 行为**，所以测试里那些裸造 `N1Session` 的地方不用改，行为也不会变。
  ///
  /// 只有回合数这一项要在这里用到：工具类能力是**会话建好之后**才补进来的
  /// （浏览器要预热、解释器要探测），那时候 [AgentLoop] 早就构造完了。
  final WorkLevel level;

  bool _browserInstalled = false;

  /// 把浏览器工具补进这次会话。**幂等**，可以在每一轮之前无脑调。
  ///
  /// 为什么可行：`AgentLoop.run` 每一轮都重新读 `tools.specs`
  /// （`agent_loop.dart` 里那句 `llm.stream(messages, tools: tools.specs)`），
  /// 而 `tools` 就是这个可变 registry。所以补注册之后**当前会话下一轮立刻
  /// 就能看见**，不用重建会话、不用重启 App，`browser` 字段也不用改成非 final。
  ///
  /// **刻意不做成"每轮重建工具表"**：`tool_registry.dart` 明确要求顺序稳定，
  /// 否则提示缓存每轮都失效。这里只在状态翻转时补一次。
  void installBrowserTools(BrowserDriver driver) {
    if (_browserInstalled) return;
    // `supportsWarmUp` = "这个平台有浏览器，只不过还没热"。这种情况下照样
    // 先把工具装上，等模型真要用浏览器时由工具自己预热（见 `withDriver`）。
    // 否则就得开机预热才能注册工具，而开机预热 = 每次打开 App 弹一个 Edge 窗口。
    if (!driver.isAvailable && !driver.supportsWarmUp) return;

    for (final tool in browserTools(available: true)) {
      tools.register(tool, timeout: N1Runtime.browserToolTimeout);
    }
    _browserInstalled = true;

    // 浏览器任务的回合数跟普通聊天不是一个量级：
    // open → snapshot → click → snapshot → type → click → snapshot → screenshot
    // 这一串正好吃满默认的 8 轮，稍微复杂一点就撞上限停下，而且是在
    // "最需要它继续干"的时候停。放宽到多少由工作强度定（标准档是 20，
    // 也就是加这个旋钮之前那个数）。
    _bumpMaxTurns(level.browserTurns);
  }

  /// 放宽回合上限，**只往上调，不往下调**。
  ///
  /// 原来这里是直接赋值，于是三路工具安装的**先后顺序会决定最终值**：
  /// 浏览器给 20、代码给 30，谁后装谁的生效。目前调用顺序固定（浏览器先、
  /// 代码后、文件最后），所以结果一直是对的——但那是巧合，加第四个安装点
  /// 或者哪天把行序调一下就悄悄变了，而且完全没有症状，只是"它怎么突然
  /// 少干几步"。改成取最大值之后，安装顺序怎么排都一样。
  void _bumpMaxTurns(int turns) {
    if (turns > loop.maxTurns) loop.maxTurns = turns;
  }

  /// 已经补进这次会话的代码工具名。
  final Set<String> _installedCodeTools = {};

  /// 把跑代码的工具补进这次会话。**幂等**，可以在每一轮之前无脑调。
  ///
  /// ## 为什么按名字记账，而不是一个 bool 或者两个 bool
  ///
  /// `run_command` 和 `run_code` 的就绪条件**不是一个**：前者看
  /// `supportsCommand`（`cmd` 一定在），后者看 `isAvailable`（得真探到
  /// Python/Node）。用一个总开关会出这种事：第一轮建会话时解释器还没探完
  /// （预热是后台跑的），`run_code` 这次没注册上；等预热完再调，开关已经是
  /// true，直接 return——**`run_code` 一整场都补不进来**，而且不报错，
  /// 看起来就是"模型从来不用这个工具"。
  ///
  /// 按名字记账对两种条件都成立，以后再加执行类工具也不用动这里。
  void installCodeTools(CodeRunner runner, {bool allowed = true}) {
    // 总开关关掉：**还得把已经装上的摘掉**。
    //
    // 只"不再装"是不够的：用户关总开关的那一刻，通常正是他刚看见一个弹窗、
    // 决定不想让它碰自己电脑的时候。而 `ChatProvider.resetSession()` 在正跑着
    // 的时候只是记账（等这一轮收完摊才真丢会话），只靠它的话这个开关要等到
    // 下一轮才生效——正好是最不该等的那个时刻。摘掉是当下就生效的。
    //
    // ⚠️ 回合上限**不回退**：它可能已经被放宽了，这一轮还在跑，中途调小
    // 会把一个正在干活的任务砍断。下一轮重建会话时自然回到该有的值。
    if (!allowed) {
      _uninstall(_installedCodeTools);
      return;
    }

    var added = false;
    for (final tool in codeTools(runner: runner)) {
      if (!_installedCodeTools.add(tool.name)) continue;
      tools.register(tool, timeout: N1Runtime.codeToolTimeout);
      added = true;
    }
    if (!added) return;

    // 写→跑→看报错→改→再跑是常态，一轮里跑三四次很正常。
    // 默认那 8 轮根本不够，而且会**恰好在最该继续的时候停下**。
    // 只在真的补上了 `run_code` 时才放宽——光有命令行不需要这么多回合。
    if (_installedCodeTools.contains(RunCodeTool.toolName)) {
      _bumpMaxTurns(level.codeTurns);
    }
  }

  /// 已经补进这次会话的文件工具名。
  final Set<String> _installedFileTools = {};

  /// 把文件工具补进这次会话。**幂等**，可以在每一轮之前无脑调。
  ///
  /// 跟代码工具不同，这一路没有"等预热"的问题——依赖是 boot 时一次探好的，
  /// 要么有要么没有。但仍然按名字记账，理由一样：以后加 `delete_file` 之类
  /// 的工具不用回来改这里。
  ///
  /// ⚠️ **只对写操作走审批的由工具自己判**（`write_file` 覆盖已有文件的
  /// `approvalReason`），这里不做任何过滤——过滤等于在这里重写一遍判定规则。
  /// 生成 PDF 用的中文字体。
  ///
  /// 包里带的是 Noto Sans SC 的**子集**（GB2312 全集 + 常用符号，2.1 MB）。
  /// 完整字重 17 MB，塞不进 APK 的 25 MiB 上限；子集覆盖常用汉字的代价是
  /// **生僻字打不出来**——真遇到时 PDF 里那个字会是空白，不会报错。
  ///
  /// 缓存一份：每次生成 PDF 都从 assets 解一次的话，连着写五份文档要多花
  /// 几十毫秒，没必要。
  static ByteData? _cachedFont;
  static bool _fontLoadFailed = false;

  static Future<ByteData?> _loadCjkFont() async {
    if (_cachedFont != null) return _cachedFont;
    if (_fontLoadFailed) return null;
    try {
      _cachedFont = await rootBundle.load('assets/fonts/NotoSansSC-subset.ttf');
      return _cachedFont;
    } catch (_) {
      _fontLoadFailed = true;
      return null;
    }
  }

  void installFileTools({
    required PathResolver paths,
    required FilePolicy policy,
    required FileBackupStore backups,
    bool allowed = true,
  }) {
    // 同 `installCodeTools`：关掉要**摘掉**，不是"以后不再装"。
    if (!allowed) {
      _uninstall(_installedFileTools);
      return;
    }

    var added = false;
    for (final tool in fileTools(
      available: true,
      paths: paths,
      policy: policy,
      backups: backups,
      loadFont: _loadCjkFont,
    )) {
      if (!_installedFileTools.add(tool.name)) continue;
      tools.register(tool, timeout: N1Runtime.codeToolTimeout);
      added = true;
    }
    if (!added) return;

    // "看看那个目录里有什么 → 读两个文件 → 改一个 → 再读一遍确认"是常态，
    // 8 轮兜不住，会在改到一半的时候停下。
    _bumpMaxTurns(level.codeTurns);
  }

  /// 已经补进这次会话的 MCP 工具名。
  final Set<String> _installedMcpTools = {};

  /// 把 MCP 服务器上的工具补进这次会话。**幂等**，可以在每一轮之前无脑调。
  ///
  /// 工具名带前缀（`mcp_<服务器>_<工具>`）：一是避免跟内置工具撞名，二是
  /// 用户看到痕迹时能一眼认出这话是外面那台服务器说的。
  void installMcpTools(List<McpConnection> connections) {
    var added = false;

    for (final conn in connections) {
      for (final info in conn.tools) {
        final base = mcpToolNameFor(conn.config.name, info.name);

        // 两台服务器叫同一个名字、又都有同名工具时，后到的加 `_2`。
        // 直接覆盖的话，前一台的工具会**无声消失**——模型只会觉得
        // "这台服务器的工具少了一个"。
        var name = base;
        var suffix = 2;
        while (tools.byName(name) != null && !_installedMcpTools.contains(name)) {
          name = '${base}_$suffix';
          suffix++;
        }

        if (!_installedMcpTools.add(name)) continue;
        tools.register(
          McpToolAdapter(
            client: conn.client,
            serverName: conn.config.name,
            info: info,
            prefixedName: name,
          ),
          timeout: N1Runtime.mcpToolTimeout,
        );
        added = true;
      }
    }

    if (added) _bumpMaxTurns(level.codeTurns);
  }

  /// 把 [names] 里的工具从注册表摘掉，并清空记账。
  ///
  /// 清空记账是必须的：不清的话开关再打开时，`_installed.add(...)` 会发现
  /// "名字已经有了"，于是**一个都不补回来**——关一次就永久废了。
  void _uninstall(Set<String> names) {
    for (final name in names) {
      tools.remove(name);
    }
    names.clear();
  }

  void dispose() => context.dispose();
}
