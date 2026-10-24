import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/services/skill_loader.dart';
import 'package:path/path.dart' as p;

/// 技能加载。
///
/// 全部用 `test()` 而不是 `testWidgets()`：testWidgets 跑在 FakeAsync 里，
/// 真文件 IO / asset 读取会被卡成"永远不完成"。用 test() 就没有这层时间伪造，
/// 该怎么 await 就怎么 await。
void main() {
  // rootBundle 需要绑定先初始化（后面几组测试真的读 asset）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    // 临时目录当 appSupport。这也是这个类收 Directory 参数而不是自己去调
    // path_provider 的原因——测试完全不用碰平台通道。
    tmp = Directory.systemTemp.createTempSync('n1_skill_loader_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  SkillLoader newLoader() =>
      SkillLoader(skillsDir: Directory(p.join(tmp.path, 'skills')));

  group('从 asset 释放并加载', () {
    test('内置技能全部加载成功', () async {
      final loader = newLoader();
      final registry = await loader.load();

      // 数量跟着清单走，不写死。写死的话每加一个技能都要回来改这里，
      // 而"清单和真实目录对不对得上"有下面那条专门的测试在管。
      expect(registry.all.length, SkillLoader.bundledSkillNames.length);
      expect(
        registry.all.map((s) => s.name).toList(),
        // all 按名字排序，顺序也是稳定的
        [...SkillLoader.bundledSkillNames]..sort(),
      );

      for (final skill in registry.all) {
        expect(skill.name, isNotEmpty, reason: '技能必须有 name，否则挂不上工具表');
        expect(skill.description, isNotEmpty, reason: '没有 description 模型不知道什么时候用它');
        expect(skill.body, isNotEmpty, reason: '正文才是 skill_read 真正返回的东西');
      }
    });

    test('释放出来的文件落在 <skills>/<名字>/SKILL.md', () async {
      final loader = newLoader();
      await loader.load();

      for (final name in SkillLoader.bundledSkillNames) {
        final file = loader.fileFor(name);
        expect(file.existsSync(), isTrue, reason: '${file.path} 应该被释放出来');
      }
    });

    test('技能名清单跟真实的 assets/skills 目录对得上', () async {
      // 这条测试是清单的保险：Flutter 没法枚举 asset 目录，清单只能手写，
      // 那就一定会有人加了新技能目录却忘了往清单里添。这里拿仓库里的真实目录对账。
      final assetDir = Directory('assets/skills');
      expect(assetDir.existsSync(), isTrue, reason: '测试要在 app/ 目录下跑');

      final onDisk = assetDir
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .where((name) => File(p.join(assetDir.path, name, 'SKILL.md')).existsSync())
          .toList()
        ..sort();

      expect(onDisk, [...SkillLoader.bundledSkillNames]..sort());
    });
  });

  group('磁盘优先', () {
    test('用户改过的文件不会被 asset 覆盖掉', () async {
      final loader = newLoader();
      final file = loader.fileFor('note-taking');

      // 先跑一次，让它把 asset 释放出来；再模拟用户手改
      await loader.load();
      await file.writeAsString('''
---
name: note-taking
description: 用户自己改过的描述
---

# 我自己的规矩
''');

      final registry = await loader.load();
      final skill = registry.byName('note-taking')!;
      expect(skill.description, '用户自己改过的描述');
      expect(skill.body, contains('我自己的规矩'));
      // 磁盘上的版本原样留着
      expect(file.readAsStringSync(), contains('用户自己改过的描述'));
    });

    test('forceRefresh 时强制从 asset 覆盖回默认版本', () async {
      final loader = newLoader();
      final file = loader.fileFor('note-taking');

      await loader.load();
      await file.writeAsString('坏的/自定义的内容');

      final registry = await loader.load(forceRefresh: true);
      final skill = registry.byName('note-taking')!;
      expect(skill.description, isNot('坏的/自定义的内容'));
      expect(skill.body, isNotEmpty);
      expect(file.readAsStringSync(), isNot('坏的/自定义的内容'));
    });
  });

  group('容错', () {
    test('坏掉的技能文件只是被跳过，不崩，也不影响其他技能', () async {
      final loader = newLoader();
      await loader.load(); // 先正常释放一份

      await loader.fileFor('web-research').writeAsString('这里没有 frontmatter');

      final registry = await loader.load();
      expect(registry.all.length, SkillLoader.bundledSkillNames.length - 1);
      expect(registry.byName('web-research'), isNull);
      expect(registry.byName('companion-talk'), isNotNull);
    });

    test('skills 目录还不存在时会自己建出来', () async {
      final dir = Directory(p.join(tmp.path, 'deep', 'skills'));
      expect(dir.existsSync(), isFalse);

      final registry = await SkillLoader(skillsDir: dir).load();

      expect(dir.existsSync(), isTrue);
      expect(registry.all.length, SkillLoader.bundledSkillNames.length);
    });
  });
}
