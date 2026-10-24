import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

ToolCall _call(String name, [Map<String, Object?> args = const {}]) =>
    ToolCall(id: 'c1', name: name, arguments: args);

/// 按参数决定要不要问的工具。
///
/// `ProbeTool` 只有静态的 `requiresApproval`，表达不了"看参数才知道"——
/// 而那正是审批门存在的理由，所以这里得有个能按参数回答的。
class _ConditionalTool extends N1Tool {
  _ConditionalTool(this.reasonFor);

  final String? Function(Map<String, Object?> input) reasonFor;

  /// 真执行过几次。**"被拒了没执行"全靠它证伪**——只看返回值的话，
  /// 一个"先执行再假装拒绝"的实现照样能过。
  final List<Map<String, Object?>> ran = [];

  @override
  String get name => 'risky';

  @override
  String get description => '测试用';

  @override
  Map<String, Object?> get inputSchema =>
      const {'type': 'object', 'properties': {}};

  @override
  String? approvalReason(Map<String, Object?> input) => reasonFor(input);

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    ran.add(input);
    return const ToolResult.ok('做完了');
  }
}

/// 记账的审批人：说要返回什么，还数被问了几次。
class _RecordingApprover {
  _RecordingApprover(this.decision);

  final ToolApprovalDecision decision;
  final List<ToolApprovalRequest> asked = [];

  Future<ToolApprovalDecision> call(ToolApprovalRequest request) async {
    asked.add(request);
    return decision;
  }
}

void main() {
  group('审批门', () {
    test('不用问的工具，压根不碰审批人', () async {
      final registry = ToolRegistry()..register(ProbeTool('safe'));
      final approver = _RecordingApprover(const ToolApprovalDecision.denied());

      final inv = await registry.invoke(
        _call('safe'),
        testContext(approver: approver.call),
      );

      expect(inv.result.ok, isTrue);
      expect(
        approver.asked,
        isEmpty,
        reason: 'approvalReason 返回 null 的工具不该打扰用户——'
            '这正是"只对危险操作问"的实现方式',
      );
    });

    test('批准了才真执行', () async {
      final tool = ProbeTool('danger', requiresApproval: true);
      final registry = ToolRegistry()..register(tool);
      final approver = _RecordingApprover(const ToolApprovalDecision.approved());

      final inv = await registry.invoke(
        _call('danger'),
        testContext(approver: approver.call),
      );

      expect(inv.result.ok, isTrue);
      expect(tool.receivedInputs, hasLength(1));
      expect(approver.asked, hasLength(1));
      expect(approver.asked.single.tool, 'danger');
    });

    test('拒绝了 → 失败结果，而且**没执行**', () async {
      final tool = _ConditionalTool((_) => '这条命令会删东西');
      final registry = ToolRegistry()..register(tool);

      final inv = await registry.invoke(
        _call('risky'),
        testContext(
          approver: (r) async => const ToolApprovalDecision.denied('别删'),
        ),
      );

      expect(inv.result.ok, isFalse);
      expect(inv.result.content, contains('拒绝'));
      expect(tool.ran, isEmpty, reason: '被拒的调用绝对不能真跑');
    });

    test('拒绝文案要拦得住重试', () async {
      final registry = ToolRegistry()
        ..register(ProbeTool('danger', requiresApproval: true));

      final inv = await registry.invoke(
        _call('danger'),
        testContext(
          approver: (r) async => const ToolApprovalDecision.denied(),
        ),
      );

      // 模型看不见弹窗。不说这句它会拿同一件事反复撞，把轮数烧光。
      expect(inv.result.content, contains('不要重试同一个'));
    });

    test('没有审批人 = 拒绝，不是放行', () async {
      // ⚠️ 这条是整个安全设计的默认值。改成"放行"的话，任何忘了接审批界面的
      // 环境（新平台、命令行工具、测试里漏了）都会**静默执行危险操作**。
      final tool = _ConditionalTool((_) => '危险');
      final registry = ToolRegistry()..register(tool);

      final inv = await registry.invoke(_call('risky'), testContext());

      expect(inv.result.ok, isFalse);
      expect(inv.result.content, contains('没有确认的界面'));
      expect(tool.ran, isEmpty);
    });

    test('审批人自己崩了 → 按拒绝，不当成同意', () async {
      final tool = _ConditionalTool((_) => '危险');
      final registry = ToolRegistry()..register(tool);

      final inv = await registry.invoke(
        _call('risky'),
        testContext(approver: (r) async => throw StateError('弹窗炸了')),
      );

      expect(inv.result.ok, isFalse);
      expect(tool.ran, isEmpty);
    });

    test('看参数决定：同一个工具，一个问一个不问', () async {
      final tool = _ConditionalTool(
        (input) => input['cmd'] == 'del' ? '要删东西' : null,
      );
      final registry = ToolRegistry()..register(tool);
      final approver = _RecordingApprover(const ToolApprovalDecision.approved());
      final ctx = testContext(approver: approver.call);

      await registry.invoke(_call('risky', {'cmd': 'echo hi'}), ctx);
      expect(approver.asked, isEmpty, reason: 'echo 不该问');

      await registry.invoke(_call('risky', {'cmd': 'del'}), ctx);
      expect(approver.asked, hasLength(1), reason: 'del 该问');
      expect(approver.asked.single.reason, '要删东西');
    });

    test('超时和"没法问"是两种不同的说法', () async {
      final registry = ToolRegistry()
        ..register(ProbeTool('danger', requiresApproval: true));

      final timedOut = await registry.invoke(
        _call('danger'),
        testContext(
          approver: (r) async => const ToolApprovalDecision.timedOut(),
        ),
      );
      final unavailable = await registry.invoke(
        _call('danger'),
        testContext(),
      );

      expect(timedOut.result.content, contains('超时'));
      expect(unavailable.result.content, contains('没有确认的界面'));
      expect(
        timedOut.result.content,
        isNot(unavailable.result.content),
        reason: '两种失败对模型该说不同的话——一个是"再问一次"，'
            '一个是"这个环境做不到"',
      );
    });

    test('审批请求把原样参数带给界面', () async {
      // 弹窗要显示原样命令，不是"检测到危险操作"。用户判断依赖原文。
      final registry = ToolRegistry()
        ..register(ProbeTool('danger', requiresApproval: true));
      final approver = _RecordingApprover(const ToolApprovalDecision.denied());

      await registry.invoke(
        _call('danger', {'command': 'del /s /q C:\\temp'}),
        testContext(approver: approver.call),
      );

      expect(approver.asked.single.input['command'], 'del /s /q C:\\temp');
    });
  });
}
