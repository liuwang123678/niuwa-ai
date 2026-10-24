import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/code/webview_js_runner.dart';

import '../browser/webview_driver_test.dart' show FakeSurface;

/// 安卓那条路：借 WebView 跑 JS。
///
/// 真 WebView 造不出来（`WebViewPlatform.instance` 要插件在 MainActivity 里
/// 注册），所以跟浏览器那边一样，拿一个假表面把"驱动真正要考的那些"
/// （状态翻转、超时之后重开、失败怎么说）跑成真的。
///
/// ⚠️ **这一层验不了"真机上行不行"**。最要紧的那条——不挂进 widget 树能不能
/// 求值——只有真机能回答，见 runner 类注释。这里验的是"错了怎么办"。
void main() {
  group('预热', () {
    test('建表面 → 开 JS → 导一次空白页', () async {
      // 🩸 空白页那一步不能省：刚建出来的 WebView 手上一份文档都没有，
      // 那时候求值没有可执行的环境，`evaluateJavascript` 只回一个 null。
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces);

      await runner.warmUp();

      expect(runner.isAvailable, isTrue);
      expect(surfaces, hasLength(1));
      expect(surfaces.single.prepared, isTrue);
      expect(surfaces.single.navigated, [jsBlankPage]);
    });

    test('起不来：如实说，而不是留一个"看着能用"的', () async {
      final runner = _runner([], failPrepare: true);

      await runner.warmUp();

      expect(runner.isAvailable, isFalse);
      expect(runner.unavailableReason, contains('起不来'));
      expect(runner.supportedLanguages, isEmpty);
    });

    test('幂等：热过了就不再建', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces);

      await runner.warmUp();
      await runner.warmUp();
      await runner.warmUp();

      expect(surfaces, hasLength(1));
    });

    test('同时来几个请求只建一个（预热里的 future 是要合并的）', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces);

      await Future.wait([runner.warmUp(), runner.warmUp(), runner.warmUp()]);

      expect(surfaces, hasLength(1));
    });

    test('🩸 求值回字面量 `null` 时**不算就绪**', () async {
      // `PlatformWebViewSurface.evaluate` 是 `'$result'`，所以 JS 回 null 的
      // 时候我们拿到的是**字符串 "null"**，不是空串。用 `isNotEmpty` 当判据的话
      // 头一次探测就"成功"了——而那时候根本还没有可执行的文档。
      final surfaces = <FakeJsSurface>[];
      final surface = FakeJsSurface(readyState: 'null');
      final runner = WebViewJsRunner(
        createSurface: () {
          surfaces.add(surface);
          return surface;
        },
        startupTimeout: const Duration(milliseconds: 150),
      );

      await runner.warmUp();

      // 等不到也不该判死：让第一次求值自己去失败，错误信息更具体。
      expect(surfaces.single.probes, greaterThan(1), reason: '应该一直在探');
      expect(runner.isAvailable, isTrue);
    });

    test('探到个"loading"也算数——我们要的是能求值，不是页面加载完', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces, readyState: '"loading"');

      await runner.warmUp();

      expect(surfaces.single.probes, 1, reason: '不该傻等 readyState 变 complete');
      expect(runner.isAvailable, isTrue);
    });

    test('手机上只有 JavaScript，而且没有命令行', () async {
      final runner = _runner([]);
      await runner.warmUp();

      expect(runner.supportedLanguages, {CodeLanguage.javascript});
      expect(runner.supportsCommand, isFalse);
      expect(runner.isAvailable, isTrue);
    });

    test('没预热之前一门语言都不报（schema 靠它，不能提前吹）', () {
      final runner = _runner([]);
      expect(runner.isAvailable, isFalse);
      expect(runner.supportedLanguages, isEmpty);
    });
  });

  group('跑起来', () {
    test('正常：退出码 0，返回值在输出里', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces, reply: _ok('42'));

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'return 42;',
        ),
      );

      expect(result.ok, isTrue);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('返回值：42'));
      expect(result.note, isNull, reason: '跑得好好的不用解释退出码');
    });

    test('发出去的确实是协议脚本，源码原样嵌在里面', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces, reply: _ok('1'));

      await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'return 1;',
        ),
      );

      final sent = surfaces.single.sentScripts.last;
      expect(sent, contains('new Function'));
      expect(sent, contains('return 1;'));
    });

    test('代码自己报错：退出码 1，错误进 stderr', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(
        surfaces,
        reply: _envelope(ok: false, error: 'TypeError: x is not a function'),
      );

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'return x();',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('TypeError'));
      // "退出码"这个词在 JS 这条路上本来就没有，得跟模型说一句，
      // 不然它会去找一个不存在的东西。
      expect(result.note, contains('退出码'));
      expect(result.toModelText(), contains('TypeError'), reason: '错要带给模型');
    });

    test('console 的日志进输出', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(
        surfaces,
        reply: _envelope(value: '0', logs: ['log: 你好']),
      );

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'console.log(1); return 0;',
        ),
      );

      expect(result.stdout, contains('log: 你好'));
    });

    test('日志被截过就如实标一下', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(
        surfaces,
        reply: _envelope(value: '0', logs: ['log: 1'], logsCut: true),
      );

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'x',
        ),
      );

      expect(result.stdout, contains('后面的没记'));
    });

    test('🩸 回包读不出来时**不假装成功**', () async {
      // 引擎崩了、或者被超时放弃之后慢吞吞回了个半截，都会到这儿。
      // 这里要是编一个"空结果"糊过去，模型会以为代码跑完了、没输出。
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces, reply: '这不是信封');

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'return 1;',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.exitCode, -1);
      expect(result.stderr, contains('没把结果带回来'));
      expect(result.stderr, contains('别原样重试'));
    });

    test('输出超长：截断并标注，而且不从半个 emoji 中间切', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = WebViewJsRunner(
        createSurface: () => _makeSurface(surfaces),
        maxOutputChars: 50,
      );
      await runner.warmUp();
      surfaces.single.reply = _envelope(value: '"${'👍' * 100}"');

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'return x;',
        ),
      );

      expect(result.truncated, isTrue);
      for (var i = 0; i < result.stdout.length; i++) {
        final u = result.stdout.codeUnitAt(i);
        if (u >= 0xD800 && u <= 0xDBFF) {
          expect(
            i + 1 < result.stdout.length &&
                result.stdout.codeUnitAt(i + 1) >= 0xDC00,
            isTrue,
            reason: '第 $i 位是个落单的高位代理',
          );
        }
      }
    });

    test('源码是空的直接拒，不白跑一趟', () async {
      await expectLater(
        _runner([]).run(
          const CodeRequest(
            language: CodeLanguage.javascript,
            source: '   ',
          ),
        ),
        throwsA(isA<CodeException>()),
      );
    });

    test('语言不是 JavaScript：说清楚只能跑什么', () async {
      await expectLater(
        _runner([]).run(
          const CodeRequest(language: CodeLanguage.python, source: 'print(1)'),
        ),
        throwsA(
          isA<CodeException>().having(
            (e) => e.message,
            'message',
            contains('JavaScript'),
          ),
        ),
      );
    });

    test('命令行：手机上没有，如实说', () async {
      await expectLater(
        _runner([]).runCommand(const CommandRequest(command: 'dir')),
        throwsA(isA<CodeException>()),
      );
    });

    test('没预热就直接跑：会自己先热一下（真跑里就是这个时序）', () async {
      // boot 是后台探的，用户打第一句话那会儿多半还没好；工具是**每一轮**
      // 按名字补登记的，所以真到跑的时候其实早就热了。但"热没热都要能跑"
      // 这件事得钉住——不然只会在真机上偶发失败。
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces, reply: _ok('1'));

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'return 1;',
        ),
      );

      expect(result.ok, isTrue);
      expect(surfaces.single.prepared, isTrue);
    });
  });

  group('卡死之后怎么办', () {
    // ⚠️ 这一组里的 `timeout: Duration.zero` **不是随手写的**，省掉它测试会挂。
    //
    // "没填超时"这个意思是用 `Duration.zero` 表达的（工具层那个
    // `_CodeTool.parseTimeout` 就是这么给的），执行器收到 0 才回落到自己的
    // `defaultTimeout`。而 `CodeRequest` **自己**的默认值是 60 秒——
    // 裸造一个 `CodeRequest` 不给 timeout，执行器拿到的是 60 秒，
    // 它自己的 `defaultTimeout` 连看都不会看一眼。
    // （真跑里不会撞上：工具那一层永远显式给一个值。）

    test('🩸 超时：如实报，并且把这个环境丢掉', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = WebViewJsRunner(
        createSurface: () => _makeSurface(surfaces),
        defaultTimeout: const Duration(milliseconds: 80),
      );
      await runner.warmUp();
      surfaces.single.gate = Completer<String>(); // 永远不返回，模拟 while(true)

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'while (true) {}',
          timeout: Duration.zero,
        ),
      );

      expect(result.timedOut, isTrue);
      expect(result.exitCode, -1);
      expect(result.stderr, contains('死循环'));
      expect(runner.isAvailable, isFalse);
      expect(runner.unavailableReason, contains('重开'));
      // 告诉模型别重试同一个。它拿着"超时"两个字最常见的反应就是原样再来一遍。
      expect(result.stderr, contains('别再写死循环'));
    });

    test('🩸 卡死之后下一个请求**真的重开一个**，而且能正常跑', () async {
      // 整条路的意义就在这一条：JS 死循环没法中断（WebView 没有中断接口），
      // 唯一的出路是把整个 WebView 换掉。换不掉的话，卡一次这个工具就废到
      // 重启 App 为止。
      final surfaces = <FakeJsSurface>[];
      final runner = WebViewJsRunner(
        // 回包写在工厂里，**不要事后补 `surfaces.last.reply = ...`**：
        // 那会儿 `last` 还是第一个（卡住的那个），第二个建出来是空回包，
        // 于是"重开之后能正常跑"这条看起来失败，其实是测试自己设错了对象。
        createSurface: () => _makeSurface(surfaces, reply: _ok('7')),
        defaultTimeout: const Duration(milliseconds: 80),
      );
      await runner.warmUp();
      surfaces.single.gate = Completer<String>();

      await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'while (true) {}',
          timeout: Duration.zero,
        ),
      );
      expect(surfaces, hasLength(1));

      // 下一次请求：应该建第二个表面，而且它上面跑得好好的。
      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'return 7;',
        ),
      );

      expect(surfaces, hasLength(2), reason: '没重开的话它就永久卡死了');
      expect(surfaces.last.prepared, isTrue);
      expect(result.ok, isTrue);
      expect(result.stdout, contains('返回值：7'));
    });

    test('超时只给 maxTimeout 那么多，模型写多大都不好使', () async {
      // 模型偶尔会写个 `timeout_seconds: 100000`。不夹住的话这条请求
      // 会挂到 App 关掉为止。
      final surfaces = <FakeJsSurface>[];
      final runner = WebViewJsRunner(
        createSurface: () => _makeSurface(surfaces),
        maxTimeout: const Duration(milliseconds: 80),
      );
      await runner.warmUp();
      surfaces.single.gate = Completer<String>();

      final started = DateTime.now();
      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'while (true) {}',
          timeout: Duration(hours: 1),
        ),
      );

      expect(result.timedOut, isTrue);
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
    });

    test('超时之后善后那一下不管成不成，都不该盖掉真正的错', () async {
      // 善后是"再导一次空白页看能不能把卡住的渲染进程掀掉"，纯尽力而为。
      // 它要是抛出来，用户看到的就成了一个内部异常，而不是"你写了个死循环"。
      final surfaces = <FakeJsSurface>[];
      final runner = WebViewJsRunner(
        createSurface: () => _makeSurface(surfaces),
        defaultTimeout: const Duration(milliseconds: 60),
      );
      await runner.warmUp();
      surfaces.single.gate = Completer<String>();
      surfaces.single.failNavigate = true;

      final result = await runner.run(
        const CodeRequest(
          language: CodeLanguage.javascript,
          source: 'while (true) {}',
          timeout: Duration.zero,
        ),
      );

      expect(result.stderr, contains('死循环'));
    });
  });

  group('关掉之后', () {
    test('立刻失败，不是挂在那儿', () async {
      final runner = _runner([]);
      await runner.warmUp();
      await runner.dispose();

      expect(runner.isAvailable, isFalse);
      expect(runner.unavailableReason, contains('关掉'));
      await expectLater(
        runner.run(
          const CodeRequest(
            language: CodeLanguage.javascript,
            source: 'return 1;',
          ),
        ),
        throwsA(isA<CodeException>()),
      );
    });

    test('dispose 之后预热也不会偷偷把它弄活', () async {
      final surfaces = <FakeJsSurface>[];
      final runner = _runner(surfaces);
      await runner.dispose();

      await runner.warmUp();

      expect(surfaces, isEmpty);
      expect(runner.isAvailable, isFalse);
    });
  });
}

