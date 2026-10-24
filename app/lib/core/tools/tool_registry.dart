import 'dart:async';

import '../code/audit_log.dart';
import '../llm/llm_client.dart';
import '../models/chat_message.dart';
import 'n1_tool.dart';
import 'tool_approval.dart';
import 'tool_context.dart';

/// 一次工具调用的执行记录。界面拿它渲染"调用了什么、结果如何"。
class ToolInvocation {
  const ToolInvocation({
    required this.call,
    required this.result,
    required this.duration,
  });

  final ToolCall call;
  final ToolResult result;
  final Duration duration;
}

/// 工具表。
///
/// 平台缺哪个能力就**不注册**对应的工具——模型看不到就不会去调，
/// 比注册了再返回"不支持"要好（后者会让模型反复重试同一个不可用的工具）。
class ToolRegistry {
  ToolRegistry([Iterable<N1Tool> tools = const []]) {
    for (final t in tools) {
      register(t);
    }
  }

  final Map<String, N1Tool> _tools = {};

  /// 单个工具的超时。浏览器类工具慢，注册时可以单独调大。
  final Map<String, Duration> _timeouts = {};

  static const Duration _defaultTimeout = Duration(seconds: 30);

  /// 单条工具结果回喂给模型的**字数上限**。null = 不限（默认）。
  ///
  /// 由工作强度（`WorkLevel.toolResultChars`）设定，落在这里是因为
  /// [invoke] 是**所有**工具结果的必经之路，也是它们被交还给模型的那一刻。
  /// 放到各个工具里各截各的，以后新加一个工具忘了截，症状只是账单悄悄涨一截。
  int? resultChars;

  /// 动用户电脑的调用往哪儿记账。null = 不记。
  ///
  /// 放在注册表上而不是 [ToolContext] 里：写一条需要的东西——**审批的结论**
  /// 和**执行的结果**——只有 [invoke] 这一个地方同时拿得到。放到工具里写的话，
  /// "用户拒了"这一类根本进不来（被拒的工具压根没执行），而那恰恰是最该留痕的。
  CodeAuditLog? audit;

  void register(N1Tool tool, {Duration? timeout}) {
    _tools[tool.name] = tool;
    if (timeout != null) _timeouts[tool.name] = timeout;
  }

  bool remove(String name) {
    _timeouts.remove(name);
    return _tools.remove(name) != null;
  }

  /// 这个工具注册时指定的超时。**没指定就是 null**（真跑时走 [_defaultTimeout]）。
  ///
  /// 存在的理由：浏览器工具**必须**显式放宽到 60 秒，否则"打开一个慢站"会
  /// 撞上默认的 30 秒，模型收到"超时了"就以为这个站打不开。而"注册时带上
  /// 了 timeout 吗"这件事光看代码没法验证——少了那一个具名参数，测试全绿，
  /// 症状只在真跑里出现。所以留一个读的口子让它可断言。
  Duration? timeoutFor(String name) => _timeouts[name];

  N1Tool? byName(String name) => _tools[name];

  List<N1Tool> get all =>
      _tools.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  bool get isEmpty => _tools.isEmpty;

  /// 喂给模型的工具声明。顺序稳定，别改——system prompt 变了会打掉提示缓存。
  List<ToolSpec> get specs => all.map((t) => t.spec).toList();

  /// 执行一次调用。
  ///
  /// **任何异常都在这里被吃掉，转成 `ToolResult.fail`。** 工具崩了不该把整轮对话带崩，
  /// 而且模型看到明确的失败原因后往往能自己换个法子。
  Future<ToolInvocation> invoke(ToolCall call, ToolContext ctx) async {
    final started = DateTime.now();
    final tool = _tools[call.name];

    if (tool == null) {
      return ToolInvocation(
        call: call,
        result: ToolResult.fail(
          // 注意 ${call.name} 的花括号：`$call.name` 只插值 call，`.name` 会变成字面量
          '没有叫 `${call.name}` 的工具。可用的是：'
          '${_tools.keys.join('、')}',
        ),
        duration: Duration.zero,
      );
    }

    // 参数里带 __raw 说明模型吐的 JSON 就是坏的，直接报回去让它重发。
    if (call.arguments.containsKey('__raw')) {
      return ToolInvocation(
        call: call,
        result: ToolResult.fail(
          '参数不是合法 JSON。请重新按 schema 生成 `${call.name}` 的参数。',
        ),
        duration: Duration.zero,
      );
    }

    // 需要审批的调用先问用户。
    //
    // **位置很讲究，两件事都要对**：
    //   1. 在 `__raw` 检查之后——参数都没解析出来，弹窗上给不出命令原文；
    //   2. 在 `timeout` 之外——等用户点弹窗可能要一两分钟，而下面那个 timeout
    //      是留给工具**执行**的。两件事共用一个时限的话，"用户想久了"会被
    //      报成"工具超时"，而且工具会被当成失败。
    //
    // 拒绝在这条路径上**自动变成一次普通的 fail**，所以照样会产出
    // `ToolCallFinished` 和一条 tool 消息——界面的转圈会停，历史也是合法的。
    // 这正是把审批放在这里、而不是放在 `AgentLoop` 里的全部理由。
    final approvalReason = tool.approvalReason(call.arguments);
    var autoApproved = false;
    if (approvalReason != null) {
      final decision = await _ask(ctx, call, approvalReason);
      if (!decision.isApproved) {
        final refused = ToolInvocation(
          call: call,
          result: ToolResult.fail(approvalRefusalText(decision)),
          duration: DateTime.now().difference(started),
        );
        await _audit(ctx, tool, call, _refusalOf(decision), refused);
        return refused;
      }
      autoApproved = decision.auto;
    }

    final timeout = _timeouts[call.name] ?? _defaultTimeout;
    ToolResult result;
    try {
      result = await tool.call(call.arguments, ctx).timeout(timeout);
    } on ToolInputException catch (e) {
      result = ToolResult.fail('参数错误：${e.message}');
    } on TimeoutException {
      result = ToolResult.fail('超时了（${timeout.inSeconds} 秒没返回）');
    } catch (e) {
      result = ToolResult.fail('${e.runtimeType}: $e');
    }

    final invocation = ToolInvocation(
      call: call,
      result: _cap(result),
      duration: DateTime.now().difference(started),
    );
    await _audit(
      ctx,
      tool,
      call,
      autoApproved ? CodeDecision.autoRan : CodeDecision.ran,
      invocation,
    );
    return invocation;
  }

