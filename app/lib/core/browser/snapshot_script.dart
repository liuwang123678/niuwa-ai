import 'dart:convert';

import 'browser_driver.dart';

/// 注入到页面里的 JS。**两端共用同一份。**
///
/// 为什么不各写一份：快照格式必须两端一致（`BrowserSnapshot.toModelText` 的
/// 注释里写着这条），脚本分家的话"一致"就只能靠人盯，而人盯不住。
///
/// ## 为什么所有返回值都是 JSON 字符串
///
/// Android 的 `runJavaScriptReturningResult` 经 Pigeon 过一道，Dart 侧拿到的是
/// 什么形态并不确定（见 [decodeScriptPayload]）。统一返回 JSON 文本，解析就只有
/// **一条**路径，不用为"点一下返回 `OK` 还是 `"OK"`"写两套判断。
///
/// ## 为什么不用注入 `<script>` 标签
///
/// 那条路会被页面 CSP 挡。CDP 的 `Runtime.evaluate` 和 Android 的
/// `evaluateJavascript` 都是**控制端**注入，不受页面 CSP 约束。所以脚本常量直接
/// 交给引擎跑，别自己去插标签。
///
/// ## 已知看不到的东西（不是 bug，是浏览器的安全模型）
///
/// - **跨域 iframe 里的内容**：`iframe.contentDocument` 直接抛 SecurityError。
///   所以登录框、支付框、reCAPTCHA 全在快照之外——工具 description 和技能文档
///   都要说，让模型撞上时停下来找用户，而不是对着空快照反复试。
/// - **Shadow DOM 里的内容**：`querySelectorAll` 不穿 shadow root，
///   YouTube 这类站点会漏主内容。这一版先不穿，TODO 记在这儿。
///
/// ⚠️ 这份脚本里**不许出现不可见字符**——不间断空格（U+00A0）、行分隔符
/// （U+2028/U+2029）、零宽字符这些。要匹配它们就写 `\u00a0` 这种转义，
/// 别贴真的进来。
///
/// 这不是洁癖，是**真栽过**：`\n` 被写成真的换行之后，字符串字面量直接断行，
/// 整份脚本抛 `SyntaxError: Unexpected token '}'`，而报错行号指向别处，看着
/// 像括号不平衡，查了半天。中文本身没问题（文件和传输全程 UTF-8），危险的
/// 是**看不见**的那些。
const String browserSnapshotJs = r'''
(() => {
  var MAX_NODES = 300;
  var MAX_SCAN = 3000;
  var MAX_TEXT = 20000;
  var MAX_NAME = 120;

  var SEL = 'a,button,input,select,textarea,[role=button],[role=link],' +
            '[role=checkbox],[role=radio],[role=switch],[role=tab],' +
            '[role=menuitem],[onclick]';

  function txt(v) {
    if (v === null || v === undefined) return '';
    return String(v).replace(/[\s\u00a0]+/g, ' ').trim();
  }

  function attr(el, n) {
    try { return el.getAttribute ? (el.getAttribute(n) || '') : ''; }
    catch (e) { return ''; }
  }

  function roleOf(el) {
    var explicit = txt(attr(el, 'role'));
    if (explicit) return explicit;
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'a') return 'link';
    if (tag === 'button') return 'button';
    if (tag === 'select') return 'select';
    if (tag === 'textarea') return 'textbox';
    if (tag === 'input') {
      var t = txt(attr(el, 'type')).toLowerCase() || 'text';
      if (t === 'submit' || t === 'button' || t === 'reset' || t === 'image') return 'button';
      if (t === 'checkbox') return 'checkbox';
      if (t === 'radio') return 'radio';
      if (t === 'hidden') return 'hidden';
      return 'textbox';
    }
    return 'element';
  }

  // 优先级不是拍脑袋：模型全靠这个字符串判断该点哪个，
  // 所以按"人眼认这个控件靠什么"排——无障碍名 > 可见文字 > 提示 > 已填的值。
  function nameOf(el) {
    var s = txt(attr(el, 'aria-label'));
    if (s) return s.slice(0, MAX_NAME);
    try { s = txt(el.innerText || el.textContent); } catch (e) { s = ''; }
    if (s) return s.slice(0, MAX_NAME);
    // 只有图标的按钮/链接：名字在里面的 img 上。实测百度首页就有几个
    // 名字为空的可点元素（`link ""`），模型对着它只能瞎猜——
    // 而图标按钮在这类元素里占比很高，值得单独捞一次。
    try {
      var icon = el.querySelector ? el.querySelector('img[alt],svg[aria-label]') : null;
      if (icon) {
        s = txt(attr(icon, 'alt') || attr(icon, 'aria-label'));
        if (s) return s.slice(0, MAX_NAME);
      }
    } catch (e) { /* 跨域 iframe 之类，跳过 */ }
    s = txt(attr(el, 'title'));
    if (s) return s.slice(0, MAX_NAME);
    s = txt(attr(el, 'placeholder'));
    if (s) return s.slice(0, MAX_NAME);
    try { s = txt(el.value); } catch (e) { s = ''; }
    if (s) return s.slice(0, MAX_NAME);
    s = txt(attr(el, 'alt'));
    if (s) return s.slice(0, MAX_NAME);
    s = txt(attr(el, 'name'));
    if (s) return s.slice(0, MAX_NAME);
    // 最后才轮到 href。判断"这条链接通向哪"，URL 有时候比文字还准；
    // 而且空字符串对模型毫无信息量，有总比没有强。
    return txt(attr(el, 'href')).slice(0, MAX_NAME);
  }

  // 有 client rect 就算"在页面上"——**刻意不判"在不在视口里"**：
  // 视口外的元素也要给编号，否则滚动就没有意义了（滚动之后要能点到它）。
  function visible(el) {
    try {
      if (!el.getClientRects || el.getClientRects().length === 0) return false;
      var doc = el.ownerDocument;
      var win = (doc && doc.defaultView) ? doc.defaultView : window;
      var st = win.getComputedStyle(el);
      if (!st) return true;
      if (st.visibility === 'hidden' || st.display === 'none') return false;
      if (parseFloat(st.opacity) === 0) return false;
      return true;
    } catch (e) { return false; }
  }

  function isForm(el) {
    var tag = (el.tagName || '').toLowerCase();
    return tag === 'input' || tag === 'select' || tag === 'textarea';
  }

  // 同源 iframe 递归进去（很多站点的控件在 iframe 里）。
  // 跨域的直接抛 SecurityError，catch 掉跳过——**绝不能让它带崩整段脚本**。
  function collect(doc, depth) {
    var found = [];
    if (!doc || depth > 2) return found;
    var all;
    try { all = doc.querySelectorAll(SEL); } catch (e) { return found; }
    for (var i = 0; i < all.length && i < MAX_SCAN; i++) {
      var el = all[i];
      if (roleOf(el) === 'hidden') continue;
      if (!visible(el)) continue;
      found.push(el);
    }
    var frames;
    try { frames = doc.querySelectorAll('iframe'); } catch (e) { frames = []; }
    for (var j = 0; j < frames.length && j < 20; j++) {
      var inner = null;
      try { inner = frames[j].contentDocument; } catch (e) { inner = null; }
      if (inner) found = found.concat(collect(inner, depth + 1));
    }
    return found;
  }

  // 超预算时**先保住表单控件**，其余按 DOM 顺序收到额满为止。
  // 保留 DOM 顺序很重要：模型读编号列表时是按页面从上到下理解的。
  function trim(list) {
    if (list.length <= MAX_NODES) return { kept: list, truncated: false };
    var marked = {};
    var markedCount = 0;
    var reserve = Math.floor(MAX_NODES / 3);
    for (var i = 0; i < list.length && reserve > 0; i++) {
      if (isForm(list[i])) { marked[i] = true; markedCount++; reserve--; }
    }
    var plain = MAX_NODES - markedCount;
    var kept = [];
    for (var j = 0; j < list.length; j++) {
      if (marked[j]) { kept.push(list[j]); }
      else if (plain > 0) { kept.push(list[j]); plain--; }
    }
    return { kept: kept, truncated: true };
  }

  var picked = trim(collect(document, 0));
  var refs = [];
  var nodes = [];

  for (var n = 0; n < picked.kept.length; n++) {
    var el = picked.kept[n];
    var rec = {
      ref: String(n + 1),
      role: roleOf(el),
      name: nameOf(el),
      value: null
    };
    if (isForm(el)) {
      var v = '';
      try { v = txt(el.value); } catch (e) { v = ''; }
      if (v) rec.value = v.slice(0, 80);
    }
    nodes.push(rec);
    // 元素引用留在页面上下文里，下一次快照会整体重建 —— 这就是
    // "编号只在下一次快照之前有效"的代码强制，不再靠约定。
    refs.push(el);
  }

  var text = '';
  try {
    var main = document.querySelector('main, article, [role=main]');
    var host = main || document.body || document.documentElement;
    text = String(host ? host.innerText : '') || '';
  } catch (e) { text = ''; }
  // 正文保留换行（段落结构对模型有用），只收掉行内多余空白和连续空行。
  text = text.replace(/[ \t\u00a0]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
  if (text.length > MAX_TEXT) text = text.slice(0, MAX_TEXT);

  var note = '';
  if (picked.truncated) {
    note = '（可交互元素太多，超过 ' + MAX_NODES + ' 个的部分没列出来；' +
           '没找到的东西可能在下面，试着往下滚）';
  }

  window.__n1 = { refs: refs, url: String(location.href) };

  return JSON.stringify({
    url: String(location.href),
    title: String(document.title || ''),
    note: note,
    nodes: nodes,
    text: text
  });
})()
''';

