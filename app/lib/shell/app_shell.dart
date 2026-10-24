import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../pages/chat_page.dart';
import '../pages/memory_page.dart';
import '../pages/settings_page.dart';
import '../pages/skills_page.dart';
import '../theme.dart';
import '../widgets/n1_mark.dart';

/// 四个页面的壳。
///
/// 宽屏用左侧竖栏、窄屏用底部横条。**不是"桌面用侧栏、手机用底栏"那么简单**：
/// 判断依据是**可用宽度**而不是平台——安卓平板横过来也该用侧栏，Windows 上把
/// 窗口拖窄了也该换成底栏。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// 到这个宽度就换成侧栏。
  static const double wideBreakpoint = 900;

  /// 侧栏宽度。
  static const double railWidth = 84;

  /// 侧栏顶部那只牛蛙的尺寸。
  static const double railMarkSize = 30;

  /// 侧栏那只牛蛙的中心，从屏幕左上角算起。
  ///
  /// **启动动画要落到这里**，所以这几个数必须只有一个来源：闪屏那边
  /// 自己再写一遍 84 / 20 / 30 的话，将来侧栏一改，蛙就会飞到空气里。
  /// 坐标从屏幕顶算，因为 `Scaffold` 的 body 不带自动 SafeArea，
  /// 侧栏的 Padding 就是从 body 顶边量起的。
  static const Offset railMarkCenter = Offset(
    railWidth / 2,
    S.x6 + railMarkSize / 2,
  );

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _items = <_NavItem>[
    _NavItem(Icons.chat_bubble_outline, Icons.chat_bubble, '聊天'),
    _NavItem(Icons.psychology_outlined, Icons.psychology, '记忆'),
    _NavItem(Icons.auto_awesome_outlined, Icons.auto_awesome, '技能'),
    _NavItem(Icons.settings_outlined, Icons.settings, '设置'),
  ];

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= AppShell.wideBreakpoint;

    // IndexedStack 而不是每次重建：聊天页有滚动位置、输入框里的半句话、
    // 记忆页有搜索词。切一下标签页就全丢，是很难忍的。
    final pages = <Widget>[
      ChatPage(onOpenSettings: () => _go(3)),
      const MemoryPage(),
      const SkillsPage(),
      const SettingsPage(),
    ];

    return Scaffold(
      body: wide
          ? Row(
              children: [
                _SideRail(current: _index, onSelect: _go, items: _items),
                Expanded(child: IndexedStack(index: _index, children: pages)),
              ],
            )
          : IndexedStack(index: _index, children: pages),
      bottomNavigationBar: wide
          ? null
          : _BottomBar(current: _index, onSelect: _go, items: _items),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.activeIcon, this.label);

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

// ══════════════════════════════════════════════════════════════════
// 窄屏：底部横条
// ══════════════════════════════════════════════════════════════════

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.current,
    required this.onSelect,
    required this.items,
  });

  final int current;
  final ValueChanged<int> onSelect;
  final List<_NavItem> items;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavButton(
                    item: items[i],
                    selected: i == current,
                    onTap: () => onSelect(i),
                    vertical: true,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 宽屏：左侧竖栏
// ══════════════════════════════════════════════════════════════════

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.current,
    required this.onSelect,
    required this.items,
  });

  final int current;
  final ValueChanged<int> onSelect;
  final List<_NavItem> items;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Container(
      width: AppShell.railWidth,
      decoration: BoxDecoration(
        color: c.raised,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          // 顶上放标志而不是标题：竖栏只有 84 宽，塞文字会挤成一团，
          // 而标志本来就该是这个 App 最好认的那一样东西。
          const Padding(
            padding: EdgeInsets.only(top: S.x6, bottom: S.x5),
            child: N1Mark(size: AppShell.railMarkSize),
          ),
          for (var i = 0; i < items.length; i++)
            _NavButton(
              item: items[i],
              selected: i == current,
              onTap: () => onSelect(i),
              vertical: false,
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 按钮
// ══════════════════════════════════════════════════════════════════

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.vertical,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  /// true = 图标在上、文字在下（底栏）；false = 只显示图标（侧栏）。
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final color = selected ? c.accentInk : c.faint;

    final icon = AnimatedSwitcher(
      duration: M.fast,
      switchInCurve: M.out,
      switchOutCurve: M.out,
      child: Icon(
        selected ? item.activeIcon : item.icon,
        key: ValueKey(selected),
        size: 22,
        color: color,
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        // 水波纹要关掉：这个按钮是"选中态 + 背景胶囊"的形态，再加上一片
        // 灰色水波会显得很脏。
        splashFactory: NoSplash.splashFactory,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: SizedBox(
          height: vertical ? null : 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (vertical) const SizedBox(height: S.x2),
              AnimatedContainer(
                duration: M.base,
                curve: M.out,
                padding: EdgeInsets.symmetric(
                  horizontal: vertical ? S.x5 : S.x4,
                  vertical: vertical ? S.x1 : S.x2,
                ),
                decoration: BoxDecoration(
                  color: selected ? c.accentWash : Colors.transparent,
                  borderRadius: BorderRadius.circular(R.sm),
                ),
                child: icon,
              ),
              if (vertical) ...[
                const SizedBox(height: 3),
                Text(
                  item.label,
                  style: n1Text(
                    size: 10.5,
                    height: 1.2,
                    color: color,
                  ).n1W(selected ? 600 : 500),
                ),
                const SizedBox(height: S.x1),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
