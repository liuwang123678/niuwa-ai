import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../theme.dart';

/// 打开自动模式之前的确认框。
///
/// 为什么这个框不能省：自动模式关掉的是整个 App 唯一那道"做之前问你一句"。
/// 用户从输入条上那颗小胶囊、或者设置页的一个开关就能打开它——两个入口
/// 相隔很远，但后果一模一样，所以**必须走同一段文案**，不然总有一处会
/// 写得比另一处轻。
///
/// 返回 true = 用户确认打开。点外面、按返回、点"先不用"都是 false。
Future<bool> confirmAutoApprove(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = N1Colors.of(ctx);
      return AlertDialog(
        title: const Text('打开自动模式？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '之后需要确认的操作——删文件、改东西、跑命令——'
              '它都会直接做，不再问你。',
              style: n1Text(size: 14, color: c.ink, height: 1.5),
            ),
            const SizedBox(height: S.x3),
            Text(
              '还能拦住的只有两条：系统目录不让写、每一步都记进审计日志'
              '（标成「自动」）。买错东西、删错东西这一类，事后没法替你撤销。',
              style: n1Text(size: 13, color: c.dim, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('先不用'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: c.danger),
            child: const Text('我知道，打开'),
          ),
        ],
      );
    },
  );
  return ok == true;
}
