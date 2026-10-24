import 'package:flutter/foundation.dart';

import '../core/agent/work_level.dart';
import '../core/llm/providers.dart';
import '../core/mcp/mcp_config.dart';
import '../services/model_catalog.dart';
import '../services/secure_store.dart';

/// 设置页的状态。
///
/// 为什么不直接拿 [SettingsStore] 当 provider 用：设置页还要管**API Key**，
/// 而 Key 在 `flutter_secure_storage` 里——那是异步的，启动时读不了，跟
/// [SettingsStore] 用 shared_preferences 的理由正好相反。
///
/// 所以这里做一层合并：偏好设置直接转发，Key 自己管异步状态。外面只看到
/// 一个"设置"对象，不用关心哪个字段存在哪。
class SettingsProvider extends ChangeNotifier {
  // 公开参数名是 `store` / `secure` / `builtInPersona`（Dart 会去掉下划线）。
  SettingsProvider({
    required this._store,
    required this._secure,
    required this._builtInPersona,
    ModelCatalog? catalog,
  }) : _catalog = catalog ?? ModelCatalog() {
    _store.addListener(_relay);
    _loadKey();
  }

  final SettingsStore _store;
  final SecureStore _secure;
  final String _builtInPersona;
  final ModelCatalog _catalog;

  // ── 偏好设置：直接转发 ──

  bool get streamReasoning => _store.streamReasoning;
  double get temperature => _store.temperature;
  String get personaOverride => _store.personaOverride;

  /// 工作强度。管着回合数、工具结果回喂的长度、记忆索引条数、带多少历史。
  WorkLevel get workLevel => _store.workLevel;

  /// 允许 N1 操作文件和运行程序。关掉之后文件/代码这两类工具不注册。
  ///
  /// ⚠️ 这是一个**需要重建会话**的设置：工具表是会话建好那一刻定下来的。
  /// 设置页改完会调 `ChatProvider.resetSession()`（这是唯一能让它当场生效的路）。
  bool get allowCodeTools => _store.allowCodeTools;

  /// 自动模式：需要确认的操作不问，直接执行。
  ///
  /// 跟 [allowCodeTools] 不一样，这一项**不用重建会话**——`ChatProvider.askUser`
  /// 每次审批都现读设置，关掉的那一秒就恢复弹窗。
  bool get autoApprove => _store.autoApprove;

  /// 内置人设正文，给设置页做"恢复默认"的预览用。
  String get builtInPersona => _builtInPersona;

  /// 当前真正生效的人设：覆盖优先。
  String get effectivePersona =>
      personaOverride.trim().isEmpty ? _builtInPersona : personaOverride.trim();

  bool get isPersonaOverridden => personaOverride.trim().isNotEmpty;

  Future<void> setStreamReasoning(bool v) => _store.setStreamReasoning(v);
  Future<void> setTemperature(double v) => _store.setTemperature(v);
  Future<void> setPersonaOverride(String v) => _store.setPersonaOverride(v);
  Future<void> setWorkLevel(WorkLevel v) => _store.setWorkLevel(v);
  Future<void> setAllowCodeTools(bool v) => _store.setAllowCodeTools(v);
  Future<void> setAutoApprove(bool v) => _store.setAutoApprove(v);

  /// 用户自己配的 MCP 服务器。改完要重建会话——工具表是按会话建的。
  List<McpServerConfig> get mcpServers => _store.mcpServers;
  Future<void> setMcpServers(List<McpServerConfig> v) => _store.setMcpServers(v);

  /// 改回内置人设。
  Future<void> resetPersona() => _store.setPersonaOverride('');

  // ── 接哪家 ──

  /// 可选的供应商清单，设置页的下拉直接用它。
  List<LlmProvider> get providers => kLlmProviders;

  String get providerId => _store.providerId;
  LlmProvider get provider => _store.provider;

  /// 当前用的接口地址。预置那几家是固定的，「自定义」是用户填的。
  String get baseUrl => _store.effectiveBaseUrl;

  Future<void> setBaseUrl(String v) => _store.setCustomBaseUrl(v);

  /// 当前用的模型名。
  String get model => _store.effectiveModel;

  Future<void> setModel(String v) => _store.setModelFor(providerId, v);

  /// 去哪申请 Key。本机跑的（比如 Ollama）没有这一项，返回 null。
  String? get keyUrl => provider.keyUrl;

  /// 换供应商。
  ///
  /// 换完**必须重新读一次 Key**：每家一个 Key，读的是哪一格跟着供应商走。
  /// 不重读的话，界面上会拿上一家的 Key 长度显示"已设置"，而真正发出去的是
  /// 新那家的——看起来一切正常，一说话就 401。
  Future<void> selectProvider(String id) async {
    if (id == providerId) return;
    await _store.setProviderId(id);
    // 上一家拉回来的列表对新那家没有意义（模型名各家不通用），留着的话
    // 用户在新那家底下看见一堆不属于它的名字，点一下会把模型名设成无效值。
    _resetModelList();
    _keyLoading = true;
    notifyListeners();
    await _loadKey();
  }

