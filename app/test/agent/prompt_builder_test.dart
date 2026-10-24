import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

void main() {
  test('人设打头', () async {
    final prompt = await testPromptBuilder(persona: '你是牛蛙。').build();
    expect(prompt, startsWith('你是牛蛙。'));
  });

  test('没有记忆时给一句人话，不留空白', () async {
    final prompt = await testPromptBuilder().build();
    expect(prompt, contains('还没有'));
  });

  test('记忆以索引行形式注入', () async {
    final store = InMemoryMemoryStore([
      MemoryEntry(
        id: 'm1',
        kind: MemoryKind.preference,
        content: '用户不吃香菜',
        subject: '用户本人',
        importance: 4,
        createdAt: 1,
        updatedAt: 2,
      ),
    ]);

    final prompt = await testPromptBuilder(memory: store).build();

    // 时间戳 2 毫秒＝1970-01-01。日期是给模型判断"这事多久以前"用的。
    expect(prompt, contains('- [preference][1970-01-01]（用户本人） 用户不吃香菜'));
  });

  test('技能以 name + description 形式注入，并说明要先读再照做', () async {
    final registry = SkillRegistry()
      ..register(
        const Skill(
          name: 'web-research',
          description: '联网调研。当用户要求"查一下"时使用。',
          body: '详细流程',
        ),
      );

    final prompt = await testPromptBuilder(skills: registry).build();

    expect(prompt, contains('- web-research: 联网调研'));
    expect(prompt, contains('skill_read'));
    // 正文不该进 prompt，否则技能一多上下文就爆了
    expect(prompt, isNot(contains('详细流程')));
  });

  test('system prompt 里不许出现时间', () async {
    // 时间曾经写在 system prompt 末尾，而它是整段历史的前缀——每分钟变一次，
    // 每分钟把整个对话的缓存作废。现在由 AgentLoop 拼进最后一条用户消息。
    final prompt = await testPromptBuilder().build();
    expect(prompt, isNot(contains('# 现在')));
  });

  group('顺序（提示缓存靠这个）', () {
    test('稳定的在前，记忆在后面', () async {
      final prompt = await testPromptBuilder().build();

      final iPersona = prompt.indexOf('你是测试人设');
      final iTools = prompt.indexOf('# 关于工具');
      final iMemory = prompt.indexOf('# 你记得的事');
      final iSkills = prompt.indexOf('# 你可以用的技能');

      expect(iPersona, lessThan(iTools));
      expect(iTools, lessThan(iSkills));
      expect(iSkills, lessThan(iMemory),
          reason: '技能索引比记忆索引稳定得多：技能装上就不动，记忆每次都在变。'
              '缓存按前缀命中，稳定的必须排前面，否则加了一条记忆就让后面全失效。'
              '这段原来和文件头注释、architecture.md 写的都是技能在前，只有代码'
              '把记忆排在了前面。');
    });

    test('同样的输入产出完全相同的 prompt', () async {
      final builder = testPromptBuilder();
      expect(await builder.build(), await builder.build());
    });
  });

  group('技能要被真的引导着用', () {
    // 「模型从不主动用技能」是用户报的原话。规则说了一堆，但全篇没有一处
    // 示范；人设里更是连"技能"两个字都没出现过。下面几条把这个缺口钉住。

    test('真的人设文件里提了技能——而且是"先翻手册再动手"这个动作', () async {
      // 读**真的** `assets/persona/default.md`，不用 testPromptBuilder 那个
      // 假人设：假人设永远不会有这句话，测了等于没测。
      final persona = File('assets/persona/default.md').readAsStringSync();
      expect(
        persona,
        contains('手册'),
        reason: '人设里一次都没提过技能，"不主动用技能"就不是模型的问题',
      );
      expect(persona, contains('先翻开'));
    });

    test('有一段照着做的示范，不只是"应该这么做"', () async {
      final prompt = await testPromptBuilder().build();
      expect(prompt, contains('skill_read("web-research")'));
      expect(prompt, contains('而不是凭印象直接开始搜'));
    });

    test('不跟人设打架：报工具名是禁止的，说人话讲在干什么是要的', () async {
      final prompt = await testPromptBuilder().build();
      // 这句话原来写的是"不要跟用户汇报你在调用工具"，和人设
      // 「做事时说清楚你在干什么」正面冲突，模型会在那儿犹豫。
      expect(prompt, isNot(contains('不要跟用户汇报')));
      expect(prompt, contains('别跟用户报工具名和参数'));
      expect(prompt, contains('说人话讲你在干什么'));
    });
  });

  group('写代码这一段要跟着工具走', () {
    // 模型默认的自我认知是"我只能输出文字"。光有技能文档不够——那是
    // `skill_read` 才读得到的，而它得先知道这条路存在才会去读。

    test('手上没有代码工具就一个字不提', () async {
      // 用户关了总开关、或者跑在手机上没文件工具的时候，prompt 里写着
      // "你能改文件"就是让模型吹牛。
      final prompt = await testPromptBuilder().build();
      expect(prompt, isNot(contains('写代码和动文件')));
      expect(prompt, isNot(contains('edit_file')));
    });

    test('能跑命令：说清楚是真跑，不是打印出来给人看', () async {
      final prompt = await testPromptBuilder()
          .build(toolNames: const ['get_time', 'run_command']);

      expect(prompt, contains('写代码和动文件'));
      expect(prompt, contains('你是能真跑的'));
      expect(prompt, contains('跑完看退出码'));
      // 没有文件工具就不该提文件那一段。
      expect(prompt, isNot(contains('edit_file')));
    });

    test('能读能写：改文件用 edit_file，别整个覆盖', () async {
      final prompt = await testPromptBuilder()
          .build(toolNames: const ['read_file', 'write_file']);

      expect(prompt, contains('edit_file'));
      expect(prompt, contains('整个覆盖'));
      // 没有跑代码的工具就不该说"直接写出来跑"。
      expect(prompt, isNot(contains('直接写出来跑')));
    });

    test('两样都在：危险操作那段一起给', () async {
      final prompt = await testPromptBuilder().build(
        toolNames: const ['run_code', 'run_command', 'read_file', 'write_file'],
      );

      expect(prompt, contains('危险操作会弹窗'));
      expect(prompt, contains('别换个写法再试'));
      expect(prompt, contains('skill_read("coding")'));
    });

    test('这段跟着「关于工具」走，不是插在技能索引后面', () async {
      // 顺序照旧要稳：代码这段对同一套工具是恒定的，得跟"关于工具"挨着，
      // 不能插到技能索引后面去——那段之后就是最容易变的部分。
      final prompt = await testPromptBuilder()
          .build(toolNames: const ['run_command', 'write_file']);

      expect(
        prompt.indexOf('关于工具'),
        lessThan(prompt.indexOf('写代码和动文件')),
      );
      expect(
        prompt.indexOf('写代码和动文件'),
        lessThan(prompt.indexOf('# 你可以用的技能')),
      );
    });

    test('真的人设文件里也提了——用户改了人设就随他', () async {
      // 跑真的 `assets/persona/default.md`。人设是"模型觉得自己是谁"的
      // 那一层，它不说，光靠工具说明会更费劲。
      final persona = File('assets/persona/default.md').readAsStringSync();
      expect(persona, contains('真的跑东西'));
      expect(persona, contains('手机上只能跑 JavaScript'));
    });

    test('coding 手册的 name 和索引里对得上', () async {
      // `skill_read("coding")` 是按 frontmatter 里的 name 查的。目录名和
      // 它不一致的话，索引里列着 coding、点进去却查不到——而
      // `skill_loader_test.dart` 对的是目录名，抓不到这个。
      final skill = File('assets/skills/coding/SKILL.md').readAsStringSync();
      expect(skill, contains('name: coding'));
      // 触发场景必须写进 description：索引里只有这三行，模型全靠它判断
      // 什么时候该翻开这本。
      expect(skill, contains('跑一下这段'));
    });
  });
}
