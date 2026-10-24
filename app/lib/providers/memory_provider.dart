import 'package:flutter/foundation.dart';

import '../core/n1_core.dart';

/// 记忆页的状态。
///
/// 只读 + 删改，**不提供"手动新增"**：记忆是 agent 在聊天里自己攒的，
/// 让用户手填一条等于绕过了 `memory_save` 的去重和打分逻辑，攒出来的库会脏。
/// 想让它记住什么，直接跟它说就行——那才是这个 App 该有的样子。
class MemoryProvider extends ChangeNotifier {
  MemoryProvider({required this._store});

  final MemoryStore _store;

  List<MemoryEntry> _entries = const [];
  List<MemoryEntry> get entries => _entries;

  bool _loading = true;
  bool get loading => _loading;

  /// 当前搜索词。非空时 [entries] 是搜索结果而不是全部。
  String _query = '';
  String get query => _query;
  bool get searching => _query.isNotEmpty;

  String? _error;
  String? get error => _error;

  int _total = 0;
  int get total => _total;

  bool get isEmpty => !_loading && _entries.isEmpty;

  Future<void> load() async {
    _loading = true;
    _safeNotify();
    try {
      // 并行取：总数和列表互不依赖，串行等就是白等一个来回。
      final results = await Future.wait([
        _store.index(limit: 500),
        _store.count(),
      ]);
      _entries = results[0] as List<MemoryEntry>;
      _total = results[1] as int;
      _error = null;
    } catch (e) {
      _error = '读取记忆失败：$e';
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  Future<void> search(String query) async {
    _query = query.trim();
    if (_query.isEmpty) return load();

    _loading = true;
    _safeNotify();
    try {
      // `track: false`：用户在记忆页里搜东西不算"模型用过这条记忆"，
      // 否则翻一遍记忆页就把排序权重搅乱了。
      _entries = await _store.search(_query, limit: 200, track: false);
      _error = null;
    } catch (e) {
      _error = '搜索失败：$e';
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  Future<void> clearSearch() async {
    _query = '';
    await load();
  }

  Future<void> delete(String id) async {
    try {
      await _store.delete(id);
      // 本地先摘掉，不等重新查库——删一条要等一次全量查询才消失，手感很差。
      _entries = _entries.where((e) => e.id != id).toList();
      _total = (_total - 1).clamp(0, 1 << 31);
      _error = null;
    } catch (e) {
      _error = '删除失败：$e';
    }
    _safeNotify();
  }

  /// 改一条记错的内容 / 重要度。
  ///
  /// **不提供"手动新增"**（见类注释），但**允许改**：模型偶尔会把人称、
  /// 时间记拧，或者把"不喜欢"写成"喜欢"。以前只能删了重记，而删了之后
  /// 模型不一定再记一次——这条信息就永久丢了。改内容不绕过任何打分逻辑，
  /// 因为 id、kind、主题都没动。
  Future<void> update(
    MemoryEntry entry, {
    required String content,
    required int importance,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      _error = '内容不能为空';
      _safeNotify();
      return;
    }

    final updated = entry.copyWith(
      content: trimmed,
      importance: importance.clamp(1, 5),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    try {
      await _store.save(updated);
      _entries = [
        for (final e in _entries) e.id == entry.id ? updated : e,
      ];
      _error = null;
    } catch (e) {
      _error = '保存失败：$e';
    }
    _safeNotify();
  }

  void _safeNotify() => notifyListeners();
}
