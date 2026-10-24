import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 审计日志那一行的形状。
///
/// 单独拎出来测是因为这是**唯一一份给人看、也给人切的格式**：字段错了不会
/// 报错，只会在用户真的去查"它昨天干了什么"的时候才发现——而那时候已经
/// 没机会重记了。
void main() {
  CodeAuditEntry entry({
    CodeDecision decision = CodeDecision.ran,
    String tool = 'run_command',
    String detail = 'python sum.py',
    String? cwd,
    int? exitCode,
    bool? ok,
    Duration? duration,
  }) => CodeAuditEntry(
    at: DateTime(2026, 10, 10, 21, 4, 11),
    tool: tool,
    decision: decision,
    detail: detail,
    workingDirectory: cwd,
    exitCode: exitCode,
    ok: ok,
    duration: duration,
  );

  group('一行', () {
    test('字段顺序和分隔：tab 隔开，时间在最前', () {
      final line = entry(
        cwd: r'D:\work',
        exitCode: 0,
        ok: true,
        duration: const Duration(milliseconds: 120),
      ).toLine();

      expect(
        line,
        '2026-10-10 21:04:11\tran\trun_command\tok\texit=0\t'
        'took=120ms\tcwd=D:\\work\tpython sum.py',
      );
    });

    test('补零：个位数的月日时分秒都要两位', () {
      // 不补零的话 `2026-1-5 9:4:3` 这种行按字典序排会乱到另一年去——
      // 而这份日志迟早会被 sort 或者 diff。
      final line = CodeAuditEntry(
        at: DateTime(2026, 1, 5, 9, 4, 3),
        tool: 'run_code',
        decision: CodeDecision.ran,
      ).toLine();

      expect(line, startsWith('2026-01-05 09:04:03\t'));
    });

    test('没跑的记录：ok 和 exit 都是「—」，不是 false / 0', () {
      // 这一条是本文件最要紧的断言。"用户拒绝了，所以没成功"和"跑了但失败了"
      // 在日志里长得一样的话，这份日志就没法回答"它到底动没动我的东西"。
      final line = entry(decision: CodeDecision.denied).toLine();

      expect(line, contains('\t—\texit=—\t'));
      expect(line, isNot(contains('fail')));
      expect(line, isNot(contains('exit=0')));
    });

    test('失败了：ok 位是 fail', () {
      final line = entry(exitCode: 1, ok: false).toLine();
      expect(line, contains('\tfail\texit=1\t'));
    });

    test('每种结论一个词，写日志的人和读日志的人都认同一个', () {
      expect(CodeDecision.ran.id, 'ran');
      expect(CodeDecision.denied.id, 'denied');
      expect(CodeDecision.timedOut.id, 'timedOut');
      expect(CodeDecision.unavailable.id, 'no-ask');
    });

    test('命令在最后一个字段——它自己可能带 tab', () {
      // 放中间的话，那种行会被切成错位的字段，比不解析还糟。放最后，读的人
      // 才能"切前 7 刀，剩下的全算命令"。
      final line = entry(detail: 'echo a\tb').toLine();
      final fields = line.split('\t');

      expect(fields, hasLength(9), reason: '前 7 个固定字段 + 被切成两半的命令');
      expect(fields.take(7).join('\t'), entry(detail: '').toLine().split('\t').take(7).join('\t'));
      expect(fields.skip(7).join('\t'), 'echo a\tb');
    });
  });

  group('挑哪一段', () {
    test('命令优先，其次路径、脚本、网址、查询词', () {
      expect(toolDetail(const {'command': 'ls', 'path': r'D:\x'}), 'ls');
      expect(toolDetail(const {'path': r'D:\x', 'source': 'print(1)'}), r'D:\x');
      expect(toolDetail(const {'source': 'print(1)', 'url': 'https://a'}), 'print(1)');
      expect(toolDetail(const {'url': 'https://a', 'query': 'q'}), 'https://a');
      expect(toolDetail(const {'query': 'q'}), 'q');
    });

    test('压成一行：换行和连续空格不留着', () {
      // 一条记录必须是一行。多行脚本原样写进去会把日志切得没法看。
      expect(toolDetail(const {'command': '  ls\n  -la  '}), 'ls -la');
    });

    test('全是空白等于没有', () {
      expect(toolDetail(const {'command': '   \n '}), '');
      expect(toolDetail(const {'command': 3}), '');
      expect(toolDetail(const {}), '');
    });

    test('挑不到就退回整张参数表——宁可难看也别空着', () {
      // 空 detail 的一行记录只剩"它动过东西"，等于没记。
      expect(toolDetailOrJson(const {'weird': 'x'}), '{"weird":"x"}');
      // 有得挑的时候不铺表。
      expect(toolDetailOrJson(const {'command': 'ls', 'cwd': r'D:\'}), 'ls');
    });

    test('参数表里有序列化不了的东西也不抛', () {
      // 参数都是从 JSON 解出来的，理论上到不了这儿。真到了也不该把
      // 一次工具调用带崩。
      expect(toolDetailOrJson({'obj': Object()}), isNotEmpty);
    });
  });
}
