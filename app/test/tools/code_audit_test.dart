import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

/// 记账的那一下。
///
/// 位置很关键：写在 `ToolRegistry.invoke` 里，因为**只有那个地方同时拿得到
/// "审批的结论"和"执行的结果"**。放到工具里写的话，"用户拒了"这一类根本进不来
/// ——被拒的工具压根没执行——而那恰恰是最该留痕的一条。
void main() {
  ToolCall call(String name, [Map<String, Object?> args = const {}]) =>
      ToolCall(id: 'c1', name: name, arguments: args);

  group('记了什么', () {
    test('跑成功了：ran + ok + 退出码 + 耗时', () async {
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(
          _AuditProbeTool(
            result: const ToolResult.ok(
              'done',
              meta: {'exit_code': 0, 'timed_out': false},
            ),
          ),
        );

      await tools.invoke(
        call('risky', const {'command': 'python sum.py', 'working_directory': r'D:\work'}),
        testContext(),
      );

      expect(log.entries, hasLength(1));
      final e = log.entries.single;
      expect(e.tool, 'risky');
      expect(e.decision, CodeDecision.ran);
      expect(e.detail, 'python sum.py');
      expect(e.workingDirectory, r'D:\work');
      expect(e.exitCode, 0);
      expect(e.ok, isTrue);
      expect(e.duration, isNotNull);
    });

    test('退出码非 0：ok 是 false，退出码照实记', () async {
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(
          _AuditProbeTool(
            result: const ToolResult.fail('Traceback…'),
            meta: const {'exit_code': 1},
          ),
        );

      await tools.invoke(call('risky', const {'command': 'python bad.py'}), testContext());

      expect(log.entries.single.exitCode, 1);
      expect(log.entries.single.ok, isFalse);
    });

    test('用户拒绝：denied，**并且退出码和成败都是空的**', () async {
      // 这条是整件事的重点。"被拒了"和"跑了但失败"在日志里要是长得一样，
      // 这份日志就回答不了用户唯一想问的那个问题——它到底动没动我的东西。
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(_AuditProbeTool(approvalReason: (_) => '这条会删东西'));

      await tools.invoke(
        call('risky', const {'command': 'del /s /q D:\\重要资料'}),
        testContext(approver: (_) async => const ToolApprovalDecision.denied()),
      );

      final e = log.entries.single;
      expect(e.decision, CodeDecision.denied);
      expect(e.ok, isNull);
      expect(e.exitCode, isNull);
      // 原文照记——事后查"到底想跑什么"靠的就是这一栏。
      expect(e.detail, 'del /s /q D:\\重要资料');
    });

    test('等超时和"没法问"分开记——一个有界面一个没界面', () async {
      // `no-ask` 出现就说明界面接线断了，是个得修的 bug；而 `timedOut` 是
      // 用户的选择（或者他走开了）。混成一个词，排查的时候要看半天。
      final timedOut = _RecordingAuditLog();
      final a = ToolRegistry()
        ..audit = timedOut
        ..register(_AuditProbeTool(approvalReason: (_) => '要问'));
      await a.invoke(
        call('risky', const {'command': 'x'}),
        testContext(approver: (_) async => const ToolApprovalDecision.timedOut()),
      );

      final noAsk = _RecordingAuditLog();
      final b = ToolRegistry()
        ..audit = noAsk
        ..register(_AuditProbeTool(approvalReason: (_) => '要问'));
      // 不传 approver = 没有确认通道。
      await b.invoke(call('risky', const {'command': 'x'}), testContext());

      expect(timedOut.entries.single.decision, CodeDecision.timedOut);
      expect(noAsk.entries.single.decision, CodeDecision.unavailable);
    });

    test('不用问的工具跑完也记——记的是"跑过"，不是"问过"', () async {
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(_AuditProbeTool());

      await tools.invoke(call('risky', const {'command': 'python ok.py'}), testContext());

      expect(log.entries.single.decision, CodeDecision.ran);
    });

    test('自动模式放行的记成 auto-ran，跟用户点过同意分得开', () async {
      // 这两件事事后要查得出来：一个是我点的，一个是它自己免掉的。
      // 混成一个 `ran`，等到想问"这东西到底动过什么、我当时同不同意"就没答案了。
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(_AuditProbeTool(approvalReason: (_) => '这条会删东西'));

      await tools.invoke(
        call('risky', const {'command': 'del /s /q D:\\旧缓存'}),
        testContext(
          approver: (_) async => const ToolApprovalDecision.autoApproved(),
        ),
      );

      final e = log.entries.single;
      expect(e.decision, CodeDecision.autoRan);
      expect(e.decision.id, 'auto-ran');
      // 确实执行了，所以退出码/成败照记，不能因为"没问"就留空。
      expect(e.ok, isTrue);
    });

    test('用户点同意还是 ran——auto 只有自动模式那一支才会是 true', () async {
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(_AuditProbeTool(approvalReason: (_) => '要问'));

      await tools.invoke(
        call('risky', const {'command': 'x'}),
        testContext(
          approver: (_) async => const ToolApprovalDecision.approved(),
        ),
      );

      expect(log.entries.single.decision, CodeDecision.ran);
    });
  });

  group('不记什么', () {
    test('audited 为 false 的工具一条都不记', () async {
      // 常驻的那批（看时间、抓网页、记忆、提醒）不碰用户电脑。记进去只会把
      // 真正要紧的那几条淹掉。
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(ProbeTool('get_time'));

      await tools.invoke(call('get_time'), testContext());

      expect(log.entries, isEmpty);
    });

    test('没接日志（null）也不出岔子——工具照跑', () async {
      final tools = ToolRegistry()..register(_AuditProbeTool());

      final invocation = await tools.invoke(
        call('risky', const {'command': 'python ok.py'}),
        testContext(),
      );

      expect(invocation.result.ok, isTrue);
    });

    test('工具不存在 / 参数是坏 JSON：不记', () async {
      // 这两条压根没轮到工具执行，记进去只会让日志里多出一堆"没跑成"的噪音，
      // 把真正动过东西的那几条埋掉。
      final log = _RecordingAuditLog();
      final tools = ToolRegistry()
        ..audit = log
        ..register(_AuditProbeTool());

      await tools.invoke(call('没这个工具'), testContext());
      await tools.invoke(call('risky', const {'__raw': '{"broken'}), testContext());

      expect(log.entries, isEmpty);
    });
  });

  group('日志自己出事时', () {
    test('写不进去也不把这次调用带崩', () async {
      // 磁盘满、只读盘、路径被占……都会走到这儿。日志是**旁路**，
      // 它不该有能力让用户的活儿做不成。
      final tools = ToolRegistry()
        ..audit = _ExplodingAuditLog()
        ..register(_AuditProbeTool());

      final invocation = await tools.invoke(
        call('risky', const {'command': 'python ok.py'}),
        testContext(),
      );

      expect(invocation.result.ok, isTrue, reason: '工具跑成功了，日志写不进去不该改这个结果');
    });
  });
}

