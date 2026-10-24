import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 借 WebView 跑 JS 的协议。
///
/// 分两半，因为这是两个不同的问题：
///
///   1. **生成的脚本本身对不对**——跑一下才知道。Dart 里没有 JS 引擎，
///      所以这一半是把脚本丢进 `node` 跑（见 [_runInNode]）。有个前提要认：
///      **node 不是安卓 WebView**，底下虽然都是 V8、我们要钉的这几条语义
///      完全一样，但它验不了"WebView 里能不能跑起来"。那条只有真机能回答。
///   2. **拆信封对不对**——纯解析，全在 Dart 里。
///
/// ⚠️ 没装 node 的机器上，第一组会**带着理由跳过**（`skip:` 不是静默 return）。
/// 静默跳过是最坏的一种绿：看起来验过了，其实一行都没跑。
void main() {
  final hasNode = _nodeAvailableSync();

  if (!hasNode) {
    // 让这件事在输出里吵一点。跳过的组没人会点开看，但"哪些结论其实没有
    // 证据"这件事得有人知道。
    // ignore: avoid_print
    print('⚠️ 这台机器上没有 node，跳过"生成的脚本真跑一遍"那一组。'
        '它是 JS 侧信封协议唯一的实测证据（语法错能不能捕获、Promise 会不会'
        '被当成 {} 放过去）——跳过了，那几条就只剩源码推理。');
  }

  group('生成的脚本（丢进 node 真跑）', () {
    test('正常返回：信封说 ok，而且值能拿出来', () async {
      final outcome = await _runInNode('return 1 + 1;');

      expect(outcome, isNotNull, reason: '连信封都没解析出来');
      expect(outcome!.ok, isTrue);
      expect(outcome.hasValue, isTrue);
      expect(outcome.value, '2');
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('🩸 用户代码的语法错变成**可捕获**的异常，不是一句冷冰冰的 null', () async {
      // 这一条是整个协议里最值钱的一条。如果源码是拼进脚本文本的，一个不配的
      // 括号会让**整段脚本**解析不过去，`evaluateJavascript` 只回一个 null，
      // 我们连"是语法错"都说不出来。`new Function` 把编译推迟到运行时，
      // 它就变成一个能 catch 的 SyntaxError——而"你少个括号"正是模型要听的。
      final outcome = await _runInNode('return 1 +;');

      expect(outcome, isNotNull);
      expect(outcome!.ok, isFalse);
      expect(outcome.error, contains('SyntaxError'));
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('运行期报错：也是 ok=false + 一句看得懂的错', () async {
      final outcome = await _runInNode('var a = null; return a.x;');

      expect(outcome!.ok, isFalse);
      expect(outcome.error, contains('TypeError'));
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('🩸 Promise 被挡下来，**不会**变成一个 {} 放过去', () async {
      // JSON.stringify(promise) 是 `{}`。不拦的话模型拿到一个 `{}`，
      // 会以为"查到了，是空的"——一个沉默的错误答案，比报错糟得多。
      final outcome = await _runInNode('return Promise.resolve(42);');

      expect(outcome!.ok, isFalse);
      expect(outcome.hasValue, isFalse);
      expect(outcome.error, contains('Promise'));
      expect(
        outcome.value ?? '',
        isNot('{}'),
        reason: '一旦出现 {}，就说明这个拦截漏了',
      );
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('console 被接过来，中文原样', () async {
      final outcome = await _runInNode(
        "console.log('你好', {a: 1}); console.warn('小心'); return 0;",
      );

      // 对象按 `JSON.stringify` 的样子来（没有空格），字符串不加引号。
      expect(outcome!.logs, ['log: 你好 {"a":1}', 'warn: 小心']);
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('日志条数到顶就停，并且如实标一下', () async {
      final outcome = await _runInNode(
        'for (var i = 0; i < 10; i++) console.log(i); return 0;',
        maxLogs: 3,
      );

      expect(outcome!.logs, hasLength(3));
      expect(outcome.logsCut, isTrue);
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('没写 return：hasValue 是 false，而不是编一个 null 出来', () async {
      final outcome = await _runInNode('var x = 1;');

      expect(outcome!.ok, isTrue);
      expect(outcome.hasValue, isFalse);
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('明确 return null：那是**有**值，值是 null', () async {
      // "返回了 null"和"什么都没返回"对模型是两句不同的话。
      final outcome = await _runInNode('return null;');

      expect(outcome!.hasValue, isTrue);
      expect(outcome.value, 'null');
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('返回值就是字符串时带引号（它是 JSON）', () async {
      final outcome = await _runInNode("return 'abc';");
      expect(outcome!.value, '"abc"');
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('源码里的引号、反斜杠、换行、行分隔符都不会把脚本拼坏', () async {
      // 拼接安全全靠 `jsonEncode`。自己拼引号的话，下面这段里随便一个字符
      // 都能让整段脚本解析不过去：单引号、反斜杠、真的换行、双引号，
      // 还有 U+2028 / U+2029（JS 语法里当行终止符使的两个字符）。
      //
      // ⚠️ 它们在这儿一律写成**转义**（Dart 侧 `\\u2028` → JS 源码里是
      // `\u2028` 六个字符），绝不贴真的进来——Dart 的语法里 U+2028/U+2029
      // **也是行终止符**，真贴进来会让这个测试文件自己编译不过去。
      // 这个坑本项目在 `snapshot_script.dart` 的注释里记过一次。
      const source = "var s = 'a\\\\b\\n\"c\"\\u2028\\u2029👍'; return s;";
      final outcome = await _runInNode(source);

      expect(outcome, isNotNull, reason: '拼坏了的话根本解析不出信封');
      expect(outcome!.ok, isTrue, reason: outcome.error);
      expect(jsonDecode(outcome.value!), contains('👍'));
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('throw 一个非 Error 的东西也说得出来', () async {
      final outcome = await _runInNode("throw '一句字符串';");

      expect(outcome!.ok, isFalse);
      expect(outcome.error, contains('一句字符串'));
    }, skip: hasNode ? null : '这台机器上没有 node');

    test('console.log 里的循环引用不会把整个信封弄崩', () async {
      // `JSON.stringify` 撞上循环引用是**抛异常**的。没兜住的话，
      // 连日志带返回值整个信封都没了。
      final outcome = await _runInNode(
        'var a = {}; a.self = a; console.log(a); return 1;',
      );

      expect(outcome, isNotNull, reason: '信封本身得活着');
      expect(outcome!.ok, isTrue);
      expect(outcome.value, '1');
      expect(outcome.logs, hasLength(1), reason: '打不出来的值也得有条日志占位');
    }, skip: hasNode ? null : '这台机器上没有 node');
  });

  group('拆信封', () {
    test('安卓那条路：外面还裹着一层 JSON 字符串', () {
      // `runJavaScriptReturningResult` 把 JS 字符串再编码一层，
      // 所以到手的原始文本长这样（注意外面那对引号和里面的转义）。
      const inner = '{"ok":true,"hasValue":true,"value":"2","logs":[]}';
      final raw = jsonEncode(inner);

      final outcome = JsRunOutcome.tryParse(raw);

      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue);
      expect(outcome.value, '2');
    });

    test('真机没多裹那一层时也得认（不假设对面怎么编码）', () {
      final outcome = JsRunOutcome.tryParse(
        '{"ok":true,"hasValue":false,"logs":["log: hi"]}',
      );

      expect(outcome!.ok, isTrue);
      expect(outcome.hasValue, isFalse);
      expect(outcome.logs, ['log: hi']);
    });

    test('拆不动返回 null，**不在这一层编理由**', () {
      // 为什么可能拆不动（引擎崩了、被超时放弃之后回了个半截），
      // 只有调用方知道。这一层编一句"可能是内存不够"就是瞎猜。
      expect(JsRunOutcome.tryParse(''), isNull);
      expect(JsRunOutcome.tryParse('null'), isNull);
      expect(JsRunOutcome.tryParse('这不是 JSON'), isNull);
      expect(JsRunOutcome.tryParse('[1,2,3]'), isNull, reason: '不是个对象');
    });

    test('字段类型不对时按"没有"处理，不抛类型错', () {
      // 这个 Map 是 jsonDecode 出来的，里面是什么类型由对面决定。
      // 用 `as bool` 的话，对面回一个字符串 "true" 就能把这儿炸掉——
      // 而那时候我们连"是解析出问题"都说不清。
      final outcome = JsRunOutcome.tryParse(
        '{"ok":"true","hasValue":1,"value":123,"error":456,"logs":"不是数组"}',
      );

      expect(outcome!.ok, isFalse, reason: '只有真 true 才算真');
      expect(outcome.hasValue, isFalse);
      expect(outcome.value, '123', reason: '能转成字符串就算有值');
      expect(outcome.error, '456');
      expect(outcome.logs, isEmpty);
    });

    test('logsCut 只有真 true 才算', () {
      expect(
        JsRunOutcome.tryParse('{"ok":true,"logsCut":true}')!.logsCut,
        isTrue,
      );
      expect(JsRunOutcome.tryParse('{"ok":true}')!.logsCut, isFalse);
    });
  });
}

// ────────────────────────────── node 那一段 ──────────────────────────────

/// 生成的脚本里包住结果用的标记。
///
/// 为什么不用 `console.log` 打结果：脚本会把 `console.log` 换掉（这正是它
/// 要干的事），用户代码自己打的日志也会进 stdout。用一对不可能撞上的标记
/// 把返回值夹出来，才不用去猜哪一行是哪个。
const String _markerStart = '<<<N1JS>>>';
const String _markerEnd = '<<<N1JS-END>>>';

/// 在 `main()` 里同步问一次。`test(..., skip: ...)` 要的是一个**声明期**就知道
/// 的答案，async 的 setUp 做不到这件事。
bool _nodeAvailableSync() {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 把 `jsRunScript` 生成的脚本丢进 node 跑一遍，把信封解析出来。
///
/// **这是跨引擎对账，不是真机验证。** 见文件头的说明。
Future<JsRunOutcome?> _runInNode(String source, {int maxLogs = 40}) async {
  final dir = await Directory.systemTemp.createTemp('n1_js_');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}probe.js');
    // ⚠️ 脚本是个**表达式**，得先接住再打出来；直接写会变成一条没人要的
    // 表达式语句（在 node 里连输出都没有）。
    await file.writeAsString(
      'var __out = ${jsRunScript(source, maxLogs: maxLogs)};\n'
      'process.stdout.write("$_markerStart" + __out + "$_markerEnd");\n',
    );

    // 🩸 **必须显式指定 UTF-8。** `Process.run` 默认按 `systemEncoding` 解，
    // 中文 Windows 上是 GBK——node 那边吐出来的 UTF-8 中文会被解成
    // `灏忓績` 这种乱码。更坏的是 GBK 是双字节编码，它的第二个字节可能正好
    // 落在 `"` 或 `\` 上，**把 JSON 本身撑破**，于是报回来的是"解析失败"，
    // 看起来像是协议写错了。第一次跑这个测试就是这么挂的。
    final result = await Process.run(
      'node',
      [file.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      fail('node 跑挂了（${result.exitCode}）：${result.stderr}');
    }

    final out = '${result.stdout}';
    final from = out.indexOf(_markerStart);
    final to = out.indexOf(_markerEnd);
    if (from < 0 || to < 0) {
      fail('没找到返回的那段东西。整个 stdout：$out');
    }

    return JsRunOutcome.tryParse(
      out.substring(from + _markerStart.length, to),
    );
  } finally {
    await dir.delete(recursive: true);
  }
}
