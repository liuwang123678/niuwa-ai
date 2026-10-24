/// 借 WebView 跑 JS 的**协议**：代码怎么送进去、结果怎么接回来。
///
/// 纯 Dart，`lib/services/code/webview_js_runner.dart` 只负责"跟 WebView 说话"，
/// 脚本长什么样、解析怎么退化全在这儿——这样不用真机也能把协议钉住。
/// ⚠️ 这个文件在 `lib/core/` 底下，**不许 import 任何 `package:` 平台包**。
/// `test/core_is_pure_test.dart` 只 grep `package:flutter/`，
/// 在这儿写 `package:webview_flutter` 它照样绿——别指望那条测试替你守。
library;

import 'dart:convert';

import '../browser/browser_driver.dart' show decodeScriptPayload;

/// 等 WebView 就绪用的脚本。
///
/// 跟 `browser/snapshot_script.dart` 里那个 `browserReadyStateJs` 是同一句话，
/// 这里**故意各留一份**：代码执行器不该依赖浏览器那套脚本文件（那边是一整套
/// 注入脚本，耦合上去以后改一边要想起另一边）。一个字符串常量的重复不值一提。
const String jsReadyStateScript = 'document.readyState';

/// 空白页。**必须先导航一次再求值。**
///
/// 刚建出来的 `WebViewController` 手上是一个还没加载任何文档的 WebView，
/// 那时候 `evaluateJavascript` 没有可以执行的环境。`about:blank` 是最省事的
/// 一个"有文档的页面"：不要网络、不要权限、没有站点脚本。
const String jsBlankPage = 'about:blank';

/// 造一段跑用户代码的 JS。
///
/// ## 为什么外面要包这么厚一层
///
/// ### ① JS 里的异常**不会**抛到 Dart
///
/// `evaluateJavascript` 在内部脚本出错时**只回一个 null**——不抛、不报错，
/// 拿回来的就是一个 null。所以你必须在 JS 侧自己 try/catch，把结果包成一个
/// 信封带回来，Dart 侧再拆。不这么做的话，"用户代码报错了"和"引擎卡死了"
/// 在 Dart 这边长得一模一样。
///
/// ### ② 用 `new Function(src)` 而不是把源码拼进脚本文本
///
/// 拼进去的话，用户代码里一个括号不配，**整段脚本**（包括我们那个 try/catch）
/// 都解析不过去，直接退化成上面那个 null。用 `new Function` 把编译推迟到运行时，
/// 语法错就变成一个**能被 catch 住的 SyntaxError**，能原样报给模型——
/// 而"你这儿少个括号"正是它最需要听到的一句话。
///
/// ### ③ Promise 要显式挡掉
///
/// `JSON.stringify(promise)` 是 `{}`。不拦的话模型写个 `fetch(...).then(...)`，
/// 拿回来一个 `{}`，然后它会以为"查到了，是空的"——**一个沉默的错误答案**，
/// 比报错糟得多。`runJavaScriptReturningResult` 不会等 Promise，
/// 这条路上只能同步算完。
///
/// ### ④ console 要接过来
///
/// 不然 `console.log` 的东西全进 logcat，模型一个字都看不到，而它八成会用
/// `console.log` 来打印中间结果（写 Python 时它也用 print）。
///
/// [maxLogs] 是**条数**上限，不是长度。少收几条日志的代价远小于一个
/// `for(;;) console.log(i)` 把内存顶穿——那种脚本连返回值都带不回来。
String jsRunScript(String source, {int maxLogs = 40}) {
  // `jsonEncode` 出来的东西**一定能安全地当一个 JS 字符串字面量**：
  // 引号、反斜杠、换行、U+2028/U+2029 全都被转义了。
  // 这正是这个协议唯一需要的小心处——别自己拼引号。
  final literal = jsonEncode(source);

  return '''
(function () {
  var __logs = [];
  var __logsCut = false;
  var __maxLogs = $maxLogs;

  var __names = ['log', 'info', 'debug', 'warn', 'error'];
  var __real = {};
  for (var __i = 0; __i < __names.length; __i++) {
    (function (__name) {
      __real[__name] = console[__name];
      console[__name] = function () {
        if (__logs.length >= __maxLogs) {
          __logsCut = true;
        } else {
          var __parts = [];
          for (var __j = 0; __j < arguments.length; __j++) {
            __parts.push(__text(arguments[__j]));
          }
          __logs.push(__name + ': ' + __parts.join(' '));
        }
        try { __real[__name].apply(console, arguments); } catch (__e) {}
      };
    })(__names[__i]);
  }

  function __json(v) {
    try {
      var s = JSON.stringify(v);
      if (typeof s !== 'undefined') return s;
    } catch (__e) {}
    try { return String(v); } catch (__e2) { return '(这个值打不出来)'; }
  }

  // console 的参数：字符串原样（`log: 你好` 比 `log: "你好"` 好读），别的走 JSON。
  function __text(v) {
    if (typeof v === 'string') return v;
    return __json(v);
  }

  var __source = $literal;
  var __payload;

  try {
    var __fn = new Function(__source);
    var __value = __fn();

    if (__value && typeof __value.then === 'function') {
      __payload = {
        ok: false,
        hasValue: false,
        error: '这段代码返回的是一个 Promise（异步结果），这条路等不到它。' +
               'run_code 只能同步跑完给结果：要么去掉 async / await，' +
               '要么把要等的东西换成别的工具做。',
        logs: __logs
      };
    } else {
      __payload = {
        ok: true,
        hasValue: typeof __value !== 'undefined',
        // ⚠️ 返回值走 `__json`，**字符串也带引号**——跟 console 那条不一样。
        // 不加引号的话 `return "2"` 和 `return 2` 会显示成同一个 `2`，
        // 模型分不出手里是字符串还是数字，而它拿这个结果是要接着算的。
        value: __json(__value),
        logs: __logs
      };
    }
  } catch (__err) {
    var __msg;
    try {
      __msg = (__err && __err.name ? __err.name + ': ' : '') +
              (__err && __err.message ? __err.message : String(__err));
    } catch (__e3) {
      __msg = '(连错误信息都读不出来)';
    }
    __payload = { ok: false, hasValue: false, error: __msg, logs: __logs };
  }

  if (__logsCut) __payload.logsCut = true;
  return JSON.stringify(__payload);
})()
''';
}

