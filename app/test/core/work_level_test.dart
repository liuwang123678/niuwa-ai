import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 工作强度这个旋钮。
///
/// 最重要的一条是**「标准 ＝ 加这个功能之前的行为」**——用户升级完什么都不选，
/// 不该发现它变笨了或者变抠了。这条要是松了，所有人都会觉得新版"变傻"，
/// 而且是那种查不出来的傻：没有报错、没有日志，只是答案差了一点。
void main() {
  group('标准档必须等于旧行为', () {
    test('六个数字逐一钉住', () {
      const l = WorkLevel.standard;

      // 这几条是**照着改之前代码里写死的值**抄的，不是"看着合理"填的：
      //   AgentLoop(maxTurns: 8)            —— 默认值
      //   installBrowserTools → maxTurns 20 —— 那一处的注释
      //   installCodeTools    → maxTurns 30 —— 那一处的注释
      //   PromptBuilder(memoryIndexLimit: 20)
      //   工具结果不截断 / 历史全带 —— 以前压根没这两件事
      expect(l.maxTurns, 8);
      expect(l.browserTurns, 20);
      expect(l.codeTurns, 30);
      expect(l.memoryIndexLimit, 20);
      expect(l.toolResultChars, isNull, reason: '标准档不许截工具结果');
      expect(l.historyMessages, isNull, reason: '标准档不许砍历史');
    });

    test('没存过、或存着一个认不出的 id，都退回标准', () {
      // 退回别的档都不行：退回"省着用"是偷偷降级，退回"放开干"是偷偷加钱。
      expect(WorkLevel.fromId(null), WorkLevel.standard);
      expect(WorkLevel.fromId(''), WorkLevel.standard);
      expect(WorkLevel.fromId('standard'), WorkLevel.standard);
      expect(WorkLevel.fromId('（以后某个被删掉的档）'), WorkLevel.standard);
    });
  });

  group('三档的 id', () {
    test('id 是存进设置里的东西，写进测试就是钉住它不能被改', () {
      // 改 id 等于把老用户存的档位弄丢——他们会被静默退回标准，
      // 而"我明明选过省着用"这件事没有任何地方能看出来。
      expect(
        WorkLevel.values.map((l) => l.id).toList(),
        ['frugal', 'standard', 'thorough'],
      );
    });

    test('每个 id 都能认回来', () {
      for (final level in WorkLevel.values) {
        expect(WorkLevel.fromId(level.id), level, reason: level.id);
      }
    });

    test('label 是人话，不重复', () {
      final labels = WorkLevel.values.map((l) => l.label).toSet();
      expect(labels.length, WorkLevel.values.length);
      expect(WorkLevel.standard.label, '标准');
    });
  });

  group('档位之间的方向', () {
    test('越往上给得越多——以后加档也别写歪', () {
      for (var i = 1; i < WorkLevel.values.length; i++) {
        final low = WorkLevel.values[i - 1];
        final high = WorkLevel.values[i];
        expect(high.maxTurns, greaterThan(low.maxTurns), reason: high.id);
        expect(high.browserTurns, greaterThan(low.browserTurns), reason: high.id);
        expect(high.codeTurns, greaterThan(low.codeTurns), reason: high.id);
        expect(
          high.memoryIndexLimit,
          greaterThan(low.memoryIndexLimit),
          reason: high.id,
        );
      }
    });

    test('省着用真的比标准省，而且省在两处', () {
      const frugal = WorkLevel.frugal;
      // 截工具结果——这项是 agent 任务里的大头。
      expect(frugal.toolResultChars, isNotNull);
      expect(frugal.toolResultChars!, lessThan(6000));
      // 少带历史——这项是纯聊天里的大头。
      expect(frugal.historyMessages, isNotNull);
      expect(frugal.maxTurns, lessThan(WorkLevel.standard.maxTurns));
    });

    test('放开干不许自称省钱', () {
      // 它就是把 token 换成"别停下"，文案上写"又省又能干"就是骗人。
      // 这条测试守的是文案，但文案会直接进设置页给用户看。
      expect(WorkLevel.thorough.summary, isNot(contains('省')));
    });

    test('省着用的说明里必须写出代价', () {
      // 砍了回合、砍了工具结果、只带最近一段历史——用户碰上"它忘了刚才说的"
      // 时才不会以为是 bug。靠瞒着用户省钱是不行的。
      final s = WorkLevel.frugal.summary;
      expect(s, contains('历史'));
    });

    test('按话题捞的记忆条数跟着档位走：省着用 < 标准 < 放开干', () {
      // 这一份是**每句话**都重发的，不是 system prompt 里那份静态索引。
      // 所以"标准"给 6 条就够了，往上只多不少，但别跟索引一样给到 20/40。
      expect(WorkLevel.frugal.recallLimit, lessThan(WorkLevel.standard.recallLimit));
      expect(
        WorkLevel.standard.recallLimit,
        lessThan(WorkLevel.thorough.recallLimit),
      );
      expect(WorkLevel.standard.recallLimit, lessThan(WorkLevel.standard.memoryIndexLimit));
    });

    test('每一档都有说明，而且不是同一条', () {
      final summaries = WorkLevel.values.map((l) => l.summary).toSet();
      expect(summaries.length, WorkLevel.values.length);
      for (final level in WorkLevel.values) {
        expect(level.summary.trim(), isNotEmpty, reason: level.id);
      }
    });
  });
}
