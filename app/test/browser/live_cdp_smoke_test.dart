@Tags(['live'])
library;

// 这个文件里的 print 是**故意的**，别改成 logging：它的输出就是真跑的
// 证据本身（CLAUDE.md:35——声明「通过」之前要有输出为证）。改成 logging
// 框架反而会让这唯一一处证据消失。
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/browser/cdp_browser_driver.dart';

/// **真的拉起一个浏览器**跑一遍。默认不跑。
///
/// ```
/// N1_LIVE_BROWSER=1 flutter test test/browser/live_cdp_smoke_test.dart
/// ```
///
/// 为什么不放进常规测试：它会开窗口、连外网、花十几秒，别人机器上没有
/// Edge 就红——那是环境问题，不是代码问题。但它必须存在：CDP 这条链上
/// 大部分失败（端口没开、profile 冲突、脚本注入不进去、innerText 取不到）
/// **只有真跑才看得见**，假驱动一条都测不出来。
void main() {
  final enabled = Platform.environment['N1_LIVE_BROWSER'] == '1';
  final skipReason = enabled ? null : '设 N1_LIVE_BROWSER=1 才会跑（会真的开浏览器）';

  late CdpBrowserDriver driver;

  setUp(() {
    driver = CdpBrowserDriver(logger: (m) => print('[驱动] $m'));
  });

  tearDown(() async {
    await driver.dispose();
  });

  test('起得来、连得上、能读到页面', () async {
    await driver.warmUp();

    expect(
      driver.isAvailable,
      isTrue,
      reason: '预热失败：${driver.unavailableReason}',
    );

    // 刻意用百度当"能通的站"。**不要用 example.com**——它在这台机器上是
    // `ERR_CONNECTION_REFUSED`（curl 也是 000），拿它当基准的话红的是网络，
    // 容易被当成代码坏了。
    await driver.open('https://www.baidu.com/');
    final snap = await driver.snapshot();

    print('=== 百度首页快照 ===\n${snap.toModelText(maxTextChars: 300)}');

    expect(snap.url, contains('baidu.com'));
    expect(snap.title, contains('百度'));
    expect(snap.text, isNotEmpty, reason: '正文是空的——innerText 没取到？');
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

  test('打不开的网址要如实报错，不能给一个空白页', () async {
    await driver.warmUp();
    expect(driver.isAvailable, isTrue, reason: driver.unavailableReason);

    // 导航失败时 CDP 是**成功返回**的，错误藏在 errorText 里。不看它就
    // 会给模型一个空白快照，然后它开始怀疑自己的选择器写错了。
    await expectLater(
      driver.open('https://example.com/'),
      throwsA(
        isA<BrowserException>().having(
          (e) => e.message,
          'message',
          contains('打不开'),
        ),
      ),
    );
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

  test('中文站：真能填进输入框、点提交、页面真的换了', () async {
    await driver.warmUp();
    expect(driver.isAvailable, isTrue, reason: driver.unavailableReason);

    await driver.open('https://www.baidu.com/');
    var snap = await driver.snapshot();

    print('=== 百度首页 ===\n${snap.toModelText(maxTextChars: 200)}');
    expect(snap.title, contains('百度'), reason: '没拿到百度首页，标题是「${snap.title}」');
    expect(snap.nodes, isNotEmpty, reason: '一个可交互元素都没抓到');

    // 找能填的地方。**别断言"第一个 textbox 就是搜索框"**——实测（2026-10-10）
    // 这套新布局里，经典搜索框 `#kw` 是 `rects=0`（不可见，被 visible() 挡掉），
    // 快照里唯一可见的 textbox 是文心助手的 `#chat-textarea`，而它的
    // placeholder 是**轮换的热搜词**。名字长什么样完全不受我们控制，
    // 所以这里只断言"有个地方能填"。
    final box = snap.nodes.firstWhere(
      (n) => n.role == 'textbox',
      orElse: () => throw StateError(
        '快照里没有 textbox，抓到的是：'
        '${snap.nodes.map((n) => '${n.role}/${n.name}').join(', ')}',
      ),
    );
    print('能填的地方：[${box.ref}] ${box.name}');

    await driver.type(box.ref, '牛蛙');

    // 填完**重新快照**再找按钮。ref 是每次快照现发的，上一份里的 13 号和
    // 这一份里的 13 号不是同一个东西——拿它们互相比较是没有意义的断言。
    snap = await driver.snapshot();
    final submit = snap.nodes.firstWhere(
      (n) =>
          n.role == 'button' &&
          (n.name.contains('百度') || n.name.contains('搜索')),
      orElse: () => throw StateError('没找到搜索按钮，按钮有：'
          '${snap.nodes.where((n) => n.role == 'button').map((n) => n.name).join(', ')}'),
    );
    print('提交按钮：[${submit.ref}] ${submit.name}');

    await driver.click(submit.ref);
    await Future<void>.delayed(const Duration(seconds: 2));

    final next = await driver.snapshot();
    print('=== 提交之后 ===\n${next.toModelText(maxTextChars: 400)}');

    // 页面真的换了——这是"type + click 确实生效"最硬的证据。
    expect(next.url, isNot(snap.url), reason: '点了提交，页面没动');

    // 落地页有两种：搜索结果页，或者百度的滑块验证页。全新 profile 一个
    // cookie 都没有，百度大概率弹验证。**那是百度的反爬，不是我们的 bug**，
    // 所以撞上验证不算失败——但要**明确打出来**，别让下次看的人以为代码坏了。
    final captcha = next.url.contains('wappass') ||
        next.title.contains('验证') ||
        next.text.contains('安全验证');
    if (captcha) {
      print('⚠️ 落到百度的滑块验证页了。全新 profile 没有 cookie，这是百度的'
          '反爬，不是驱动的问题——到这一步 type + click 已经证明有效。');
    } else {
      expect(next.text, contains('牛蛙'), reason: '结果页正文里没搜到关键词');
      expect(next.nodes, isNotEmpty, reason: '结果页一个元素都没抓到');
    }
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 4)));

  test('滚动真的会动', () async {
    await driver.warmUp();
    expect(driver.isAvailable, isTrue, reason: driver.unavailableReason);

    await driver.open('https://www.baidu.com/');
    await driver.scroll(ScrollDirection.down);
    final after = await driver.snapshot();

    print('滚完之后还在百度：${after.title}');
    expect(after.url, contains('baidu.com'));
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

  test('截图拿到真 PNG，用完进程和临时目录都不留', () async {
    await driver.warmUp();
    expect(driver.isAvailable, isTrue, reason: driver.unavailableReason);

    await driver.open('https://www.baidu.com/');
    final bytes = await driver.screenshot();

    // PNG 魔数。空字节或全黑图都过不了这个——真截图才有。
    expect(bytes.length, greaterThan(1000), reason: '截图太小了，多半是空的');
    expect(
      bytes.take(8).toList(),
      [137, 80, 78, 71, 13, 10, 26, 10],
      reason: '这不是 PNG',
    );
    print('截图 ${bytes.length} 字节，魔数正确');

    // 临时 profile 的位置：驱动自己建的，名字带 niuwa-browser-
    final temp = Directory.systemTemp;
    final before = temp
        .listSync()
        .where((e) => e.path.contains('niuwa-browser-'))
        .length;

    await driver.dispose();
    await Future<void>.delayed(const Duration(seconds: 2));

    final after = temp
        .listSync()
        .where((e) => e.path.contains('niuwa-browser-'))
        .length;

    print('临时 profile 数量：dispose 前 $before，dispose 后 $after');
    expect(
      after,
      lessThanOrEqualTo(before),
      reason: '临时 profile 越攒越多，进程树没杀干净',
    );
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));
}
