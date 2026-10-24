import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

void main() {
  // 这一组的对象是"注入脚本吐出来的东西怎么变成快照"。
  // 两端共用同一段解析，所以它错了两端一起错——值得单独钉住。

  final payload = jsonEncode({
    'url': 'https://example.com/a',
    'title': '标题',
    'note': '（截断了）',
    'nodes': [
      {'ref': '1', 'role': 'link', 'name': '首页', 'value': null},
      {'ref': '2', 'role': 'textbox', 'name': '搜索', 'value': '牛蛙'},
    ],
    'text': '正文内容',
  });

  group('BrowserSnapshot.fromScriptResult', () {
    test('CDP 那条路：拿到的是真正的 JSON 文本', () {
      final s = BrowserSnapshot.fromScriptResult(payload);

      expect(s.url, 'https://example.com/a');
      expect(s.title, '标题');
      expect(s.note, '（截断了）');
      expect(s.text, '正文内容');
      expect(s.nodes, hasLength(2));
      expect(s.nodes[1].ref, '2');
      expect(s.nodes[1].value, '牛蛙');
      expect(s.nodes[0].value, isNull);
    });

    test('安卓那条路：Pigeon 可能把整段再裹一层引号', () {
      // runJavaScriptReturningResult 的返回形态在源码里看不出来，
      // 所以三种可能都得认——这是其中最常见的一种。
      final s = BrowserSnapshot.fromScriptResult(jsonEncode(payload));

      expect(s.title, '标题');
      expect(s.nodes, hasLength(2));
    });

    test('首尾带单引号、里面没转义的也认', () {
      final s = BrowserSnapshot.fromScriptResult("'$payload'");
      expect(s.title, '标题');
    });

    test('前后有空白不影响', () {
      final s = BrowserSnapshot.fromScriptResult('\n  $payload  \n');
      expect(s.title, '标题');
    });

    test('完全解不出来时不抛，退化成"只有正文"的快照', () {
      // 抛的话整轮对话就断在这儿了。让模型看见一坨看不懂的东西，
      // 也比它什么都没收到强。
      final s = BrowserSnapshot.fromScriptResult('<<<不是 JSON>>>');

      expect(s.nodes, isEmpty);
      expect(s.text, contains('不是 JSON'));
      expect(s.toModelText(), contains('可交互元素：（无）'));
    });

    test('空字符串给一个空快照', () {
      final s = BrowserSnapshot.fromScriptResult('');
      expect(s.url, '');
      expect(s.nodes, isEmpty);
    });

    test('节点字段缺失或类型不对时跳过 / 兜底，不炸', () {
      final s = BrowserSnapshot.fromScriptResult(
        jsonEncode({
          'url': 'https://x/',
          'nodes': [
            {'ref': '1'}, // 没有 role/name
            {'role': 'link', 'name': '没编号'}, // 没有 ref —— 跳过
            '不是对象', // 跳过
            {'ref': 2, 'role': 'link', 'name': 123}, // ref 是数字、name 不是字符串
          ],
        }),
      );

      expect(s.nodes, hasLength(2));
      expect(s.nodes[0].role, 'element'); // 缺省兜底
      expect(s.nodes[1].ref, '2'); // 数字也收，统一成字符串
      expect(s.nodes[1].name, '123');
    });
  });

  group('unwrapJsString', () {
    // 这一组守的是一类**看不见的**失败：不剥引号不会报错、不会抛异常，
    // 只是每个字符串比较永远为假。安卓那边就栽在这上面——`complete` 到手是
    // `"complete"`，于是"页面永远加载不完"。

    test('剥掉安卓回传时包的那层引号', () {
      expect(unwrapJsString('"complete"'), 'complete');
    });

    test('剥完再把转义还原回去', () {
      expect(unwrapJsString(r'"a\"b"'), 'a"b');
      expect(unwrapJsString(r'"第一行\n第二行"'), '第一行\n第二行');
      expect(unwrapJsString(r'"中文"'), '中文');
    });

    test('CDP 那条路本来就没引号，原样返回', () {
      expect(unwrapJsString('complete'), 'complete');
      expect(unwrapJsString('https://example.com/'), 'https://example.com/');
    });

    test('前后的空白先收掉——readyState 的比较受不了空格', () {
      expect(unwrapJsString('  "complete"  '), 'complete');
      expect(unwrapJsString('\n complete \n'), 'complete');
    });

    test('只有一个引号、或者根本不是 JSON：原样还回去，**不抛**', () {
      // 这里抛的话，一个解析失败就扛掉整轮对话。
      expect(unwrapJsString('"半截'), '"半截');
      expect(unwrapJsString('"a"b"'), '"a"b"');
      expect(unwrapJsString(''), '');
      expect(unwrapJsString('""'), '');
    });

    test('数字和布尔原样：它们是 num/bool，本来就不带引号', () {
      expect(unwrapJsString('800'), '800');
      expect(unwrapJsString('true'), 'true');
    });
  });

  group('parseBrowserRef', () {
    test('正常编号解析成整数', () {
      expect(parseBrowserRef('3'), 3);
      expect(parseBrowserRef(' 12 '), 12);
    });

    test('非数字当场抛，**不把模型给的东西拼进 JS 去跑**', () {
      // 编号会被 replaceAll 进脚本源码。不解析就等于把模型的输出当代码执行。
      for (final bad in ['1); alert(1);//', '三', '', 'null']) {
        expect(
          () => parseBrowserRef(bad),
          throwsA(isA<BrowserException>()),
          reason: '「$bad」不该通过',
        );
      }
    });
  });

  group('ensureBrowserScriptOk', () {
    test('ok 放过', () {
      expect(() => ensureBrowserScriptOk('{"status":"ok"}'), returnsNormally);
    });

    test('stale 说清"重新快照一次"', () {
      // 只说"失败了"的话，模型会原地重试同一个编号——而编号已经作废了。
      expect(
        () => ensureBrowserScriptOk('{"status":"stale"}'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('重新 browser_snapshot'),
          ),
        ),
      );
    });

    test('error 把页面给的原因带出来', () {
      expect(
        () => ensureBrowserScriptOk('{"status":"error","message":"按钮被挡住了"}'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('按钮被挡住了'),
          ),
        ),
      );
    });

    test('status 缺失、乱写、不是 JSON —— 一律当失败，绝不假装成功', () {
      for (final bad in [
        '',
        '这不是 JSON',
        '{}',
        '{"status":"什么"}',
        '{"status":"ok"，中文逗号}',
      ]) {
        expect(
          () => ensureBrowserScriptOk(bad),
          throwsA(isA<BrowserException>()),
          reason: '「$bad」不该被当成成功',
        );
      }
    });

    test('安卓那种整段被再包一层引号的也认', () {
      expect(
        () => ensureBrowserScriptOk('"{\\"status\\":\\"ok\\"}"'),
        returnsNormally,
      );
    });
  });

  group('注入脚本的拼装', () {
    test('三个模板都别留占位符', () {
      expect(browserClickJs(3), isNot(contains('__REF__')));
      expect(browserTypeJs(3, 'x'), isNot(contains('__TEXT__')));
      expect(browserTypeJs(3, 'x'), isNot(contains('__REF__')));
      expect(
        browserScrollJs(ScrollDirection.down, 0.8),
        isNot(contains('__AMOUNT__')),
      );
    });

    test('ref 真的拼进了下标', () {
      expect(browserClickJs(3), contains('refs[3 - 1]'));
    });

    test('文本里的引号和反斜杠被转义掉，不会撑破字符串', () {
      final js = browserTypeJs(1, r'他说"你好"\背斜杠');

      // 原文里的裸引号不该出现在脚本里——出现就说明没转义。
      expect(js, isNot(contains('"你好"')));
      expect(js, contains(r'\"你好\"'));
    });

    test('换行和制表符被转义成 \\n \\t，不会把一行断成两行', () {
      final js = browserTypeJs(1, 'a\nb\tc');

      expect(js, contains(r'\n'));
      expect(js, contains(r'\t'));
      // 脚本里除了模板自带的行，不该多出来自文本的行
      expect(js.contains('a\nb'), isFalse);
    });

    test('滚动方向按枚举名生成，四个都在', () {
      for (final d in ScrollDirection.values) {
        expect(browserScrollJs(d, 0.8), contains("'${d.name}'"));
      }
    });

    test('amount 越界会被夹住，不会拼出滚不动的值', () {
      expect(browserScrollJs(ScrollDirection.down, 99), contains('5.00'));
      expect(browserScrollJs(ScrollDirection.down, -3), contains('0.10'));
      // NaN / 无穷 兜回默认值
      expect(browserScrollJs(ScrollDirection.down, double.nan), contains('0.80'));
    });
  });

  group('快照脚本本体', () {
    test('是自执行、有返回值的，并且重置了编号表', () {
      // 编号表每次重建 = "旧编号自动作废"这件事有代码兜底，不靠约定。
      expect(browserSnapshotJs, contains('window.__n1 = { refs: refs'));
      expect(browserSnapshotJs, startsWith('(() =>'));
      expect(browserSnapshotJs.trimRight(), endsWith('})()'));
      expect(browserSnapshotJs, contains('return JSON.stringify'));
    });

    test('跨域 iframe 的 SecurityError 被关在 try 里', () {
      // 不关的话一个跨域 iframe 就能让整段脚本抛掉，页面直接读不到。
      expect(
        browserSnapshotJs,
        contains('frames[j].contentDocument'),
      );
      expect(browserSnapshotJs, contains('catch (e) { inner = null; }'));
    });

    test('正文在脚本里就先截一次，别把整页几 MB 传回来', () {
      expect(browserSnapshotJs, contains('text.length > MAX_TEXT'));
    });

    // ── 下面两条是这个文件里**唯一能自动抓住"脚本本身语法错"**的东西 ──
    //
    // 为什么值得单独一栏：这错我真写出来过（2026-10-10）。`'\n\n'` 在源码里被
    // 写成了真的两个换行，字符串字面量当场断行，整份脚本抛
    // `SyntaxError: Unexpected token '}'`——而报错行号指向别处，看着像括号
    // 不平衡。默认测试全绿，因为默认测试不跑真浏览器；等发现的时候是在真机上
    // 配着报错猜。这两条不需要浏览器。

    test('没有字符串字面量跨行——跨行就是语法错', () {
      final bad = stringsSpanningLines(browserSnapshotJs);
      expect(bad, isEmpty, reason: '${bad.join('；')}\n这会让整份脚本解析不过。');
    });

    test('没有不可见字符', () {
      // 用码点写，**不要**把字符直接贴进来——这条测试要防的就是「看不见的
      // 字符混进源码」，它自己先得干净。
      const invisible = {
        0x00a0: '不间断空格',
        0x2028: '行分隔符',
        0x2029: '段分隔符',
        0x200b: '零宽空格',
        0xfeff: 'BOM',
      };
      for (final entry in invisible.entries) {
        expect(
          browserSnapshotJs.contains(String.fromCharCode(entry.key)),
          isFalse,
          reason: '脚本里躺着一个${entry.value}，出事时没人查得出来',
        );
      }
    });
  });
}

