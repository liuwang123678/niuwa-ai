import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/browser/webview_browser_driver.dart';
import 'package:niuwa_ai/services/browser/webview_surface.dart';
import 'package:niuwa_ai/widgets/browser_host.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// [BrowserHost] 是安卓浏览器功能的**承重缝**：它不挂，驱动就永远算不可用，
/// 模型也就永远看不见 browser_* 工具——而症状只是"它说做不到"。
///
/// 这里能测的都是接线：挂载时有没有通知驱动、child 有没有被撑坏、平台不对时
/// 是不是透明。**测不到**的是"真机上挂上去之后 WebView 到底有没有布局"——
/// 那需要一块真屏幕，是留给真机验收的第一条。
void main() {
  testWidgets('挂上之后驱动才算可用；child 照常渲染', (tester) async {
    final driver = WebViewBrowserDriver(
      createSurface: () => _FakeSurface(),
      logger: (_) {},
    );

    await driver.warmUp();
    expect(driver.isAvailable, isFalse, reason: '还没挂上就不该算可用');

    await tester.pumpWidget(
      MaterialApp(home: BrowserHost(driver: driver, child: const Text('界面'))),
    );

    expect(find.text('界面'), findsOneWidget);
    expect(driver.isAvailable, isTrue);
  });

  testWidgets('卸载之后驱动回到不可用，不会再被当成能用', (tester) async {
    final driver = WebViewBrowserDriver(
      createSurface: () => _FakeSurface(),
      logger: (_) {},
    );
    await driver.warmUp();

    await tester.pumpWidget(
      MaterialApp(home: BrowserHost(driver: driver, child: const Text('界面'))),
    );
    expect(driver.isAvailable, isTrue);

    await tester.pumpWidget(const MaterialApp(home: Text('换掉了')));

    expect(driver.isAvailable, isFalse);
  });

  testWidgets('child 拿到的仍然是满屏的紧约束（Stack 没把布局搞坏）', (tester) async {
    // 这个组件是被塞进 MaterialApp.builder 的，包在导航器外面。包错了就会把
    // 整个 App 的尺寸语义改掉——而那种坏法不是崩溃，是"界面莫名其妙缩了"。
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserHost(
          driver: const UnavailableBrowserDriver('这个平台没有'),
          child: Container(key: const Key('body'), color: const Color(0xFF000000)),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const Key('body'))), const Size(800, 600));
  });

  testWidgets('不是 WebView 驱动时它是透明的，不会误报"挂上了"', (tester) async {
    // Windows 走 CDP：那边自己拉浏览器，不需要挂任何东西，也不该被这个组件
    // 影响。传一个别的驱动进来必须什么都不发生。
    final driver = _RecordingDriver();

    await tester.pumpWidget(
      MaterialApp(home: BrowserHost(driver: driver, child: const Text('界面'))),
    );

    expect(find.text('界面'), findsOneWidget);
    expect(driver.warmed, isFalse, reason: '不该替别人预热');
  });

  testWidgets('驱动建不起来时（真机上不会，单测里很常见）界面照常出', (tester) async {
    final driver = WebViewBrowserDriver(
      createSurface: () => throw StateError('WebViewPlatform.instance is null'),
      logger: (_) {},
    );

    await tester.pumpWidget(
      MaterialApp(home: BrowserHost(driver: driver, child: const Text('界面'))),
    );
    await tester.pump();

    expect(find.text('界面'), findsOneWidget);
    expect(driver.isAvailable, isFalse);
  });
}

class _FakeSurface implements WebViewSurface {
  @override
  String? lastLoadError;

  @override
  void clearLoadError() => lastLoadError = null;

  /// 单测里永远是 null（真 controller 造不出来），所以这块 WebView 不会被
  /// 渲染进树——这一组测的是**接线**，不是渲染。
  @override
  WebViewController? get controller => null;

  @override
  Future<void> prepare() async {}

  @override
  Future<void> navigate(String url) async {}

  @override
  Future<String> evaluate(String js) async => '';

  @override
  Future<void> historyBack() async {}
}

/// 一个"别的驱动"，用来验 [BrowserHost] 对它无动于衷。
class _RecordingDriver extends BrowserDriver {
  bool warmed = false;

  @override
  bool get isAvailable => true;

  @override
  Future<void> warmUp() async => warmed = true;

  @override
  Future<void> open(String url) async {}
  @override
  Future<BrowserSnapshot> snapshot() async =>
      const BrowserSnapshot(url: '', title: '', nodes: [], text: '');
  @override
  Future<void> click(String ref) async {}
  @override
  Future<void> type(String ref, String text) async {}
  @override
  Future<void> scroll(ScrollDirection direction, {double amount = 0.8}) async {}
  @override
  Future<Uint8List> screenshot() async => Uint8List(0);
  @override
  Future<void> back() async {}
  @override
  Future<void> dispose() async {}
}