  /// 把审批的结论翻成日志里的那个词。
  ///
  /// 三个"没执行"分开记是**有意**的：用户点「不要」和等了 120 秒没人管是
  /// 两回事，而"这个环境没有确认通道"又是一回事（那说明界面接线断了，
  /// 是个得修的 bug，不是用户的选择）。
  static CodeDecision _refusalOf(ToolApprovalDecision decision) =>
      switch (decision.outcome) {
        ApprovalOutcome.denied => CodeDecision.denied,
        ApprovalOutcome.timedOut => CodeDecision.timedOut,
        ApprovalOutcome.unavailable => CodeDecision.unavailable,
        // 走进来的是"批准了"，调用方只在没通过时才叫这个函数。
        // 真到这儿了记成 ran 也不对——那次确实没执行；但更不该抛异常把
        // 一轮对话带崩。记一条"没问成"，反正这条本身就不该发生。
        ApprovalOutcome.approved => CodeDecision.unavailable,
      };

  /// 记一笔。**只记 [N1Tool.audited] 的工具。**
  ///
  /// 写日志失败绝不能把工具调用带崩：日志是**旁路**，不是执行的一部分。
  Future<void> _audit(
    ToolContext ctx,
    N1Tool tool,
    ToolCall call,
    CodeDecision decision,
    ToolInvocation invocation,
  ) async {
    final log = audit;
    if (log == null || !tool.audited) return;

    final meta = invocation.result.meta;
    final ran =
        decision == CodeDecision.ran || decision == CodeDecision.autoRan;

    // 只有在真跑了的时候，退出码和成败才有意义。被拒的那次记个 exit=0 / ok
    // 会直接骗人——"没成功"和"压根没执行"是两回事。
    //
    // ⚠️ 这里写成 `meta != null ? meta['exit_code'] : null` 而不是
    // `meta?['exit_code']`：后者在**三元表达式里**是有歧义的——解析器会把它
    // 读成 `cond ? [列表] : ...`，直接报"Conditions must have a static type
    // of 'bool'"。别为了少写几个字掉进去。
    final Object? rawExit = ran && meta != null ? meta['exit_code'] : null;

    try {
      await log.record(
        CodeAuditEntry(
          at: DateTime.now(),
          tool: call.name,
          decision: decision,
          detail: toolDetailOrJson(call.arguments),
          workingDirectory: call.arguments['working_directory'] as String?,
          exitCode: rawExit is int ? rawExit : null,
          ok: ran ? invocation.result.ok : null,
          duration: invocation.duration,
        ),
      );
    } catch (e) {
      ctx.log('审计日志写不进去（不影响这次调用）：$e');
    }
  }

  /// 按 [resultChars] 截。**截断只在 [invoke] 的出入口这一个地方发生**，
  /// 所以界面上看到的和模型收到的是同一份——两边不一致的话，用户会以为
  /// 模型看见了全部。
  ToolResult _cap(ToolResult result) {
    final limit = resultChars;
    if (limit == null) return result;
    return result.limitedTo(limit);
  }

  /// 把"要不要做"这个问题交给界面，拿回一个决定。
  ///
  /// 三条守则：
  ///   - **没有 approver 就是拒绝**（`unavailable`），不是放行——见那处的说明；
  ///   - 审批本身**不设超时**：时限该由实现方定（他要弹窗、要用户读命令、
  ///     要处理"用户离开一会儿"）。这里再套一层只会把"用户还在看"误报成超时，
  ///     而那是个**假的失败**，模型会以为是自己做错了什么；
  ///   - 回调抛异常**按拒绝**处理。弹窗崩了不该让整轮对话崩，但更不能当成同意。
  static Future<ToolApprovalDecision> _ask(
    ToolContext ctx,
    ToolCall call,
    String reason,
  ) async {
    final approver = ctx.approver;
    if (approver == null) return const ToolApprovalDecision.unavailable();
    try {
      return await approver(
        ToolApprovalRequest(
          tool: call.name,
          input: call.arguments,
          reason: reason,
        ),
      );
    } catch (e) {
      ctx.log('审批回调出错，按拒绝处理：$e');
      return const ToolApprovalDecision.denied('确认的时候出了点问题');
    }
  }
}