/// 扫一遍 JS 源码，报告「字符串字面量跨行」的位置。
///
/// **不是**完整的 JS 词法分析器，只做一件事：跳过注释之后，确认没有哪个
/// `'` 或 `"` 开的字符串跨了行。它只认这两件事，别拿它当解析器用。
///
/// 跳过注释是必须的——注释里的引号会被当成字符串开头，那才是误报来源。
/// 正则字面量（`/.../`）不特殊处理：这份脚本里的正则都不含引号，
/// 真加了含引号的正则就得回来补这一块。
List<String> stringsSpanningLines(String js) {
  final bad = <String>[];
  var i = 0;
  var line = 1;

  while (i < js.length) {
    final c = js[i];

    if (c == '\n') {
      line++;
      i++;
      continue;
    }

    // 行注释：一路跳到行尾
    if (c == '/' && i + 1 < js.length && js[i + 1] == '/') {
      final nl = js.indexOf('\n', i);
      if (nl < 0) break;
      i = nl;
      continue;
    }

    // 块注释
    if (c == '/' && i + 1 < js.length && js[i + 1] == '*') {
      final end = js.indexOf('*/', i + 2);
      if (end < 0) break;
      for (var k = i; k < end; k++) {
        if (js[k] == '\n') line++;
      }
      i = end + 2;
      continue;
    }

    if (c == "'" || c == '"') {
      final quote = c;
      final startLine = line;
      i++;
      var closed = false;
      while (i < js.length) {
        final d = js[i];
        if (d == '\\') {
          i += 2; // 转义掉下一个字符（含 \\' 和 \\n）
          continue;
        }
        if (d == '\n') break; // 断在行内 = 就是这个错
        if (d == quote) {
          closed = true;
          i++;
          break;
        }
        i++;
      }
      if (!closed) {
        bad.add('第 $startLine 行开始的那个 $quote 字符串没在本行内闭合');
      }
      continue;
    }

    i++;
  }

  return bad;
}
