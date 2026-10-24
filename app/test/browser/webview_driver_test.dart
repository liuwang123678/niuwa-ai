import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/browser/webview_browser_driver.dart';
import 'package:niuwa_ai/services/browser/webview_surface.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 这一组盯的是**安卓那半边的驱动**。
///
/// 它跑在一层假的 [WebViewSurface] 上，因为真的 `WebViewController` 要平台实现
/// （插件在 MainActivity 里注册），单测里造不出来。假的换掉的只是"跟真 WebView
/// 说话"这一层——驱动自己那套状态机、超时、协议判定全是真的。
///
/// 真机上还剩两件事测不到，别把这里的绿当成"手机上能用"：
///   1. WebView 挂上去之后到底有没有布局（`window.innerHeight > 0`）；
///   2. `runJavaScriptReturningResult` 回传的字符串到底长什么样。
/// 第 2 条的三种形态都在这组里覆盖了（见 [FakeSurface.readyState]），但那是
/// 按源码推断出来的，不是实测出来的。
void main() {
  group('预热与挂载', () {
    test('预热前不可用', () {
      final driver = WebViewBrowserDriver(
        createSurface: () => FakeSurface(),
        logger: (_) {},
      );

      expect(driver.isAvailable, isFalse);
      expect(driver.unavailableReason, isNotNull);
    });

    test('预热好了、但视图还没挂上：仍然是不可用，而且原因是"没挂上"', () async {
      // 这条是**故意要它不可用**。没挂上时脚本能跑、但读回来是空的
      // （没有布局 → getClientRects 全空）。那种"能跑但读到空"比不能用更坏：
      // 模型会拿着空快照反复换选择器重试，烧光回合数。
      final driver = WebViewBrowserDriver(
        createSurface: () => FakeSurface(),
        logger: (_) {},
      );

      await driver.warmUp();

      expect(driver.isAvailable, isFalse);
      expect(driver.unavailableReason, contains('视图'));
      await expectLater(driver.snapshot(), throwsA(isA<BrowserException>()));
    });

    test('挂上之后才可用', () async {
      final driver = WebViewBrowserDriver(
        createSurface: () => FakeSurface(),
        logger: (_) {},
      );

      await driver.warmUp();
      driver.markHostMounted();

      expect(driver.isAvailable, isTrue);
      expect(driver.unavailableReason, isNull);
    });

    test('卸载之后又变回不可用', () async {
      final driver = WebViewBrowserDriver(
        createSurface: () => FakeSurface(),
        logger: (_) {},
      );
      await driver.warmUp();
      driver.markHostMounted();
      driver.markHostUnmounted();

      expect(driver.isAvailable, isFalse);
    });

    test('是幂等的：预热三次只建一个 WebView', () async {
      var created = 0;
      final driver = WebViewBrowserDriver(
        createSurface: () {
          created++;
          return FakeSurface();
        },
        logger: (_) {},
      );

      await Future.wait([driver.warmUp(), driver.warmUp(), driver.warmUp()]);

      expect(created, 1, reason: '重复预热拉起第二个 WebView 会一直漏');
    });

    test('预热失败不抛——boot 阶段是 unawaited 调的，抛出去就是未捕获异步错误', () async {
      final driver = WebViewBrowserDriver(
        createSurface: () => FakeSurface(failPrepare: true),
        logger: (_) {},
      );

      await driver.warmUp(); // 不 expectLater(throwsA) ——它就该不抛

      expect(driver.isAvailable, isFalse);
      expect(driver.unavailableReason, contains('起不来'));
    });

    test('建 WebView 本身就抛（单测环境的正常退化）也不崩', () async {
      final driver = WebViewBrowserDriver(
        createSurface: () => throw StateError('WebViewPlatform.instance is null'),
        logger: (_) {},
      );

      await driver.warmUp();

      expect(driver.isAvailable, isFalse);
      expect(driver.unavailableReason, contains('起不来'));
    });
  });

  group('open', () {
    late FakeSurface surface;
    late WebViewBrowserDriver driver;

    setUp(() async {
      surface = FakeSurface();
      driver = WebViewBrowserDriver(
        createSurface: () => surface,
        settleDelay: Duration.zero,
        loadTimeout: const Duration(seconds: 2),
        logger: (_) {},
      );
      await driver.warmUp();
      driver.markHostMounted();
    });

    test('真的导航过去了', () async {
      await driver.open('https://example.com/a');
      expect(surface.navigated, ['https://example.com/a']);
    });

    test('🩸 readyState 带引号也认得出 complete', () async {
      // 这是整组里最值钱的一条。安卓把 JS 字符串按 JSON 编码回传，`complete`
      // 到手是 `"complete"`（带引号）。不剥引号的话这个比较**永远为假**，
      // 循环一直转到超时——而症状是"页面好像永远加载不完"，页面其实早好了。
      surface.readyState = '"complete"';
      final started = DateTime.now();

      await driver.open('https://example.com/a');

      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason: '等满了超时说明没认出带引号的 complete',
      );
    });

    test('页面加载失败：抛的是翻译过的人话，不是 net::ERR_ 原文', () async {
      surface.failNavigateWith =
          '打不开这个页面：连不上（net::ERR_NAME_NOT_RESOLVED）。'
          '先确认手机有网，或者这个域名是不是拼错了。';

      await expectLater(
        driver.open('https://nope.invalid/'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('连不上'),
          ),
        ),
      );
    });

    test('加载失败时**立刻**返回，不干等满超时', () async {
      // 失败的导航照样会把 readyState 走成 complete（浏览器渲染的是它自己的
      // 错误页），所以只看 readyState 看不出失败。不看 lastLoadError 的话，
      // 一个打不开的域名要让用户等满整个超时。
      surface.readyState = 'loading';
      surface.failNavigateWith = '打不开这个页面：连不上。';
      final started = DateTime.now();

      await expectLater(
        driver.open('https://nope.invalid/'),
        throwsA(isA<BrowserException>()),
      );

      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason: '_waitForLoad 没提前退出',
      );
    });

    test('每次导航前先清掉上一次的错误', () async {
      // 直接塞一个"上一次留下的错"。导航本身不报错，所以它只可能被
      // open() 开头那次 clear 清掉——清了才不会一直粘着。
      surface.lastLoadError = '上一页的错';
      surface.readyState = 'complete';

      await driver.open('https://example.com/a');

      expect(surface.clearCount, 1);
    });

    test('不是一个网址就当场说清楚，不去导航', () async {
      await expectLater(
        driver.open('牛蛙'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('http'),
          ),
        ),
      );
      expect(surface.navigated, isEmpty);
    });

    test('一直没加载完也只是继续往下走，不抛', () async {
      // 重 SPA 的 readyState 可能长时间停在 interactive，但页面已经能读了。
      // 在这里抛的话，模型会以为这个站打不开而放弃——比读到半成品更糟。
      surface.readyState = 'loading';
      driver = WebViewBrowserDriver(
        createSurface: () => surface,
        settleDelay: Duration.zero,
        loadTimeout: const Duration(milliseconds: 250),
        logger: (_) {},
      );
      await driver.warmUp();
      driver.markHostMounted();

      await driver.open('https://example.com/a');

      expect(surface.navigated, hasLength(1));
    });
  });

  group('页面操作', () {
    late FakeSurface surface;
    late WebViewBrowserDriver driver;

    setUp(() async {
      surface = FakeSurface();
      driver = WebViewBrowserDriver(
        createSurface: () => surface,
        settleDelay: Duration.zero,
        logger: (_) {},
      );
      await driver.warmUp();
      driver.markHostMounted();
    });

    test('snapshot 解析出节点', () async {
      surface.responses[browserSnapshotJs] = jsonEncode({
        'url': 'https://example.com/',
        'title': '例子',
        'nodes': [
          {'ref': '1', 'role': 'link', 'name': '首页'},
        ],
        'text': '正文',
      });

      final snap = await driver.snapshot();

      expect(snap.title, '例子');
      expect(snap.nodes.single.name, '首页');
    });

    test('click 把编号拼进脚本', () async {
      surface.responses['el.click()'] ='{"status":"ok"}';

      await driver.click('3');

      expect(surface.scripts.last, browserClickJs(3));
    });

    test('编号不是数字：当场拦下，**不把模型的输出拼进 JS 去跑**', () async {
      final before = surface.scripts.length;

      await expectLater(
        driver.click('1); alert(1);//'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('不是一个编号'),
          ),
        ),
      );

      expect(surface.scripts, hasLength(before));
    });

    test('编号过期：翻成"重新快照一次"', () async {
      surface.responses['el.click()'] ='{"status":"stale"}';

      await expectLater(
        driver.click('3'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('重新 browser_snapshot'),
          ),
        ),
      );
    });

    test('页面上报的错原样带出来', () async {
      surface.responses['el.click()'] ='{"status":"error","message":"按钮被挡住了"}';

      await expectLater(
        driver.click('3'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('按钮被挡住了'),
          ),
        ),
      );
    });

    test('返回看不懂的东西时不假装成功', () async {
      surface.responses['el.click()'] ='这不是 JSON';

      await expectLater(driver.click('3'), throwsA(isA<BrowserException>()));
    });

    test('type 把文字转义着塞进脚本', () async {
      surface.responses["Event('input'"] ='{"status":"ok"}';

      await driver.type('2', r'他说"你好"');

      expect(surface.scripts.last, browserTypeJs(2, r'他说"你好"'));
      expect(surface.scripts.last, contains(r'\"你好\"'));
    });

    test('scroll 四个方向都发得出去', () async {
      surface.responses['scrollBy'] ='{"status":"ok"}';

      for (final d in ScrollDirection.values) {
        await driver.scroll(d, amount: 0.5);
        expect(surface.scripts.last, browserScrollJs(d, 0.5));
      }
    });

    test('back 真的往回退', () async {
      await driver.back();
      expect(surface.backCount, 1);
    });
  });

  group('screenshot 如实失败', () {
    test('抛，而且**不说谎**', () async {
      // 这个平台没有截图接口。返回空字节的话，工具层现成的文案会写成
      // "页面可能还没加载出来"——那是撒谎：页面好得很，是这儿截不了。
      // 模型照着那句会去重新 open、重新等，白烧几轮。
      final surface = FakeSurface();
      final driver = WebViewBrowserDriver(
        createSurface: () => surface,
        settleDelay: Duration.zero,
        logger: (_) {},
      );
      await driver.warmUp();
      driver.markHostMounted();

      await expectLater(
        driver.screenshot(),
        throwsA(
          isA<BrowserException>()
              .having((e) => e.message, 'message', contains('截不了'))
              .having(
                (e) => e.message,
                'message',
                isNot(contains('还没加载')),
              ),
        ),
      );
    });
  });

  group('dispose', () {
    test('之后所有操作立刻报错，不 hang', () async {
      final surface = FakeSurface();
      final driver = WebViewBrowserDriver(
        createSurface: () => surface,
        settleDelay: Duration.zero,
        logger: (_) {},
      );
      await driver.warmUp();
      driver.markHostMounted();
      await driver.dispose();

      expect(driver.isAvailable, isFalse);
      await expectLater(driver.open('https://a.com'), throwsA(isA<BrowserException>()));
      await expectLater(driver.snapshot(), throwsA(isA<BrowserException>()));
      await expectLater(driver.click('1'), throwsA(isA<BrowserException>()));
      await expectLater(driver.scroll(ScrollDirection.down), throwsA(isA<BrowserException>()));
    });

    test('重复 dispose 不炸', () async {
      final driver = WebViewBrowserDriver(
        createSurface: () => FakeSurface(),
        logger: (_) {},
      );
      await driver.warmUp();
      await driver.dispose();
      await driver.dispose();
    });
  });

  group('describeLoadError', () {
    // errorCode 是必填的（老接口留的），我们只认 description——真机上也是
    // 那句话在起作用，各机型给的错码并不统一。
    WebResourceError err(String description, {bool? mainFrame = true}) =>
        WebResourceError(
          errorCode: -2,
          isForMainFrame: mainFrame,
          description: description,
          errorType: WebResourceErrorType.unknown,
        );

    test('明文被拦时告诉它换 https 或改用 http_fetch，不是甩一个 net::ERR_', () {
      final msg = describeLoadError(err('net::ERR_CLEARTEXT_NOT_PERMITTED'));

      expect(msg, contains('http_fetch'));
      expect(msg, contains('https'));
    });

    test('连不上时说人话，并原样保留系统给的错码', () {
      final msg = describeLoadError(err('net::ERR_NAME_NOT_RESOLVED'));

      expect(msg, contains('有网'));
      expect(msg, contains('ERR_NAME_NOT_RESOLVED'), reason: '排障时要用到原文');
    });

    test('其余错误也包一层，不至于只剩一个错码', () {
      expect(describeLoadError(err('net::ERR_FAILED')), contains('打不开这个页面'));
    });
  });
}