/// 页面的加载状态。`open` / `click` 之后靠轮询它来判断"现在能不能读了"。
const String browserReadyStateJs = 'document.readyState';

/// 点一个编号对应的元素。
///
/// [ref] 由调用方先 `int.tryParse`，**解析不出数字就别调这个函数**——
/// 编号是本脚本自己发出去的，非数字只可能是模型瞎编或已经过期。
const String _clickTemplate = r'''
(() => {
  var m = window.__n1;
  if (!m || !m.refs) return JSON.stringify({status:'stale'});
  var el = m.refs[__REF__ - 1];
  if (!el) return JSON.stringify({status:'stale'});
  try { if (el.scrollIntoView) el.scrollIntoView({block:'center'}); } catch (e) {}
  try { if (el.focus) el.focus(); } catch (e) {}
  try { el.click(); } catch (e) {
    return JSON.stringify({status:'error', message: String(e)});
  }
  return JSON.stringify({status:'ok'});
})()
''';

/// 往输入框里填字。
///
/// **走原生 setter + 手动派发 input/change**，不是 `el.value = x`：React / Vue
/// 这类框架在 value 上装了劫持，直接赋值它看不见——界面上字是填进去了，框架的
/// 内部状态还是空的，点提交时提交的是空。这一段是必需的，不是讲究。
const String _typeTemplate = r'''
(() => {
  var m = window.__n1;
  if (!m || !m.refs) return JSON.stringify({status:'stale'});
  var el = m.refs[__REF__ - 1];
  if (!el) return JSON.stringify({status:'stale'});
  var value = __TEXT__;
  try { if (el.focus) el.focus(); } catch (e) {}
  try {
    var proto = null;
    if (typeof HTMLTextAreaElement !== 'undefined' && el instanceof HTMLTextAreaElement) {
      proto = HTMLTextAreaElement.prototype;
    } else if (typeof HTMLInputElement !== 'undefined' && el instanceof HTMLInputElement) {
      proto = HTMLInputElement.prototype;
    }
    var setter = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
    if (setter && setter.set) { setter.set.call(el, value); }
    else if ('value' in el) { el.value = value; }
    else { el.textContent = value; }
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
  } catch (e) {
    return JSON.stringify({status:'error', message: String(e)});
  }
  return JSON.stringify({status:'ok'});
})()
''';

