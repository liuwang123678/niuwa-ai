import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/n1_core.dart';

/// 把打包在 asset 里的技能释放到可写目录，再从磁盘加载。
///
/// **为什么不直接读 asset**：技能是给用户改的——改措辞、加自己的规矩、
/// 干脆删掉一个不想要的。asset 是只读的，用户改不动，所以第一次启动时
/// 释放一份到应用目录，之后一切以磁盘为准（见 [load]）。
class SkillLoader {
  /// [skillsDir] 是技能的根目录（真机上是 `<appSupport>/skills`）。
  ///
  /// 为什么是注入一个 [Directory] 而不是内部调 `getApplicationSupportDirectory()`：
  /// 那样测试就得去 mock path_provider 的平台通道（`path_provider_platform_interface`
  /// 那一套），为了一个目录路径引一层 mock 太重了。换成构造参数以后，
  /// 测试塞一个临时目录进去就行，平台通道一次都不碰，生产入口留在 [forApp]。
  ///
  /// [bundle] 同理有默认值，正常不用传。
  SkillLoader({required this.skillsDir, AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  /// 内置技能清单。
  ///
  /// **必须是硬编码的清单**：Flutter 没有"枚举 asset 目录"的能力——
  /// [AssetBundle] 只有 `load`/`loadString` 这类按键取值的接口，`AssetManifest.json`
  /// 也只列出文件、不给你一个"目录"的概念，拿到目录名会直接抛异常。
  /// 所以想知道 `assets/skills/` 下有哪些技能，只有编译期写死一条路。
  ///
  /// 代价是：**新增一个技能要同时改这个清单和 pubspec 的 assets 声明**。
  /// 漏改是静默失败（技能就是不见了，没有任何报错），所以
  /// `test/services/skill_loader_test.dart` 里有一条测试拿真实的
  /// `assets/skills/` 目录跟这个清单对账，漏改会在测试阶段炸出来。
  static const List<String> bundledSkillNames = [
    'browser-task',
    'coding',
    'companion-talk',
    'debugging',
    'note-taking',
    'nuwa',
    'planning',
    'review',
    'testing',
    'web-research',
  ];

  static const String assetRoot = 'assets/skills';
  static const String skillFileName = 'SKILL.md';

  /// 技能的根目录（真机上是 `<appSupport>/skills`；测试里是临时目录）。
  final Directory skillsDir;

  final AssetBundle _bundle;

  /// 生产入口：`<appSupport>/skills`。
  ///
  /// 用 appSupport 而不是 Documents：技能文件不是用户文档，不该出现在
  /// 文件管理器里让用户误删；而且它在各平台上都保证存在且可写。
  static Future<SkillLoader> forApp({AssetBundle? bundle}) async {
    final support = await getApplicationSupportDirectory();
    return SkillLoader(
      skillsDir: Directory(p.join(support.path, 'skills')),
      bundle: bundle,
    );
  }

  /// 某个技能在磁盘上的位置。测试也用它来改文件、验证"磁盘优先"。
  File fileFor(String skillName) =>
      File(p.join(skillsDir.path, skillName, skillFileName));

  /// 释放 + 加载。
  ///
  /// [forceRefresh] 为 true 时无视磁盘上的内容强制用 asset 覆盖一遍
  /// （用户改坏了想还原时用）。
  Future<SkillRegistry> load({bool forceRefresh = false}) async {
    await _releaseFromAssets(forceRefresh: forceRefresh);

    // 统一从磁盘读，而不是"释放成功就用 asset 的内容"——两条路合一条，
    // 保证最终生效的永远是用户磁盘上那一份，不会出现"这次启动用的是 asset、
    // 下次用的是磁盘"这种飘忽行为。
    final sources = <String, String>{};
    for (final name in bundledSkillNames) {
      final file = fileFor(name);
      if (!await file.exists()) {
        debugPrint('技能文件不存在，跳过：${file.path}');
        continue;
      }
      try {
        sources[file.path] = await file.readAsString();
      } catch (e) {
        debugPrint('技能文件读不出来，跳过：${file.path} — $e');
      }
    }

    final result = SkillRegistry.fromMarkdown(sources);
    // fromMarkdown 的容错取向是"解析不了就跳过"，但静默跳过等于技能凭空消失，
    // 排查时会让人以为是清单或 asset 的问题。这里把 failures 打出来，一眼定位。
    for (final failure in result.failures) {
      debugPrint('技能解析失败，已跳过：$failure');
    }
    return result.registry;
  }

  Future<void> _releaseFromAssets({required bool forceRefresh}) async {
    for (final name in bundledSkillNames) {
      final file = fileFor(name);

      // 磁盘优先。这就是这个类的设计意图：用户改过的版本比内置的版本权威，
      // 每次启动都覆盖一遍会把用户的心血抹掉，而且用户完全不知道为什么。
      if (!forceRefresh && await file.exists()) continue;

      try {
        final content = await _bundle.loadString(
          '$assetRoot/$name/$skillFileName',
        );
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
      } catch (e) {
        // 释放失败不能让 App 起不来：磁盘上多半还有上一版，读多少算多少。
        debugPrint('技能释放失败：$name — $e');
      }
    }
  }
}
