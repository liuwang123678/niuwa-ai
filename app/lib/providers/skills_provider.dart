import 'package:flutter/foundation.dart';

import '../core/n1_core.dart';
import '../services/n1_runtime.dart';

/// 技能页的状态。
///
/// 技能**只能看，不能在 App 里编辑**——它们是 markdown 文件，躺在
/// `<appSupport>/skills/<名字>/SKILL.md`。想改就去改文件，改完回这个页面点
/// 刷新。在 App 里塞一个 markdown 编辑器看着方便，实际上是给用户一个比记事本
/// 更差的编辑器，还要处理保存冲突、编码、撤销……不值。
class SkillsProvider extends ChangeNotifier {
  SkillsProvider({required this._runtime});

  final N1Runtime _runtime;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  /// 当前展开来看的那个技能。null = 停在列表。
  Skill? _open;
  Skill? get open => _open;

  List<Skill> get skills => _runtime.skills.all;
  bool get isEmpty => skills.isEmpty;

  /// 技能文件在磁盘上的位置，给用户复制路径用。
  String pathOf(String name) => _runtime.skillLoader.fileFor(name).path;

  /// 技能的根目录。用户想自己放一个技能进来时要知道往哪儿放。
  String get skillsDir => _runtime.skillLoader.skillsDir.path;

  void show(Skill skill) {
    _open = skill;
    notifyListeners();
  }

  void closeDetail() {
    _open = null;
    notifyListeners();
  }

  /// 重新读盘。
  ///
  /// [forceRefresh] 会把磁盘上的版本用内置的覆盖回去——这是给"我改坏了想还原"
  /// 准备的，所以是个需要确认的危险操作，界面上要问一句。
  Future<void> reload({bool forceRefresh = false}) async {
    _loading = true;
    _safeNotify();
    try {
      await _runtime.reloadSkills(forceRefresh: forceRefresh);
      // 展开着的那条，内容可能已经变了，或者干脆没了。按名字重取一次：
      // 拿着旧对象的话用户会盯着改之前的内容，还以为没生效。
      final name = _open?.name;
      _open = name == null ? null : _runtime.skills.byName(name);
      _error = null;
    } catch (e) {
      _error = '加载技能失败：$e';
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  void _safeNotify() => notifyListeners();
}
