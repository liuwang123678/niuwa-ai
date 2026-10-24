import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/agent/work_level.dart';
import '../core/llm/providers.dart';
import '../core/mcp/mcp_config.dart';

/// 机密存储的后端。
///
/// 抽这一层不是为了"将来换实现"，而是因为**测试环境里根本没有平台通道**：
/// `flutter test` 跑在 Dart VM 上，底下既没有 Android Keystore 也没有 Windows DPAPI，
/// 直接调 [FlutterSecureStorage] 会以 MissingPluginException 挂掉。
/// 所以生产走真后端、测试注入内存后端，两边共用同一套 SecureStore 逻辑
/// （trim、空值判定这些容易写错的细节只写一遍）。
abstract class SecureKeyBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 真后端：Android 走 Keystore、Windows 走 DPAPI、iOS 走 Keychain。
class PlatformSecureKeyBackend implements SecureKeyBackend {
  const PlatformSecureKeyBackend([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 内存后端。测试用，也可以当作安全存储不可用时的兜底。
///
/// 放在 lib 里而不是 test 里，是因为这个项目里内核也是这么干的
/// （`InMemoryMemoryStore` 同样住在 lib 里、同样注明"测试用"），保持一致。
class InMemorySecureKeyBackend implements SecureKeyBackend {
  InMemorySecureKeyBackend([Map<String, String>? seed]) : _data = {...?seed};

  final Map<String, String> _data;

  /// 给测试看的内部状态快照（比如断言"clear 之后确实什么都没留下"）。
  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

/// API Key 的存放处。
///
/// 为什么不用 shared_preferences 存 Key：那是明文 XML/plist，任何能读到
/// 应用目录的东西（备份、别的 App 越权读取、用户自己翻文件）都能拿走它。
/// Key 直接等于用户的账单，必须交给系统级加密存储。
class SecureStore {
  /// [backend] 不传就是真后端。测试必须传 [InMemorySecureKeyBackend]。
  SecureStore({SecureKeyBackend? backend})
    : _backend = backend ?? const PlatformSecureKeyBackend();

  /// 老版本只有一家可接，Key 存在这个固定名字下。
  ///
  /// 换成「每家一个 Key」之后这个名字不再写入，但**读的时候还得认**——
  /// 不然已经填过 Key 的人升级上来，会发现设置页显示「还没设置」，
  /// 而他手里那个 Key 明明还能用（更难查的是：他以为丢了，又去建一个）。
  static const String legacyApiKeyName = 'n1.api_key';

  /// 每家一个 Key。换供应商不会把你原来那家的冲掉，切回来不用重填。
  static String apiKeyNameFor(String providerId) => 'n1.api_key.$providerId';

  final SecureKeyBackend _backend;

  /// 读某家供应商的 Key。[providerId] 不传就是当前默认那家。
  Future<String?> readApiKey({String? providerId}) async {
    final id = providerId ?? kDefaultProviderId;

    final own = await _backend.read(apiKeyNameFor(id));
    if (own != null && own.trim().isNotEmpty) return own;

    // 老键名里那份 Key 本来就是默认那家的，所以只对默认那家回退。
    // 套到别家头上等于把一个不属于那家的 Key 发过去，只会换来一个 401，
    // 而且用户完全看不出为什么——设置页明明显示"已设置"。
    if (id == kDefaultProviderId) {
      final legacy = await _backend.read(legacyApiKeyName);
      if (legacy != null && legacy.trim().isNotEmpty) return legacy;
    }
    return null;
  }

  /// 写之前 trim：用户从网页上复制 Key 十有八九会带上首尾空白或换行，
  /// 那玩意进了 `Authorization` 头就是个非法请求，而且报错信息完全看不出原因。
  Future<void> writeApiKey(String key, {String? providerId}) => _backend.write(
    apiKeyNameFor(providerId ?? kDefaultProviderId),
    key.trim(),
  );

  Future<void> clearApiKey({String? providerId}) async {
    final id = providerId ?? kDefaultProviderId;
    await _backend.delete(apiKeyNameFor(id));
    // 默认那家还要连老键名一起删。不删的话 [readApiKey] 会回退到它，
    // 用户点完"清除"再看一眼，Key 又回来了——像个删不掉的鬼。
    if (id == kDefaultProviderId) {
      await _backend.delete(legacyApiKeyName);
    }
  }

  /// 只有空白也算没配——不然用户复制了个空行会让 App 以为已经配置好了。
  Future<bool> hasApiKey({String? providerId}) async {
    final key = await readApiKey(providerId: providerId);
    return key != null && key.trim().isNotEmpty;
  }
}

/// 非机密设置的存放处。
///
/// 这里的东西（开关、温度、人设覆盖）都需要在**首帧之前**读到——界面一打开就要
/// 按设置渲染，异步读会让界面先闪一下默认值。shared_preferences 恰好能在
/// 启动时同步读（内存缓存），所以用它。
///
/// 继承 [ChangeNotifier] 而不是自己做事件：全 App 共享一个实例，
/// `provider` 直接监听就行，设置页改一下，聊天页当场生效。
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  /// 生产入口。
  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  static const String _kStreamReasoning = 'settings.stream_reasoning';
  static const String _kTemperature = 'settings.temperature';
  static const String _kPersonaOverride = 'settings.persona_override';
  static const String _kProviderId = 'settings.provider_id';
  static const String _kCustomBaseUrl = 'settings.custom_base_url';
  static const String _kWorkLevel = 'settings.work_level';
  static const String _kAllowCodeTools = 'settings.allow_code_tools';
  static const String _kAutoApprove = 'settings.auto_approve';
  static const String _kMcpServers = 'settings.mcp_servers';

  /// 模型名**按供应商分开存**：各家名字不通用，共用一格的话换回来就得重填。
  static String _kModel(String providerId) => 'settings.model.$providerId';

  static const bool defaultStreamReasoning = true;
  static const double defaultTemperature = 0.7;
  static const double minTemperature = 0;
  static const double maxTemperature = 2;

  final SharedPreferences _prefs;

  // ── 接哪家 ──

  /// 当前选的供应商。
  ///
  /// 存的是 `id` 不是显示名——显示名以后想改就改，改不动老用户已经存下的选择。
  /// 存着的 id 已经不认识了（比如某个供应商被删掉了）就退回默认那家，
  /// 而不是让界面拿着一个查不到的对象去炸。
  String get providerId {
    final stored = _prefs.getString(_kProviderId);
    if (stored != null && providerById(stored) != null) return stored;
    return kDefaultProviderId;
  }

  LlmProvider get provider => providerById(providerId) ?? kLlmProviders.first;

  Future<void> setProviderId(String id) async {
    await _prefs.setString(
      _kProviderId,
      providerById(id) == null ? kDefaultProviderId : id,
    );
    notifyListeners();
  }

  /// 「自定义」那条的接口地址。别的供应商用不上这一格。
  String get customBaseUrl => _prefs.getString(_kCustomBaseUrl) ?? '';

  Future<void> setCustomBaseUrl(String value) async {
    await _prefs.setString(_kCustomBaseUrl, value.trim());
    notifyListeners();
  }

  /// 某家供应商现在用的模型名。没自己改过就用预置默认值。
  ///
  /// 清空等于"用回预置的"，而不是"没有模型"——用户在输入框里删干净之后，
  /// 通常想要的是恢复原样，不是让 App 发一个空模型名出去。
  String modelFor(String providerId) {
    final stored = _prefs.getString(_kModel(providerId));
    if (stored != null && stored.trim().isNotEmpty) return stored.trim();
    return providerById(providerId)?.defaultModel ?? '';
  }

  Future<void> setModelFor(String providerId, String value) async {
    await _prefs.setString(_kModel(providerId), value.trim());
    notifyListeners();
  }

  /// 现在真正要用的接口地址：「自定义」取用户填的，其余取预置的。
  String get effectiveBaseUrl =>
      provider.isCustom ? customBaseUrl : provider.baseUrl;

  /// 现在真正要用的模型名。
  String get effectiveModel => modelFor(providerId);

  /// 是否把模型的思考过程流式显示出来。
  bool get streamReasoning =>
      _prefs.getBool(_kStreamReasoning) ?? defaultStreamReasoning;

  /// 采样温度。0 最稳，2 最飘；超过 2 上游接口会直接拒，所以在 setter 里夹住。
  double get temperature =>
      _prefs.getDouble(_kTemperature) ?? defaultTemperature;

  /// 覆盖内置人设。空串 = 用内置的（而不是"没有人设"）。
  String get personaOverride => _prefs.getString(_kPersonaOverride) ?? '';

  /// 工作强度。存的是 [WorkLevel.id]。
  ///
  /// 没存过、或者存着一个认不出的 id，都退回 [WorkLevel.standard]——
  /// **默认这一档必须等于加这个功能之前的行为**，见 `WorkLevel` 的说明。
  WorkLevel get workLevel =>
      WorkLevel.fromId(_prefs.getString(_kWorkLevel));

  Future<void> setStreamReasoning(bool value) async {
    await _prefs.setBool(_kStreamReasoning, value);
    notifyListeners();
  }

  Future<void> setTemperature(double value) async {
    final safe = value.clamp(minTemperature, maxTemperature).toDouble();
    await _prefs.setDouble(_kTemperature, safe);
    notifyListeners();
  }

  Future<void> setPersonaOverride(String value) async {
    // 只存 trim 过的：判断"是不是空串"的地方很多，别让一串空格混过去。
    await _prefs.setString(_kPersonaOverride, value.trim());
    notifyListeners();
  }

  Future<void> setWorkLevel(WorkLevel value) async {
    await _prefs.setString(_kWorkLevel, value.id);
    notifyListeners();
  }

  /// 用户自己配的 MCP 服务器。存成一段 JSON。
  ///
  /// 为什么不放进安全存储：这里面只有命令和参数，没有密钥。而 MCP 服务器
  /// 将来要带密钥的话（远程那种），得单独开一个字段走 Keystore。
  List<McpServerConfig> get mcpServers =>
      McpServerConfig.decodeList(_prefs.getString(_kMcpServers));

  Future<void> setMcpServers(List<McpServerConfig> servers) async {
    await _prefs.setString(_kMcpServers, McpServerConfig.encodeList(servers));
    notifyListeners();
  }

  /// 允许 N1 读你电脑上的文件、跑程序。**关掉之后这两类工具直接不注册**
  /// （模型看不见，不会去调，也不会说"我做不到"）。
  ///
  /// 默认**开**。不默认关的理由不只是"用户要这个能力"：关着的时候
  /// `run_command` 和 `read_file` 都没了，而删除、覆盖这类操作本来就走的
  /// 审批弹窗——默认关于是成了一种自相矛盾：普通操作你都不让它做，却指望
  /// 它在需要的时候问你一句。
  bool get allowCodeTools => _prefs.getBool(_kAllowCodeTools) ?? true;

  Future<void> setAllowCodeTools(bool value) async {
    await _prefs.setBool(_kAllowCodeTools, value);
    notifyListeners();
  }

  /// 自动模式：需要确认的操作**不问**，直接执行。
  ///
  /// 默认**关**。这是全 App 唯一一个"把安全兜底关掉"的开关，所以它必须由
  /// 用户自己按下，而且界面上要一直看得见（输入条上那颗"自动"胶囊）。
  ///
  /// 关掉的时候什么都不变：危险操作照样弹窗，用户点「不要」照样不执行。
  /// 打开之后**保护仍在**：系统目录照样不让写、审计日志照样记（记为
  /// `auto-ran`，跟用户点过同意的 `ran` 分得开），只是不再停下来等那一下。
  bool get autoApprove => _prefs.getBool(_kAutoApprove) ?? false;

  Future<void> setAutoApprove(bool value) async {
    await _prefs.setBool(_kAutoApprove, value);
    notifyListeners();
  }
}
