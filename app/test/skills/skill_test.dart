import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

const _valid = '''
---
name: web-research
description: 联网调研。当用户要求"查一下"时使用。
---

# Web Research

## 工作流
1. 先想清楚问题
''';

void main() {
  group('SKILL.md 解析', () {
    test('正常文件能解出 name / description / 正文', () {
      final skill = Skill.parse(_valid)!;

      expect(skill.name, 'web-research');
      expect(skill.description, '联网调研。当用户要求"查一下"时使用。');
      expect(skill.body, startsWith('# Web Research'));
      expect(skill.body, contains('先想清楚问题'));
    });

    test('CRLF 换行照样能解（Windows 上编辑过就会变这样）', () {
      final skill = Skill.parse(_valid.replaceAll('\n', '\r\n'));
      expect(skill, isNotNull);
      expect(skill!.name, 'web-research');
    });

    test('值带引号时把引号剥掉', () {
      final skill = Skill.parse('''
---
name: "quoted"
description: '单引号也行'
---
正文
''');
      expect(skill!.name, 'quoted');
      expect(skill.description, '单引号也行');
    });

    test('description 里带冒号不会被截断', () {
      final skill = Skill.parse('''
---
name: t
description: 用法：先做 A 再做 B
---
x
''');
      expect(skill!.description, '用法：先做 A 再做 B');
    });

    group('坏文件返回 null 而不是抛异常', () {
      // 用户手改技能文件改坏了，不该让整个 App 起不来
      test('没有 frontmatter', () {
        expect(Skill.parse('# 就是个普通 markdown'), isNull);
      });

      test('frontmatter 没闭合', () {
        expect(Skill.parse('---\nname: x\ndescription: y\n'), isNull);
      });

      test('缺 name', () {
        expect(Skill.parse('---\ndescription: y\n---\n正文'), isNull);
      });

      test('缺 description —— 模型就不知道什么时候该用它', () {
        expect(Skill.parse('---\nname: x\n---\n正文'), isNull);
      });

      test('name 是空串', () {
        expect(Skill.parse('---\nname:\ndescription: y\n---\n正文'), isNull);
      });
    });
  });

  group('技能库', () {
    test('索引里的顺序稳定（提示缓存靠这个）', () {
      final registry = SkillRegistry()
        ..register(const Skill(name: 'zeta', description: 'Z', body: ''))
        ..register(const Skill(name: 'alpha', description: 'A', body: ''))
        ..register(const Skill(name: 'mid', description: 'M', body: ''));

      expect(registry.all.map((s) => s.name).toList(), ['alpha', 'mid', 'zeta']);
      expect(registry.toIndexPrompt().split('\n').first, startsWith('- alpha:'));
    });

    test('同名技能后注册的覆盖先注册的', () {
      final registry = SkillRegistry()
        ..register(const Skill(name: 'x', description: '内置的', body: 'a'))
        ..register(const Skill(name: 'x', description: '用户装的', body: 'b'));

      expect(registry.length, 1);
      expect(registry.byName('x')!.body, 'b');
    });

    test('批量加载时坏文件被跳过并记下来', () {
      final result = SkillRegistry.fromMarkdown({
        'good/SKILL.md': _valid,
        'bad/SKILL.md': '不是技能文件',
      });

      expect(result.registry.length, 1);
      expect(result.failures, ['bad/SKILL.md']);
    });

    test('索引为空时给一句人话而不是空字符串', () {
      expect(SkillRegistry().toIndexPrompt(), contains('没有'));
    });
  });
}
