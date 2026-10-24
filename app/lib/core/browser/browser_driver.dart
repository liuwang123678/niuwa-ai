import 'dart:convert';
import 'dart:typed_data';

/// 驱动里出的事，[message] 是**直接说给模型听的话**。
///
/// 为什么要单独一个类型：驱动失败的原因五花八门（编号过期、页面超时、
/// 元素点不动），但模型需要的都是同一件事——一句人话。用这个类型当载体，
/// `_BrowserTool.withDriver` 就能把 [message] 原样翻成一次工具失败，
/// 不会走到 `ToolRegistry.invoke` 那个 `'${e.runtimeType}: $e'` 的兜底分支上去
/// （那条路会把 `BrowserException: ` 这个类名也塞给模型）。
class BrowserException implements Exception {
  const BrowserException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 滚动的四个方向。
enum ScrollDirection { up, down, top, bottom }

/// 把注入脚本的返回值解成 Map。解不出来返回 null。
///
/// **三段式，不是花哨，是因为不知道会拿到什么**（见 [BrowserSnapshot.fromScriptResult]）：
///
///   1. 直接 `jsonDecode`——CDP 那条路就是这种；
///   2. 解出来是个 String 就再解一层——Android 多裹一层引号时是这种；
///   3. 首尾有引号但没转义的，先剥引号再解——Pigeon 另一种可能的处理方式。
///
/// 三条都不成，返回 null，由调用方决定怎么退化。**不要在这里抛**：
/// 一个解析失败扛不住整轮对话。
Map<String, Object?>? decodeScriptPayload(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    decoded = null;
  }

  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      decoded = null;
    }
  }

  if (decoded == null && trimmed.length >= 2) {
    final first = trimmed[0];
    final last = trimmed[trimmed.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      final inner = trimmed.substring(1, trimmed.length - 1);
      try {
        decoded = jsonDecode(inner);
      } catch (_) {
        decoded = null;
      }
    }
  }

  if (decoded is Map) return decoded.cast<String, Object?>();
  return null;
}

/// 把平台层回传的**字符串标量**还原出来。
///
/// 安卓的 `runJavaScriptReturningResult` 把 JS 返回值按 JSON 编码往回带，所以
/// 一个 JS 字符串 `complete` 到手是 `"complete"`——**带引号**。不还原的话
/// `'$value' == 'complete'` 永远是假的，而症状是"页面好像永远加载不完"，
/// 你会去怀疑网络、怀疑超时、怀疑页面。
///
/// 和 [decodeScriptPayload] 的分工：那个是给对象用的（可能要解两层），这个只
/// 负责剥一层标量。解析不了就把原样还回去——**不抛**，让调用方自己判断。
String unwrapJsString(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is String) return decoded;
    } catch (_) {
      // 不是合法 JSON 就用原样。宁可让调用方拿到一句看不懂的，也别在这儿抛。
    }
  }
  return trimmed;
}

/// 把 `browser_snapshot` 里那个方括号编号解析成整数。
///
/// 早一步拦下来是有意义的：编号是本程序自己发出去的，非数字只可能是模型
/// 瞎编的。而且**它会被拼进 JS 源码**，不做解析就等于把模型的输出直接当
/// 代码执行。
int parseBrowserRef(String ref) {
  final parsed = int.tryParse(ref.trim());
  if (parsed == null) {
    throw BrowserException(
      '"$ref" 不是一个编号。编号是 browser_snapshot 里方括号里的数字，比如 3。',
    );
  }
  return parsed;
}

/// 检查 click / type / scroll 那几个脚本的执行状态，**没成功就抛**。
///
/// 两端共用一份：协议是同一个（脚本回 `{status: 'ok' | 'stale' | 'error'}`），
/// 各写一遍的话，改了一边另一边不会有人发现——而症状是"点了没反应"。
void ensureBrowserScriptOk(String raw) {
  final payload = decodeScriptPayload(raw);
  final status = '${payload?['status'] ?? ''}';

  switch (status) {
    case 'ok':
      return;
    case 'stale':
      throw const BrowserException(
        '这个编号已经失效了（页面变过）。重新 browser_snapshot 一次，用新的编号。',
      );
    case 'error':
      throw BrowserException('页面上没做成：${payload?['message'] ?? '原因不明'}');
    default:
      throw BrowserException('页面上没做成，它返回了看不懂的东西：$raw');
  }
}

