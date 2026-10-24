import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_browser.dart';
import '../support/fake_llm.dart';

void main() {
  late FakeBrowserDriver driver;
  late ToolContext ctx;

  setUp(() {
    driver = FakeBrowserDriver(
      snapshots: [
        fakeSnapshot(
          title: '百度一下',
          url: 'https://www.baidu.com/',
          nodes: const [
            BrowserNode(ref: '1', role: 'textbox', name: '搜索框'),
            BrowserNode(ref: '2', role: 'button', name: '百度一下'),
          ],
        ),
      ],
    );
    ctx = testContext(browser: driver);
  });

  group('工具表', () {
    test('可用时注册 7 个，名字不重', () {
      final tools = browserTools(available: true);
      final names = tools.map((t) => t.name).toList();

      expect(names, hasLength(7));
      expect(names.toSet(), hasLength(7)); // 重名会让 ToolRegistry 覆盖掉一个
      expect(names, contains('browser_scroll'));
    });

    test('不可用时返回空表——不注册比注册了再报错好', () {
      expect(browserTools(available: false), isEmpty);
    });
  });

  group('冷启动', () {
    test('工具是冷的就现热，热完接着干活', () async {
      // 开机不预热之后，第一次上网一定走到这条路上。热不起来才是失败。
      driver = FakeBrowserDriver(
        available: false,
        canWarmUp: true,
        becomeAvailableOnWarmUp: true,
        unavailableReason: '还没启动',
      );
      ctx = testContext(browser: driver);

      final r = await const BrowserOpenTool().call({
        'url': 'https://www.baidu.com/',
      }, ctx);

      expect(driver.warmUpCount, 1);
      expect(r.ok, isTrue);
      expect(driver.opened, ['https://www.baidu.com/']);
    });

    test('预热之后还是不可用：如实说，不硬来', () async {
      driver = FakeBrowserDriver(
        available: false,
        canWarmUp: true,
        unavailableReason: '这台机器上没找到 Edge',
      );
      ctx = testContext(browser: driver);

      final r = await const BrowserOpenTool().call({
        'url': 'https://www.baidu.com/',
      }, ctx);

      expect(driver.warmUpCount, 1);
      expect(r.ok, isFalse);
      expect(r.content, contains('没找到 Edge'));
      expect(driver.opened, isEmpty);
    });
  });

  group('browser_open', () {
    test('打开成功后把页面内容交给模型', () async {
      final r = await const BrowserOpenTool().call({
        'url': 'https://www.baidu.com/',
      }, ctx);

      expect(r.ok, isTrue);
      expect(driver.opened, ['https://www.baidu.com/']);
      expect(r.content, contains('百度一下'));
      expect(r.content, contains('[1] textbox "搜索框"'));
      expect(r.meta, {'url': 'https://www.baidu.com/'});
    });

    test('没带协议的网址直接报参数错，不去碰驱动', () async {
      await expectLater(
        const BrowserOpenTool().call({'url': 'www.baidu.com'}, ctx),
        throwsA(isA<ToolInputException>()),
      );
      expect(driver.opened, isEmpty);
    });
  });

  group('browser_type', () {
    test('填完必须重拍快照——否则模型拿着填之前的编号表继续点', () async {
      driver = FakeBrowserDriver(
        // 队列里只放"填完之后"的那一页：这个流程里 snapshot 只被调一次，
        // 就是 type 之后那次。放两页反而测不出东西。
        snapshots: [fakeSnapshot(title: '填之后')],
      );
      ctx = testContext(browser: driver);

      final r = await const BrowserTypeTool().call({
        'ref': '1',
        'text': '牛蛙',
      }, ctx);

      expect(r.ok, isTrue);
      expect(driver.typed, [('1', '牛蛙')]);
      expect(driver.snapshotCount, 1);
      expect(r.content, contains('填之后'));
    });

    test('编号过期时说清是编号的事，让模型重拍一次', () async {
      driver = FakeBrowserDriver(staleRefs: {'9'});
      ctx = testContext(browser: driver);

      final r = await const BrowserTypeTool().call({'ref': '9', 'text': 'x'},
          ctx);

      expect(r.ok, isFalse);
      expect(r.content, contains('失效'));
      expect(r.content, isNot(contains('BrowserException')));
    });
  });

  group('browser_scroll', () {
    test('滚完带上新快照', () async {
      driver = FakeBrowserDriver(
        snapshots: [fakeSnapshot(title: '第二屏')],
      );
      ctx = testContext(browser: driver);

      final r = await const BrowserScrollTool().call({
        'direction': 'down',
      }, ctx);

      expect(r.ok, isTrue);
      expect(driver.scrolled, [ScrollDirection.down]);
      expect(r.content, contains('第二屏'));
    });

    test('不填方向默认往下滚', () async {
      await const BrowserScrollTool().call(<String, Object?>{}, ctx);
      expect(driver.scrolled, [ScrollDirection.down]);
    });

    test('四个方向都认', () async {
      for (final d in ScrollDirection.values) {
        await const BrowserScrollTool().call({'direction': d.name}, ctx);
      }
      expect(driver.scrolled, ScrollDirection.values);
    });

    test('方向写错就报参数错，不去碰驱动', () async {
      await expectLater(
        const BrowserScrollTool().call({'direction': 'next'}, ctx),
        throwsA(isA<ToolInputException>()),
      );
      expect(driver.scrolled, isEmpty);
    });
  });

  group('驱动的两种"用不了"必须分开', () {
    test('能力不存在时说清是能力问题，并指出替代手段', () async {
      ctx = testContext(
        browser: const UnavailableBrowserDriver('安卓这边还没做浏览器'),
      );

      final r = await const BrowserOpenTool().call({
        'url': 'https://a.com',
      }, ctx);

      expect(r.ok, isFalse);
      expect(r.content, contains('安卓这边还没做浏览器'));
      // 早先这里无论什么原因都写"当前平台不支持浏览器操作"——驱动自己
      // 说得更准时，就该用驱动的话。
    });

    test('驱动活着但页面出错时，说的是页面的事，不是平台的事', () async {
      driver = FakeBrowserDriver(
        failWith: const BrowserException('页面加载超时了。'),
      );
      ctx = testContext(browser: driver);

      final r = await const BrowserOpenTool().call({
        'url': 'https://a.com',
      }, ctx);

      expect(r.ok, isFalse);
      expect(r.content, '页面加载超时了。');
      expect(r.content, isNot(contains('平台不支持')));
    });

    test('驱动抛出的意外异常被换成看得懂的话，不是 WebSocketChannelException',
        () async {
      ctx = testContext(browser: _ThrowingDriver());

      final r = await const BrowserSnapshotTool().call(
        <String, Object?>{},
        ctx,
      );

      expect(r.ok, isFalse);
      expect(r.content, contains('浏览器操作失败'));
      expect(r.content, contains('socket closed'));
    });
  });

  group('browser_screenshot', () {
    test('截到图时把 base64 放进 meta 给界面显示', () async {
      final png = Uint8List.fromList([137, 80, 78, 71]);
      driver = FakeBrowserDriver(screenshotBytes: png);
      ctx = testContext(browser: driver);

      final r = await const BrowserScreenshotTool().call(
        <String, Object?>{},
        ctx,
      );

      expect(r.ok, isTrue);
      expect(r.meta!['image_base64'], base64Encode(png));
      expect(r.meta!['mime'], 'image/png');
    });

    test('空字节时说"没截到"，不猜成"页面还没加载出来"', () async {
      final r = await const BrowserScreenshotTool().call(
        <String, Object?>{},
        ctx,
      );

      expect(r.ok, isFalse);
      expect(r.content, isNot(contains('还没加载出来')));
    });
  });

  group('browser_back', () {
    test('退回来之后重拍快照', () async {
      final r = await const BrowserBackTool().call(<String, Object?>{}, ctx);
      expect(r.ok, isTrue);
      expect(driver.backCount, 1);
      expect(r.content, contains('百度一下'));
    });
  });

  group('快照渲染', () {
    test('note 会交给模型看——元素被截断时不说等于骗它', () {
      final text = fakeSnapshot(
        note: '（可交互元素太多，超过 300 个的部分没列出来）',
        nodes: const [BrowserNode(ref: '1', role: 'link', name: '首页')],
      ).toModelText();

      expect(text, contains('没列出来'));
      expect(text, contains('[1] link "首页"'));
      // 渲染顺序：页面 → 地址 → 注记 → 元素 → 正文
      expect(
        text.indexOf('地址：'),
        lessThan(text.indexOf('没列出来')),
      );
    });

    test('输入框的值要显示，模型靠它判断字到底填进去没有', () {
      final text = fakeSnapshot(
        nodes: const [
          BrowserNode(ref: '1', role: 'textbox', name: '搜索框', value: '牛蛙'),
        ],
      ).toModelText();

      expect(text, contains('(值: "牛蛙")'));
    });

    test('正文过长截断并说明', () {
      final text = fakeSnapshot(text: 'x' * 9000).toModelText(maxTextChars: 100);
      expect(text, contains('正文过长已截断'));
      expect(text.length, lessThan(500));
    });
  });
}

/// 专门抛一个驱动没预料到的异常，用来验 withDriver 的兜底。
class _ThrowingDriver extends FakeBrowserDriver {
  @override
  Future<BrowserSnapshot> snapshot() async =>
      throw StateError('socket closed');
}
