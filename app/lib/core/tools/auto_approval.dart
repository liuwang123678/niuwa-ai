import 'tool_approval.dart';

/// 自动模式的判定。
///
/// ## 它是什么
///
/// 用户打开"自动"之后，需要确认的操作**不再弹窗**，直接执行。别的保护一层
/// 都没少：系统目录照样不让写、命令照样有超时、审计日志照样记——只是不再
/// 停下来等那一下。
///
/// ## 为什么单独成一个类
///
/// 这是整个 App 里唯一一处"把安全兜底关掉"的入口。规则值得有一个一眼能读完、
/// 能单独测的地方，而不是散在 `ChatProvider` 的一个 if 里——那种位置改坏了
/// 没有任何症状，`ChatProvider` 又恰好是全项目最难单测的类。
///
/// 判定只看开关本身，**不看请求内容**。这是有意的：自动模式要么开要么关，
/// "这条危险所以还是问一下"听起来稳妥，实际上会让用户没法预判它什么时候
/// 会停——一个会随机停下来问的自动模式，用两次就会被关掉。
class AutoApprovalPolicy {
  const AutoApprovalPolicy({required this.enabled});

  /// 用户在设置里按下的那个开关。
  final bool enabled;

  /// 返回 null 表示"照常弹窗问"。
  ToolApprovalDecision? decide(ToolApprovalRequest request) {
    if (!enabled) return null;
    return const ToolApprovalDecision.autoApproved();
  }
}
