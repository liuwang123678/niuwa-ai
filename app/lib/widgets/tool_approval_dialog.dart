import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../theme.dart';
import 'tool_trace_tile.dart';

/// 把「等待已经被别处收掉」的审批弹窗关掉。
///
/// **只有它还压在栈顶时才 pop。** 用户点「允许」/「不要」时，弹窗自己已经在
/// 退场动画里，路由不再是栈顶（也不再是 present）；这时再 pop 一次，弹掉的
/// 是**底下的聊天页**。导航栈空了，整个窗口就只剩一块黑——进程还活着、
/// 命令还在跑，但什么都不画。2026-10-17 真机就是这么黑的。
///
/// 返回是否真的关了一扇窗（测试要能区分"没关"和"关错了"）。
bool closeApprovalDialogIfCurrent(BuildContext context) {
  if (!context.mounted) return false;
  final route = ModalRoute.of(context);
  if (route == null || !route.isCurrent) return false;
  Navigator.of(context).pop(false);
  return true;
}

/// "这个操作要不要做"的确认弹窗。
///
/// ## 这个弹窗是安全设计里最有效的一环
///
/// 危险命令判定（`danger_command.dart`）是一份**启发式黑名单**，挡不住混淆
/// （`d^el`）、变量拼接、编码、先写脚本再跑。真正拦得住的是：**把原样命令摆给
/// 用户看，让他自己判断**。人一眼就能看出"这条命令要删我的文档"，正则不行。
///
/// 所以这里有一条硬要求：**显示的是原样字符串，不是摘要**。
/// 千万别为了"好看"把 `del /s /q D:\重要资料` 缩成"删除操作"——那就等于把
/// 唯一有效的那道关变成了走过场。
class ToolApprovalDialog extends StatelessWidget {
  const ToolApprovalDialog({super.key, required this.request});

  final ToolApprovalRequest request;

  /// 弹窗上要"原样"展示的那段文本。
  ///
  /// 按已知的参数名挑主字段（命令 / 源码 / 路径），挑不到就把整个参数表铺出来。
  /// **无论如何都不给空**——挑不到就说明这是个新工具，把参数表全给它，
  /// 总比弹一个只有"检测到危险操作"几个字的窗强。
  static String previewOf(ToolApprovalRequest request) {
    for (final key in const ['command', 'source', 'path', 'url']) {
      final value = request.input[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(request.input);
    } catch (_) {
      // 参数里塞了没法序列化的东西（理论上不会，参数是从 JSON 解出来的）。
      // 退回 `toString`，总之得有东西给用户看。
      return request.input.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final what = ToolTraceTile.labelFor(request.tool);

    return AlertDialog(
      title: Text('要我$what吗？', style: n1Text(size: 16.5, weight: 600, color: c.ink)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                request.reason,
                style: n1Text(size: 13.5, height: 1.6, color: c.dim),
              ),
              const SizedBox(height: S.x4),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(S.x3),
                decoration: BoxDecoration(
                  color: c.hasShadow
                      ? Color.alphaBlend(
                          Colors.black.withValues(alpha: 0.035),
                          c.bg,
                        )
                      : c.bg,
                  borderRadius: R.smAll,
                  border: Border.all(color: c.line),
                ),
                // 可选中 + 可滚动：命令可能很长（一整段脚本），也可能用户想
                // 复制出去搜一下"这句到底干什么"。
                child: SingleChildScrollView(
                  child: SelectableText(
                    previewOf(request),
                    style: n1Text(size: 12.5, height: 1.6, color: c.ink, mono: true),
                  ),
                ),
              ),
              const SizedBox(height: S.x3),
              Text(
                '上面是原话，没有省略。看着不对就点「不要」——它不会换个说法再试。',
                style: n1Text(size: 12, height: 1.5, color: c.faint),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('不要'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('允许'),
        ),
      ],
    );
  }
}