/// 从脚本返回的那串 JSON 里拆出来的东西。
class JsRunOutcome {
  const JsRunOutcome({
    required this.ok,
    required this.hasValue,
    this.value,
    this.error,
    this.logs = const <String>[],
    this.logsCut = false,
  });

  /// 代码自己跑完了没报错。
  final bool ok;

  /// 有没有返回值（`undefined` 不算有）。区分这个是因为"返回了 null"和
  /// "压根没返回东西"对模型是两句不同的话。
  final bool hasValue;

  /// 返回值渲染成的文本。**已经是 JSON**（字符串带引号），不是 Dart 对象。
  final String? value;

  /// 出错时的一句话。形如 `TypeError: xxx is not a function`。
  final String? error;

  /// console 收上来的日志，按发生顺序。
  final List<String> logs;

  /// 日志条数到顶了，后面的没记。
  final bool logsCut;

  /// 拆信封。**拆不动返回 null**，由调用方决定怎么退化和怎么说。
  ///
  /// 为什么可能拆不动：整个脚本抛在解析期（不可能，脚本是我们自己生成的）、
  /// 引擎崩了、或者被我们超时放弃之后又慢吞吞回了个半截。
  /// 这些都不该在这一层编一句理由出来——调用方知道当时在干什么，它来说。
  ///
  /// 走 [decodeScriptPayload]：安卓那条路会把 JS 字符串再 JSON 编码一层，
  /// `{"ok":...}` 到手是 `"{\"ok\":...}"`。那个函数已经把"三层退化"写好了。
  static JsRunOutcome? tryParse(String raw) {
    final payload = decodeScriptPayload(raw);
    if (payload == null) return null;

    final logs = <String>[];
    final rawLogs = payload['logs'];
    if (rawLogs is List) {
      for (final entry in rawLogs) {
        if (entry != null) logs.add('$entry');
      }
    }

    // ⚠️ 全程用 `== true` 和 `== null` 判，不用 `as bool` / `as String?`。
    // 这个 Map 是 `jsonDecode` 出来的，里面是什么类型由**对面**决定；
    // 用强制转换的话，对面回一个 `"true"`（字符串）就能让这儿抛一个
    // 类型错——而那时候我们连"是解析出问题"都说不清。
    final error = payload['error'];
    final value = payload['value'];

    return JsRunOutcome(
      ok: payload['ok'] == true,
      hasValue: payload['hasValue'] == true,
      value: value == null ? null : '$value',
      error: error == null ? null : '$error',
      logs: logs,
      logsCut: payload['logsCut'] == true,
    );
  }
}