// ─────────────────────────────── 假件 ───────────────────────────────

WebViewJsRunner _runner(
  List<FakeJsSurface> sink, {
  String? reply,
  bool failPrepare = false,
  String readyState = '"complete"',
  Duration startupTimeout = const Duration(seconds: 3),
}) {
  return WebViewJsRunner(
    createSurface: () {
      final surface = FakeJsSurface(
        failPrepare: failPrepare,
        readyState: readyState,
      );
      if (reply != null) surface.reply = reply;
      sink.add(surface);
      return surface;
    },
    startupTimeout: startupTimeout,
  );
}

/// 一个正常的信封。**多裹一层**——安卓那条路会把 JS 字符串再 JSON 编码一次。
String _envelope({
  bool ok = true,
  String? value,
  String? error,
  List<String> logs = const <String>[],
  bool logsCut = false,
}) {
  return jsonEncode(
    jsonEncode({
      'ok': ok,
      'hasValue': value != null,
      // `?value` 是"值为 null 就整个条目都不要"——真信封里就是这个样子
      // （`value` 缺省时那条键根本不存在），用 `if (...) ` 写等价，但这样更直白。
      'value': ?value,
      'error': ?error,
      'logs': logs,
      if (logsCut) 'logsCut': true,
    }),
  );
}