/// 滚一屏。`up` / `down` 按 `window.innerHeight` 的比例走，`top` / `bottom` 到头。
///
/// ⚠️ `window.innerHeight` 为 0 时 up/down **什么都滚不动**（安卓零尺寸 WebView
/// 就会这样）。所以那边的实现必须挂一个真实尺寸的 WebView。
///
/// 这几个方向词是按 [ScrollDirection] 的 `name` 生成的，改枚举名这里跟着改。
const String _scrollTemplate = r'''
(() => {
  var h = window.innerHeight || 800;
  var d = '__DIR__';
  var amount = __AMOUNT__;
  try {
    if (d === 'top') {
      window.scrollTo(0, 0);
    } else if (d === 'bottom') {
      var de = document.documentElement;
      var bd = document.body;
      var total = Math.max(de ? de.scrollHeight : 0, bd ? bd.scrollHeight : 0, h);
      window.scrollTo(0, total);
    } else {
      var delta = Math.round(h * amount);
      window.scrollBy(0, d === 'up' ? -delta : delta);
    }
  } catch (e) {
    return JSON.stringify({status:'error', message: String(e)});
  }
  return JSON.stringify({status:'ok'});
})()
''';

/// [ref] 必须是已解析过的整数。
String browserClickJs(int ref) => _clickTemplate.replaceAll('__REF__', '$ref');

/// [ref] 必须是已解析过的整数。
String browserTypeJs(int ref, String text) => _typeTemplate
    .replaceAll('__REF__', '$ref')
    .replaceAll('__TEXT__', _jsStringLiteral(text));

String browserScrollJs(ScrollDirection direction, double amount) {
  final clamped = amount.isFinite ? amount.clamp(0.1, 5.0) : 0.8;
  return _scrollTemplate
      .replaceAll('__DIR__', direction.name)
      .replaceAll('__AMOUNT__', clamped.toStringAsFixed(2));
}

/// 把 Dart 字符串变成能安全嵌进 JS 源码的字符串字面量。
///
/// 用 `jsonEncode` 是故意的：JSON 的字符串语法是 JS 字符串语法的子集，
/// 引号、反斜杠、换行、控制字符全都转义好了。
///
/// 唯一的缺口是 **U+2028 / U+2029**——它们在 JSON 里是合法字符（不必转义），
/// 而 ES2019 之前它们在 JS 字符串字面量里是**行终止符**，嵌进去就是语法错误。
/// 现代引擎已经放开，但这段代码会跑在页面内核上，两行替换换一份安心。
String _jsStringLiteral(String value) => jsonEncode(value)
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');