/// 快照里一个可交互元素。
class BrowserNode {
  const BrowserNode({
    required this.ref,
    required this.role,
    required this.name,
    this.value,
  });

  /// 短编号（`1`、`2`…）。只在下一次快照之前有效，页面一变就作废。
  final String ref;

  /// `button` / `link` / `textbox` / `checkbox` / `select` / `text` …
  final String role;

  /// 可见文字或无障碍名。模型靠这个判断该点哪个。
  final String name;

  /// 输入框里的当前值。
  final String? value;

  String toLine() {
    final v = value == null || value!.isEmpty ? '' : ' (值: "$value")';
    return '[$ref] $role "$name"$v';
  }
}

/// 一次页面快照。
class BrowserSnapshot {
  const BrowserSnapshot({
    required this.url,
    required this.title,
    required this.nodes,
    required this.text,
    this.note = '',
  });

  final String url;
  final String title;
  final List<BrowserNode> nodes;

  /// 截图注记。目前只有一个用途：可交互元素太多被截断时，告诉模型
  /// "没找到的东西可能在下面"。**必须让模型看得见**——看不见它就会
  /// 对着不完整的快照反复重试同一个动作。
  final String note;

  /// 整页正文纯文本（已截断）。
  final String text;

  /// 从注入脚本的返回值建快照。**两端都走这一个入口。**
  ///
  /// 脚本返回的是一段 JSON 文本，但 Android 的 `runJavaScriptReturningResult`
  /// 走 Pigeon 过了一道，Dart 侧拿到的可能是三种东西里的任意一种：
  ///
  ///   * 真正的 JSON 文本：`{"url":...}`
  ///   * 被再包一层引号的：`"{\"url\":...}"`
  ///   * 带引号但没反转义的：`'{ "url": ... }'`
  ///
  /// 源码里看不出是哪种（`android_webview_controller.dart` 只管把原生返回值
  /// 交给 Pigeon），所以**不假设**，见 [decodeScriptPayload]。
  ///
  /// 解析不出结构时**不抛**，返回一个只剩正文的快照：让模型看到一坨看不懂的
  /// 东西，也比整轮对话炸掉强。
  static BrowserSnapshot fromScriptResult(String raw) {
    final map = decodeScriptPayload(raw);
    if (map == null) {
      return BrowserSnapshot(
        url: '',
        title: '',
        nodes: const [],
        text: raw.trim(),
      );
    }

    final nodes = <BrowserNode>[];
    final rawNodes = map['nodes'];
    if (rawNodes is List) {
      for (final item in rawNodes) {
        if (item is! Map) continue;
        final ref = item['ref'];
        if (ref == null) continue;
        final value = item['value'];
        nodes.add(
          BrowserNode(
            ref: '$ref',
            role: '${item['role'] ?? 'element'}',
            name: '${item['name'] ?? ''}',
            value: value == null ? null : '$value',
          ),
        );
      }
    }

    return BrowserSnapshot(
      url: '${map['url'] ?? ''}',
      title: '${map['title'] ?? ''}',
      nodes: nodes,
      text: '${map['text'] ?? ''}',
      note: '${map['note'] ?? ''}',
    );
  }

  /// 渲染成喂给模型的文本。
  ///
  /// **这个格式两端必须完全一致**——exe 走 CDP、APK 走 WebView 注入，
  /// 渲染不统一的话同一个技能在两端行为会不一样。所以渲染只在这里做一次。
  String toModelText({int maxTextChars = 4000}) {
    final buffer = StringBuffer()
      ..writeln('页面：$title')
      ..writeln('地址：$url');

    final hint = note.trim();
    if (hint.isNotEmpty) buffer.writeln(hint);

    if (nodes.isEmpty) {
      buffer.writeln('\n可交互元素：（无）');
    } else {
      buffer.writeln('\n可交互元素：');
      for (final n in nodes) {
        buffer.writeln(n.toLine());
      }
    }

    final body = text.trim();
    if (body.isNotEmpty) {
      buffer.writeln('\n正文：');
      buffer.writeln(
        body.length <= maxTextChars
            ? body
            : '${body.substring(0, maxTextChars)}\n…（正文过长已截断）',
      );
    }
    return buffer.toString().trimRight();
  }
}