String _ok(String value) => _envelope(value: value);

/// 假的 WebView 表面。只假装"跟真 WebView 说话"这一层。
///
/// 继承 `webview_driver_test.dart` 那个 `FakeSurface`：导航失败、
/// `lastLoadError`、`controller` 那几件事两边一模一样，各写一份迟早会分家。
/// 这里只加求值这条路上多出来的东西。
///
/// ⚠️ **子类里不要再声明 `scripts` / `navigated` / `readyState`。** 父类有同名字段，
/// 声明了就会遮蔽——父类的 `navigate` 往它自己那个里写、你读的是你那个，永远读到
/// 空列表，而看起来一切正常。`readyState` 也一样是**接着用父类那个**（见下面的
/// 构造函数）；这里发出去的脚本另起名叫 [sentScripts]。
class FakeJsSurface extends FakeSurface {
  /// [readyState] 默认按安卓那条路的样子带引号（父类那个字段就是这个默认值）。
  FakeJsSurface({super.failPrepare, String readyState = '"complete"'}) {
    this.readyState = readyState;
  }

  /// 除了探测之外，别的求值回什么。
  String reply = '';

  /// 非 null 时求值**永远不返回**——这就是"用户代码里有个死循环"。
  Completer<String>? gate;

  /// 让它抛，看善后那一下失败会不会盖掉真正的错。
  bool failNavigate = false;

  int probes = 0;
  bool prepared = false;

  /// 发出去的非探测脚本。见类注释里的说明。
  final List<String> sentScripts = [];

  @override
  Future<void> prepare() async {
    prepared = true;
    await super.prepare();
  }

  @override
  Future<void> navigate(String url) async {
    if (failNavigate) throw StateError('导航失败');
    await super.navigate(url); // 父类会记进它自己的 `navigated`
  }

  @override
  Future<String> evaluate(String js) async {
    if (js == jsReadyStateScript) {
      probes++;
      return readyState;
    }
    sentScripts.add(js);
    final blocked = gate;
    if (blocked != null) return blocked.future;
    return reply;
  }
}


/// 造一个假表面并记进 [sink]。**别写成 `sink..add(x)`**——
/// 级联操作符返回的是**那个列表**，不是加进去的元素，于是 `createSurface`
/// 会把整个 List 当成 WebViewSurface 交出去（编译期就报，但报错指向调用处，
/// 一眼看不出是级联的锅）。
FakeJsSurface _makeSurface(List<FakeJsSurface> sink, {String? reply}) {
  final surface = FakeJsSurface();
  if (reply != null) surface.reply = reply;
  sink.add(surface);
  return surface;
}