/// 假的 WebView 表面。
///
/// 只假装"跟真 WebView 说话"这一层。驱动真正要考的那些（协议判定、超时、
/// 状态翻转）在这上面都是真跑的。
class FakeSurface implements WebViewSurface {
  FakeSurface({this.failPrepare = false});

  /// 预热就炸，模拟"这个平台上根本没有 WebView"。
  final bool failPrepare;

  /// `document.readyState` 的返回值。
  ///
  /// 默认带引号，**按安卓那条路的样子来**：`runJavaScriptReturningResult`
  /// 把 JS 字符串按 JSON 编码回传，所以 `complete` 到手是 `"complete"`。
  String readyState = '"complete"';

  /// 按脚本内容片段匹配的返回值。
  final Map<String, String> responses = {};

  final List<String> navigated = [];
  final List<String> scripts = [];
  int backCount = 0;
  int clearCount = 0;

  @override
  String? lastLoadError;

  @override
  void clearLoadError() {
    clearCount++;
    lastLoadError = null;
  }

  @override
  WebViewController? get controller => null;

  @override
  Future<void> prepare() async {
    if (failPrepare) throw StateError('这个平台上没有 WebView');
  }

  /// 导航时**由平台回调**报出来的错。
  ///
  /// 必须在 navigate 里设置，不能事先塞进 [lastLoadError]——真机上那个错是
  /// 加载过程中通过 delegate 来的，而 `open()` 在导航**之前**会先清一次
  /// （不清的话上一次的错会一直粘着）。事先塞的会被那个 clear 抹掉。
  String? failNavigateWith;

  @override
  Future<void> navigate(String url) async {
    navigated.add(url);
    if (failNavigateWith != null) lastLoadError = failNavigateWith;
  }

  @override
  Future<void> historyBack() async => backCount++;

  @override
  Future<String> evaluate(String js) async {
    scripts.add(js);
    if (js == browserReadyStateJs) return readyState;

    for (final entry in responses.entries) {
      if (js.contains(entry.key)) return entry.value;
    }
    return '';
  }
}