/// 带 `audited = true` 和按参数回答的探针。
///
/// `ProbeTool` 两样都不够：它的 `audited` 是 false（那正是要验的另一半），
/// 审批也只有一个静态 bool。
class _AuditProbeTool extends N1Tool {
  _AuditProbeTool({
    this.result,
    this.meta,
    String? Function(Map<String, Object?> input)? approvalReason,
  }) : reason = approvalReason;

  final ToolResult? result;
  final Map<String, Object?>? meta;

  /// 按参数回答"要不要问"。字段名不能也叫 `approvalReason`——那是基类上的方法。
  final String? Function(Map<String, Object?> input)? reason;

  @override
  String get name => 'risky';

  @override
  String get description => '测试用';

  @override
  Map<String, Object?> get inputSchema =>
      const {'type': 'object', 'properties': {}};

  @override
  bool get audited => true;

  @override
  String? approvalReason(Map<String, Object?> input) => reason?.call(input);

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final r = result;
    if (r == null) return const ToolResult.ok('ok');
    if (meta == null) return r;
    // 探针自己不会往 meta 里塞东西，测试要的退出码由外面给。
    return ToolResult(ok: r.ok, content: r.content, meta: meta);
  }
}

class _RecordingAuditLog implements CodeAuditLog {
  final List<CodeAuditEntry> entries = [];

  @override
  Future<void> record(CodeAuditEntry entry) async => entries.add(entry);
}

class _ExplodingAuditLog implements CodeAuditLog {
  @override
  Future<void> record(CodeAuditEntry entry) async =>
      throw const FileSystemException('磁盘满了');
}
