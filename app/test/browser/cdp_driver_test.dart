import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/browser/browser_driver_factory.dart';
import 'package:niuwa_ai/services/browser/cdp_browser_driver.dart';
import 'package:niuwa_ai/services/browser/webview_browser_driver.dart';

void main() {
  // 这一组盯的是 CDP 那一层最容易出错、又最难在真跑里看出来的地方：
  // 回复怎么路由、断线会不会 hang、启动参数对不对。

  group('CdpConnection', () {
    late StreamController<dynamic> incoming;
    late StreamController<dynamic> outgoing;
    late List<Object?> sent;
    late CdpConnection cdp;
    late List<String> closedReasons;

    setUp(() {
      // sync: true —— 让 add 立刻投递，测试里不用到处 await 一个零延迟
      // 去等"命令写出去了没"，少一层时序不确定性。
      incoming = StreamController<dynamic>(sync: true);
      outgoing = StreamController<dynamic>(sync: true);
      sent = [];
      closedReasons = [];
      outgoing.stream.listen(sent.add);
      cdp = CdpConnection(
        incoming: incoming.stream,
        outgoing: outgoing.sink,
        commandTimeout: const Duration(milliseconds: 150),
        onClosed: closedReasons.add,
      );
      cdp.start();
    });

    tearDown(() async {
      await cdp.close();
      await incoming.close();
      await outgoing.close();
    });

    Map<String, Object?> lastCommand() =>
        (jsonDecode('${sent.last}') as Map).cast<String, Object?>();

    void reply(Object body) => incoming.add(jsonEncode(body));

    test('发出去的是带 id 和 method 的 JSON 命令', () async {
      final future = cdp.send('Page.enable');
      final cmd = lastCommand();

      expect(cmd['method'], 'Page.enable');
      expect(cmd['id'], isA<int>());
      expect(cmd.containsKey('params'), isFalse); // 没参数就别带个 null 过去

      // 收个尾：不接住的话，tearDown 关连接时那个未处理的错误会被
      // 报成 unhandled async error，测试红得莫名其妙。
      reply({'id': cmd['id'], 'result': <String, Object?>{}});
      await future;
    });

    test('带参数时原样放进 params', () async {
      final future = cdp.send('Page.navigate', {'url': 'https://a.com'});
      final cmd = lastCommand();

      expect(cmd['params'], {'url': 'https://a.com'});

      reply({'id': cmd['id'], 'result': <String, Object?>{}});
      await future;
    });

    test('按 id 对上回复，result 交给调用方', () async {
      final future = cdp.send('Page.enable');
      final id = lastCommand()['id'];

      reply({'id': id, 'result': {'frameId': 'X'}});

      expect(await future, {'frameId': 'X'});
    });

    test('多条命令同时在飞时各回各的，不会串', () async {
      final a = cdp.send('A');
      final idA = lastCommand()['id'];
      final b = cdp.send('B');
      final idB = lastCommand()['id'];

      // 故意**倒序**回。按到达顺序取 Completer 的实现会在这儿错位。
      reply({'id': idB, 'result': {'who': 'B'}});
      reply({'id': idA, 'result': {'who': 'A'}});

      expect(await a, {'who': 'A'});
      expect(await b, {'who': 'B'});
    });

    test('error 回复翻成人话的异常', () async {
      final future = cdp.send('Nope');
      reply({
        'id': lastCommand()['id'],
        'error': {'code': -32601, 'message': 'method not found'},
      });

      await expectLater(
        future,
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('method not found'),
          ),
        ),
      );
    });

    test('没有 id 的事件被忽略，不影响正在等的那条命令', () async {
      final future = cdp.send('Page.enable');

      // 事件帧：CDP 会在命令回复前后夹一堆这种。
      reply({'method': 'Page.loadEventFired', 'params': {'timestamp': 1}});
      reply({'method': 'Runtime.consoleAPICalled', 'params': {}});

      reply({'id': lastCommand()['id'], 'result': {'ok': true}});

      expect(await future, {'ok': true});
    });

    test('不是 JSON 的帧直接丢掉，不炸', () async {
      final future = cdp.send('Page.enable');
      incoming.add('居然不是 JSON');
      incoming.add([1, 2, 3]);
      reply({'id': lastCommand()['id'], 'result': {'ok': true}});

      expect(await future, {'ok': true});
    });

    test('二进制帧按 UTF-8 解出来照样认', () async {
      final future = cdp.send('Page.enable');
      final id = lastCommand()['id'];
      incoming.add(utf8.encode(jsonEncode({'id': id, 'result': {'ok': 1}})));

      expect(await future, {'ok': 1});
    });

    test('迟迟不回话就超时，而不是无限等', () async {
      // 用户手动关掉浏览器时，某些实现下命令既不回也不报错，就那么挂着。
      // 没有这个超时，整轮对话就卡死在这儿了。
      await expectLater(
        cdp.send('Page.enable'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('没回话'),
          ),
        ),
      );
    });

    test('连接断了：等在飞的命令立刻失败，不是干等超时', () async {
      final future = cdp.send('Page.enable');

      // **断言要先挂上，再去断线。** 倒过来的话，断线发生在我们 await 的那
      // 一瞬间，错误已经投出去了而没人接——Dart 会把它报成未处理错误，
      // 红的是这一条但根因根本不是断言不成立。
      final expectation = expectLater(
        future,
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('关掉'),
          ),
        ),
      );

      await incoming.close();
      await expectation;

      expect(closedReasons, hasLength(1));
    });

    test('断开之后再发命令立刻报错，不会挂住', () async {
      await incoming.close();
      await Future<void>.delayed(Duration.zero);

      expect(() => cdp.send('Page.enable'), throwsA(isA<BrowserException>()));
    });

    test('onClosed 只报一次，连续断开不会重复通知', () async {
      await incoming.close();
      await Future<void>.delayed(Duration.zero);
      expect(closedReasons, hasLength(1));
    });

    group('evaluate', () {
      test('拿回 result.value', () async {
        final future = cdp.evaluate('document.title');
        final cmd = lastCommand();

        expect(cmd['method'], 'Runtime.evaluate');
        expect((cmd['params']! as Map)['returnByValue'], isTrue);

        reply({
          'id': cmd['id'],
          'result': {
            'result': {'type': 'string', 'value': '百度一下'},
          },
        });

        expect(await future, '百度一下');
      });

      test('页面脚本报错时翻成人话，不是把 CDP 的原始结构甩给模型', () async {
        final future = cdp.evaluate('boom()');
        reply({
          'id': lastCommand()['id'],
          'result': {
            'exceptionDetails': {'text': 'Uncaught ReferenceError: boom'},
          },
        });

        await expectLater(
          future,
          throwsA(
            isA<BrowserException>().having(
              (e) => e.message,
              'message',
              contains('ReferenceError'),
            ),
          ),
        );
      });

      test('null 值不会变成字符串 "null"', () async {
        final future = cdp.evaluate('null');
        reply({
          'id': lastCommand()['id'],
          'result': {
            'result': {'type': 'object', 'subtype': 'null', 'value': null},
          },
        });

        expect(await future, isNull);
      });
    });
  });

  group('驱动工厂', () {
    test('Windows 给 CDP 驱动', () {
      final driver = createBrowserDriver(platform: TargetPlatform.windows);
      expect(driver, isA<CdpBrowserDriver>());
    });

    test('安卓给 WebView 驱动，但**没预热、没挂载之前一律算不可用**', () {
      // 这条守的是"工具不该出现在模型眼前"。给一个 isAvailable=true 却调不通
      // 的驱动，模型会反复重试同一个工具，烧光回合数。
      //
      // 这里刻意**不调 warmUp**：安卓的驱动要多一个条件才能算好——视图得先被
      // BrowserHost 挂进 widget 树，否则页面没有布局，快照读到零个元素。
      // 见 WebViewBrowserDriver 和 BrowserHost 的说明。
      final driver = createBrowserDriver(platform: TargetPlatform.android);

      expect(driver, isA<WebViewBrowserDriver>());
      expect(driver.isAvailable, isFalse);
      expect(driver.unavailableReason, isNotNull);
    });

    test('mac / linux 如实说还没做，不假装能跑', () {
      for (final p in [TargetPlatform.macOS, TargetPlatform.linux]) {
        final driver = createBrowserDriver(platform: p);
        expect(driver.isAvailable, isFalse, reason: '$p');
        expect(driver.unavailableReason, contains('Windows'), reason: '$p');
      }
    });

    test('注入的驱动优先——测试靠这条不用真起浏览器', () {
      final fake = FakeDriver();
      expect(
        createBrowserDriver(platform: TargetPlatform.android, androidDriver: fake),
        same(fake),
      );
      expect(
        createBrowserDriver(platform: TargetPlatform.windows, windowsDriver: fake),
        same(fake),
      );
    });
  });

  group('挑 page target', () {
    List<Map<String, Object?>> pages(List<String> urls) => [
      for (var i = 0; i < urls.length; i++)
        {
          'type': 'page',
          'url': urls[i],
          'webSocketDebuggerUrl': 'ws://x/$i',
        },
    ];

    // 这一组来自真机实测：全新 profile 下 /json/list 里，Edge 自带的同步
    // 对话框排在**我们页面前面**。取"第一个 page"就会连错目标，症状只是
    // "读不到东西"，很难往这上面想。

    test('跳过 edge:// 自带页面，挑我们启动时那个 about:blank', () {
      final ws = pickPageTarget(
        pages(['edge://sync-confirmation-dialog/', 'about:blank']),
      );
      expect(ws, 'ws://x/1');
    });

    test('已经导航走了，就挑 http 页面，不是那个对话框', () {
      final ws = pickPageTarget(
        pages(['edge://sync-confirmation-dialog/', 'https://www.baidu.com/']),
      );
      expect(ws, 'ws://x/1');
    });

    test('非 page 的 target 一律不算（扩展后台页、service worker）', () {
      final ws = pickPageTarget([
        {
          'type': 'background_page',
          'url': 'chrome-extension://a/b.html',
          'webSocketDebuggerUrl': 'ws://bg',
        },
        {
          'type': 'service_worker',
          'url': 'chrome-extension://a/sw.js',
          'webSocketDebuggerUrl': 'ws://sw',
        },
        {'type': 'page', 'url': 'about:blank', 'webSocketDebuggerUrl': 'ws://p'},
      ]);
      expect(ws, 'ws://p');
    });

    test('没有调试地址的跳过', () {
      final ws = pickPageTarget([
        {'type': 'page', 'url': 'about:blank'},
        {'type': 'page', 'url': 'https://a.com/', 'webSocketDebuggerUrl': 'ws://a'},
      ]);
      expect(ws, 'ws://a');
    });

    test('实在只剩自带页面也认——有页面总比没有强', () {
      expect(pickPageTarget(pages(['edge://newtab/'])), 'ws://x/0');
    });

    test('一个 page 都没有就返回 null，让调用方去报错', () {
      expect(pickPageTarget(<Object?>[]), isNull);
      expect(pickPageTarget({'不是': '列表'}), isNull);
    });
  });

  group('CdpBrowserDriver 预热', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('n1-browser-test');
    });

    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('没找到浏览器时：不可用、说清原因、**不抛异常**', () async {
      final driver = CdpBrowserDriver(
        findExecutable: () async => null,
        tempDirectory: () async => tempRoot,
      );

      // boot 阶段是 unawaited 调的，抛出来就是 unhandled async error，打崩 zone。
      await driver.warmUp();

      expect(driver.isAvailable, isFalse);
      expect(driver.unavailableReason, contains('没找到'));
    });

    test('预热失败时也不抛——抛出会打崩 zone', () async {
      final driver = CdpBrowserDriver(
        findExecutable: () async => r'C:\fake\msedge.exe',
        startProcess: (_, _) async => throw const ProcessException('boom', []),
        tempDirectory: () async => tempRoot,
      );

      await driver.warmUp();

      expect(driver.isAvailable, isFalse);
      expect(driver.unavailableReason, contains('起不来'));
    });

    test('预热是幂等的——重复调用不会去找第二遍、起第二个浏览器', () async {
      var findCount = 0;
      final driver = CdpBrowserDriver(
        findExecutable: () async {
          findCount++;
          return null;
        },
        tempDirectory: () async => tempRoot,
      );

      await Future.wait([driver.warmUp(), driver.warmUp(), driver.warmUp()]);

      expect(findCount, 1);
    });

    test('启动参数里必须有独立 user-data-dir 和自动端口', () async {
      // 这两条是"必翻"清单上的头两条：
      //  - 没有独立 profile：已在跑的 Edge 会接手参数然后自己退出，端口永不打开；
      //  - 端口写死：撞上占用就整个起不来，而且报错看不懂。
      List<String>? captured;
      final driver = CdpBrowserDriver(
        findExecutable: () async => r'C:\fake\msedge.exe',
        startProcess: (_, args) async {
          captured = args;
          throw const ProcessException('先不走后面', []);
        },
        tempDirectory: () async => tempRoot,
        startTimeout: const Duration(milliseconds: 200),
      );

      await driver.warmUp();

      expect(captured, isNotNull);
      expect(
        captured!.any((a) => a.startsWith('--user-data-dir=')),
        isTrue,
        reason: '缺了它，调试端口永远不会打开',
      );
      expect(captured, contains('--remote-debugging-port=0'));
      // 不能是 headless：这是个陪伴型 App，用户要看得见它在干活。
      expect(captured!.any((a) => a.startsWith('--headless')), isFalse);
    });

    test('用完 dispose 之后 isAvailable 立刻是 false', () async {
      final driver = CdpBrowserDriver(
        findExecutable: () async => null,
        tempDirectory: () async => tempRoot,
      );
      await driver.warmUp();
      await driver.dispose();

      expect(driver.isAvailable, isFalse);

      final again = CdpBrowserDriver(
        findExecutable: () async => null,
        tempDirectory: () async => tempRoot,
      );
      await again.warmUp();
      await again.dispose();
      // dispose 之后再操作必须立刻报错，不能挂住
      await expectLater(
        again.snapshot(),
        throwsA(isA<BrowserException>()),
      );
    });

    test('没热好就操作：立刻报错，不是 hang', () async {
      final driver = CdpBrowserDriver(
        findExecutable: () async => null,
        tempDirectory: () async => tempRoot,
      );
      await driver.warmUp();

      await expectLater(driver.open('https://a.com'), throwsA(isA<BrowserException>()));
      await expectLater(driver.snapshot(), throwsA(isA<BrowserException>()));
      await expectLater(driver.click('1'), throwsA(isA<BrowserException>()));
    });
  });
}

/// 只为验"注入优先"的假驱动。
class FakeDriver extends BrowserDriver {
  @override
  bool get isAvailable => true;
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
