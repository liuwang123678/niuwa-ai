import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 自动模式的判定。
///
/// 它只回答一个问题："这次要不要弹窗"。而且答案**只看开关**，不看请求内容
/// ——会随机停下来问的自动模式，用两次就会被关掉，用户也没法预判。
///
/// 真正危险的部分不在这里：系统目录照样不让写、审计日志照样记（`auto-ran`）。
/// 这里只保证"关着的时候一定弹窗"。
void main() {
  const request = ToolApprovalRequest(
    tool: 'run_command',
    input: {'command': 'del /s /q D:\\重要资料'},
    reason: '这条会删东西',
  );

  test('关着的时候返回 null —— 照常弹窗问', () {
    const policy = AutoApprovalPolicy(enabled: false);
    expect(policy.decide(request), isNull);
  });

  test('开着的时候直接放行，并且标成 auto', () {
    const policy = AutoApprovalPolicy(enabled: true);
    final decision = policy.decide(request);
    expect(decision, isNotNull);
    expect(decision!.isApproved, isTrue);
    expect(decision.auto, isTrue);
    expect(decision.outcome, ApprovalOutcome.approved);
  });

  test('不看请求内容——再危险也一样放行', () {
    // 这是有意的。"这条太危险还是问一下吧"会让用户没法预判它什么时候停。
    const policy = AutoApprovalPolicy(enabled: true);
    for (final command in [
      'rm -rf /',
      'format D:',
      'shutdown /s /t 0',
    ]) {
      final decision = policy.decide(
        ToolApprovalRequest(
          tool: 'run_command',
          input: {'command': command},
          reason: '危险',
        ),
      );
      expect(decision?.isApproved, isTrue, reason: command);
    }
  });

  test('普通 approved 不会被误标成 auto', () {
    expect(const ToolApprovalDecision.approved().auto, isFalse);
  });
}