/// 浏览器驱动。两端各一个实现，接口和快照格式统一。
///
/// - Windows：`CdpBrowserDriver` —— 连本机 Edge 的调试端口
/// - Android：`WebViewBrowserDriver` —— 驱动 App 里一个隐藏的 WebView
abstract class BrowserDriver {
  /// 显式声明一个 const 构造，**是为了让子类能写 `const XxxDriver(...)`**。
  /// 不写的话 Dart 给的是一个非 const 的隐式构造，子类的 const 构造会编译不过。
  const BrowserDriver();

  /// 这个平台当前能不能用。false 时浏览器相关工具不会被注册。
  ///
  /// 必须是**同步**的：唯一决定它的是 [warmUp] 那次异步探测的结果，而
  /// `newSession` 是同步方法，没法在那里 await。驱动内部持一个 `_ready` 标志，
  /// 由 [warmUp] 写、这里读。
  bool get isAvailable;

  /// 这个驱动所在的平台**有没有**浏览器能力——哪怕现在还冷着。
  ///
  /// [isAvailable] 回答的是"现在能不能用"，这个回答的是"预热之后能不能用"。
  /// 工具层拿它决定：先注册工具，等模型真要用浏览器时在工具里现预热。
  ///
  /// 为什么不干脆开机就预热：Windows 上预热 = 拉起一个**看得见的 Edge 窗口**，
  /// 于是每次打开 App 都平白无故弹一个 `about:blank` 出来，用户当场就问
  /// "这网页哪来的"。聊天不需要浏览器，不该为它付这个代价。
  ///
  /// 默认 false，平台实现按需覆盖——加这个成员不会逼任何现有子类改代码。
  bool get supportsWarmUp => false;

  /// 不可用时的原因，直接说给模型听。可用时是 null。
  ///
  /// 让驱动自己说比让工具层猜好：同一个 `isAvailable == false` 底下可能是
  /// "这个平台没这能力"，也可能是"Edge 被用户关掉了"，处理方式完全不同。
  /// 默认 null，实现类按需覆盖——所以加这个成员不会逼任何人改代码。
  String? get unavailableReason => null;

  /// 异步就绪。拉起浏览器、连上调试端口，完成后 [isAvailable] 才会变。
  ///
  /// **刻意是带默认实现的具体方法，不是抽象方法**：这样
  /// [UnavailableBrowserDriver] 和测试里的假驱动一行都不用改。
  ///
  /// 幂等——重复调用不能拉起第二个浏览器。
  Future<void> warmUp() async {}

  Future<void> open(String url);

  Future<BrowserSnapshot> snapshot();

  Future<void> click(String ref);

  Future<void> type(String ref, String text);

  /// 滚动。[scroll] 是技能里明确教模型做的事（"找不到就往下翻"），
  /// 但接口里一直没有——技能教了做不到的事。
  ///
  /// [amount] 是一屏的比例，1.0 = 正好一屏。
  Future<void> scroll(ScrollDirection direction, {double amount = 0.8});

  Future<Uint8List> screenshot();

  Future<void> back();

  Future<void> dispose();
}

/// 平台不支持浏览器时的空实现。注册进工具表会让模型以为能用，所以不注册。
///
/// **`extends` 不是 `implements`**：基类里 `warmUp` / `unavailableReason` 是带
/// 默认实现的具体成员，`implements` 会把它们当成待实现的接口成员，逼每个子类
/// 抄一遍空实现——那正是默认实现想省掉的东西。
class UnavailableBrowserDriver extends BrowserDriver {
  const UnavailableBrowserDriver(this.reason);

  final String reason;

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason => reason;

  Never _fail() => throw BrowserException(reason);

  @override
  Future<void> open(String url) async => _fail();

  @override
  Future<BrowserSnapshot> snapshot() async => _fail();

  @override
  Future<void> click(String ref) async => _fail();

  @override
  Future<void> type(String ref, String text) async => _fail();

  @override
  Future<void> scroll(ScrollDirection direction, {double amount = 0.8}) async =>
      _fail();

  @override
  Future<Uint8List> screenshot() async => _fail();

  @override
  Future<void> back() async => _fail();

  @override
  Future<void> dispose() async {}
}
