import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../theme.dart';

/// 从平台给的模型清单里挑一个。
///
/// 返回挑中的名字；用户取消返回 null。
///
/// ## 为什么它不是一个下拉框
///
/// 这份清单是**平台自己给的，我们没验证过**——各家筛不筛、排不排序都不一样。
/// 做成锁死的下拉等于把一张没验证过的名单当成真理，比让用户手填更糟。
/// 所以选完是落回设置页那个**可编辑的输入框**，想填清单里没有的名字照样能填。
///
/// 底下那行小字就是写给这件事的，别删。
///
/// ## 为什么上面有筛选框
///
/// 硅基流动这类平台的清单是几百条。没有筛选的话，用户只能在一个三百行的列表里
/// 拿眼睛找——那还不如去官网复制。
class ModelPickerDialog extends StatefulWidget {
  const ModelPickerDialog({
    super.key,
    required this.models,
    required this.current,
  });

  final List<String> models;

  /// 现在用的模型名，在列表里给它打个勾。
  final String current;

  @override
  State<ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<ModelPickerDialog> {
  final TextEditingController _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<String> get _shown {
    final q = _filter.text.trim().toLowerCase();
    if (q.isEmpty) return widget.models;
    return widget.models
        .where((m) => m.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final shown = _shown;

    return AlertDialog(
      title: Text('选一个模型（共 ${widget.models.length} 个）'),
      content: SizedBox(
        width: 460,
        // 限高，不然几百个模型会把弹窗撑得比屏幕还高。
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _filter,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: n1Text(size: 13, height: 1.4),
              decoration: const InputDecoration(
                hintText: '筛一下，比如输入 kimi',
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
              ),
            ),
            const SizedBox(height: S.x3),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的。',
                        style: n1Text(size: 13, height: 1.4, color: c.dim),
                      ),
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final id = shown[i];
                        final isCurrent = id == widget.current;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            id,
                            style: n1Text(
                              size: 12.5,
                              height: 1.4,
                              color: isCurrent ? c.accentInk : c.ink,
                              mono: true,
                            ).n1W(isCurrent ? 600 : 400),
                          ),
                          trailing: isCurrent
                              ? Icon(Icons.check, size: 16, color: c.accentInk)
                              : null,
                          onTap: () => Navigator.pop(context, id),
                        );
                      },
                    ),
            ),
            const SizedBox(height: S.x2),
            Text(
              '这份清单是平台自己给的，我们没验证过——挑完照样能在输入框里改，'
              '想填清单里没有的名字也不拦着。',
              style: n1Text(size: 12, height: 1.6, color: c.faint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
