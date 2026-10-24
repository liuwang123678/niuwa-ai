import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/shell/app_shell.dart';
import 'package:niuwa_ai/widgets/n1_mark.dart';
import 'package:niuwa_ai/widgets/splash_gate.dart';

/// 闪屏这道门守的是三件事，每件出事都很难看：
/// 1. 内核没装好就把界面放出来 → 用户看见界面，发一句话就炸。
/// 2. 内核起不来还一直演动画 → 白屏，用户以为 App 死了。
/// 3. 蛙飞错地方 → 落位瞬间"啪"地跳一下，比没有动画更难看。
void main() {
  Widget gate(
    Future<String> boot, {
    bool animation = false,
  }) => SplashGate<String>(
    boot: boot,
    animationEnabled: animation,
    builder: (v) => Center(child: Text('界面 $v')),
    errorBuilder: (e) => Center(child: Text('起不来：$e')),
  );

  group('顺序', () {
    testWidgets('内核没装好时只有牛蛙，界面不建树', (tester) async {
      final boot = Completer<String>();
      await tester.pumpWidget(gate(boot.future));

      expect(find.byType(N1Mark), findsOneWidget);
      expect(find.textContaining('界面'), findsNothing);

      boot.complete('好了');
      await tester.pump();
      await tester.pump();

      expect(find.text('界面 好了'), findsOneWidget);
    });

    testWidgets('内核起不来：摊开原因，不演动画也不白屏', (tester) async {
      final boot = Completer<String>();
      await tester.pumpWidget(gate(boot.future, animation: true));

      boot.completeError(StateError('数据库打不开'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('起不来'), findsOneWidget);
      expect(find.textContaining('数据库打不开'), findsOneWidget);
      expect(find.byType(N1Mark), findsNothing);
    });
  });

  group('时序', () {
    testWidgets('动画没走完，界面不出现', (tester) async {
      await tester.pumpWidget(gate(Future.value('好了'), animation: true));

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('界面 好了'), findsNothing);

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('界面 好了'), findsNothing);

      // 600ms 入场结束，飞行控制器要到下一帧才开始计时（Ticker 的起点是
      // 第一次 tick 的时间戳）。飞到三成 ≈ 起飞后 120ms 才把界面放出来。
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('界面 好了'), findsNothing, reason: '650ms：刚起飞，还不能放');

      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('界面 好了'), findsOneWidget);
    });

    testWidgets('飞完把闪屏整个撤掉，界面上不留第二只蛙', (tester) async {
      await tester.pumpWidget(gate(Future.value('好了'), animation: true));

      // 分两段 pump：入场结束时才启动飞行，一次 pump 到终点穿不过这个连锁。
      await tester.pump(SplashGate.intro + const Duration(milliseconds: 10));
      await tester.pump(SplashGate.fly + const Duration(milliseconds: 10));
      await tester.pump();

      expect(find.text('界面 好了'), findsOneWidget);
      expect(find.byType(N1Mark), findsNothing);
    });

    testWidgets('内核比动画慢：停在原地等，装好了再飞', (tester) async {
      final boot = Completer<String>();
      await tester.pumpWidget(gate(boot.future, animation: true));

      // 动画早就该走完了，但内核还没好——这时不能自作主张进界面。
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.byType(N1Mark), findsOneWidget);
      expect(find.textContaining('界面'), findsNothing);

      boot.complete('好了');
      await tester.pump();
      await tester.pump(SplashGate.fly + const Duration(milliseconds: 50));

      expect(find.text('界面 好了'), findsOneWidget);
    });
  });

  group('落点', () {
    testWidgets('宽屏时落在侧栏那只蛙身上', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(gate(Future.value('好了'), animation: true));
      await tester.pump(SplashGate.intro + const Duration(milliseconds: 10));

      // 飞行最后一帧：位置应该就是侧栏蛙的中心。
      await tester.pump(SplashGate.fly - const Duration(milliseconds: 5));
      final center = tester.getCenter(find.byType(N1Mark));

      expect(center.dx, closeTo(AppShell.railMarkCenter.dx, 0.5));
      expect(center.dy, closeTo(AppShell.railMarkCenter.dy, 0.5));

      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('窄屏没有侧栏可落，收向左上角', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(gate(Future.value('好了'), animation: true));
      await tester.pump(SplashGate.intro + const Duration(milliseconds: 10));
      await tester.pump(SplashGate.fly - const Duration(milliseconds: 5));

      final center = tester.getCenter(find.byType(N1Mark));
      expect(center.dx, lessThan(60));
      expect(center.dy, lessThan(60));

      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}