  // ── 拉模型列表 ──

  /// 正在拉。
  bool _fetchingModels = false;
  bool get fetchingModels => _fetchingModels;

  /// 拉回来的模型名。空表 + [hasFetchedModels] 说明"拉过了，平台一个都没给"。
  List<String> _fetchedModels = const <String>[];
  List<String> get fetchedModels => _fetchedModels;

  /// 区分"还没拉过"和"拉过了是空的"——这两种在界面上该说的话不一样。
  bool _hasFetchedModels = false;
  bool get hasFetchedModels => _hasFetchedModels;

  /// 拉失败时说给用户听的那句话。成功或还没拉过时是 null。
  String? _modelListError;
  String? get modelListError => _modelListError;

  /// 去这个平台拉一份当前可用的模型名。
  ///
  /// ⚠️ 结果**只是建议**：界面把它摆出来给用户挑，挑完照旧落回那个可编辑的
  /// 输入框。拉不到就手填，不拦着。理由写在 [ModelCatalog] 的文档里。
  Future<void> fetchModels() async {
    if (_fetchingModels) return; // 连点两下不叠两趟请求

    // 异步回来时用户可能已经换了一家。跟 [_loadKey] 同一个坑：
    // 落库前对一次，不然会把 A 家的列表显示在 B 家的标题底下。
    final forProvider = providerId;

    _fetchingModels = true;
    _modelListError = null;
    _hasFetchedModels = false;
    _fetchedModels = const <String>[];
    notifyListeners();

    try {
      // Key 拿不到不算错：本机 Ollama 就没有 Key，照样能拉。
      final key = await _secure.readApiKey(providerId: forProvider) ?? '';
      final models = await _catalog.fetch(
        baseUrl: _store.effectiveBaseUrl,
        apiKey: key,
      );
      if (forProvider != providerId) return;
      _fetchedModels = models;
      _hasFetchedModels = true;
    } on ModelCatalogException catch (e) {
      if (forProvider != providerId) return;
      _modelListError = e.message;
    } catch (e) {
      if (forProvider != providerId) return;
      _modelListError = '拉的时候出错了：$e';
    } finally {
      if (forProvider == providerId) {
        _fetchingModels = false;
        notifyListeners();
      }
    }
  }

  void _resetModelList() {
    _fetchingModels = false;
    _hasFetchedModels = false;
    _fetchedModels = const <String>[];
    _modelListError = null;
  }


  // ── API Key：自己管 ──

  bool _keyLoading = true;
  bool get keyLoading => _keyLoading;

  bool _hasKey = false;
  bool get hasKey => _hasKey;

  /// 存在的 Key 的位数。**只给长度，不给内容**——给用户一个"我填过了"的确认，
  /// 又不把凭据显示在屏幕上。
  int _keyLength = 0;
  int get keyLength => _keyLength;

  String? _keyError;
  String? get keyError => _keyError;

  Future<void> _loadKey() async {
    // 异步回来时用户可能已经又换了一家。这中间隔着一整个平台通道往返，
    // 手快的人真能点到。落在一个已经不是当前的供应商上，界面就会显示错的
    // "已设置"状态，所以落库前先对一次。
    final forProvider = providerId;
    try {
      final key = await _secure.readApiKey(providerId: forProvider);
      if (forProvider != providerId) return;
      _hasKey = key != null && key.isNotEmpty;
      _keyLength = key?.length ?? 0;
      _keyError = null;
    } catch (e) {
      if (forProvider != providerId) return;
      _hasKey = false;
      _keyLength = 0;
      _keyError = '读不到已保存的 Key：$e';
    } finally {
      if (forProvider == providerId) {
        _keyLoading = false;
        notifyListeners();
      }
    }
  }

  /// 保存 Key。
  ///
  /// 返回是否成功——设置页要据此决定是关抽屉还是留在原地报错。
  Future<bool> saveApiKey(String raw) async {
    final key = raw.trim();
    if (key.isEmpty) {
      _keyError = 'Key 不能是空的。';
      notifyListeners();
      return false;
    }
    try {
      await _secure.writeApiKey(key, providerId: providerId);
      _hasKey = true;
      _keyLength = key.length;
      _keyError = null;
      notifyListeners();
      return true;
    } catch (e) {
      _keyError = '保存失败：$e';
      notifyListeners();
      return false;
    }
  }

  Future<void> clearApiKey() async {
    try {
      await _secure.clearApiKey(providerId: providerId);
      _hasKey = false;
      _keyLength = 0;
      _keyError = null;
    } catch (e) {
      _keyError = '清除失败：$e';
    }
    notifyListeners();
  }

  void _relay() => notifyListeners();

  @override
  void dispose() {
    _store.removeListener(_relay);
    // _store 是全局共享的，这里**不 dispose 它**——只摘掉自己的监听。
    super.dispose();
  }
}
