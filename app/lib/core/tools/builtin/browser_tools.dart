import 'dart:async';
import 'dart:convert';

import '../../browser/browser_driver.dart';
import '../n1_tool.dart';
import '../tool_context.dart';

/// 浏览器工具的公共基类。
///
/// 所有浏览器操作都经过 `ctx.browser`，驱动本身是平台注入的
/// （Windows 走 CDP 连 Edge，Android 走隐藏 WebView）。
abstract class _BrowserTool extends N1Tool {
  const _BrowserTool();

  /// 拿驱动执行。
  ///
  /// 这里要分开两种"用不了"，它们对模型的意义完全不同：
  ///
  /// 1. **驱动根本不可用**（`isAvailable == false`）——平台没这能力，
  ///    或者浏览器刚崩了。这时返回一句 `fail`，让模型换手段。
  /// 2. **驱动可用但这一次操作失败**——页面没加载出来、编号过期、
  ///    点了个不存在的元素。这时**抛出去**，由 `ToolRegistry` 翻成
  ///    "工具执行出错：<驱动说的话>"。
  ///
  /// 早先这两种都走第一句"当前平台不支持浏览器操作"——驱动明明活着，
  /// 只是页面慢了一拍，却告诉模型"这平台不行"。模型会**放弃浏览器改去
  /// http_fetch**，然后拿着抓不到 JS 内容的静态 HTML 硬撑。
  Future<ToolResult> withDriver(
    ToolContext ctx,
    Future<ToolResult> Function(BrowserDriver driver) body,
  ) async {
    final driver = ctx.browser;
    if (!driver.isAvailable && driver.supportsWarmUp) {
      // 冷启动推迟到**真要用浏览器**这一刻。开机预热的话，Windows 上会拉起
      // 一个看得见的 Edge 窗口，用户每次打开 App 都会撞见一个 about:blank。
      // warmUp 幂等、且承诺不抛；这里最多等它 0.5–2 秒。
      await driver.warmUp();
    }
    if (!driver.isAvailable) {
      return ToolResult.fail(
        driver.unavailableReason ??
            '浏览器现在用不了。可以改用 http_fetch 抓网页，或者如实告诉用户这件事做不到。',
      );
    }

    try {
      return await body(driver);
    } on BrowserException catch (e) {
      // **就地翻成失败结果，不要 rethrow。** 驱动说的话已经是给模型看的了，
      // 再抛出去会被 `ToolRegistry.invoke` 的兜底分支接住，而那里是
      // `'${e.runtimeType}: $e'`——模型会收到 `BrowserException: 页面加载超时了。`，
      // 前面挂一个它不认识的类名。失败就是失败，直接告诉它。
      return ToolResult.fail(e.message);
    } on ToolInputException {
      rethrow; // 参数写错，注册表会翻成"参数错误"
    } on TimeoutException {
      rethrow; // 注册表会翻成超时
    } catch (e) {
      // 兜底：别让模型看见 `WebSocketChannelException: ...` 这种它没法处理的东西。
      return ToolResult.fail('浏览器操作失败：$e');
    }
  }
}

class BrowserOpenTool extends _BrowserTool {
  const BrowserOpenTool();

  @override
  String get name => 'browser_open';

  @override
  String get description =>
      '打开一个网址。要点击、翻页，或者内容得靠 JS 渲染才出来的时候用它。'
      '打开后必须用 browser_snapshot 看页面内容，不要凭空猜页面上有什么。'
      '注意：开的是临时浏览器，没有用户的登录状态——需要登录的站点打不开，'
      '遇到就停下来告诉用户。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': '完整网址，要带 http:// 或 https://'},
    },
    'required': ['url'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final url = N1Tool.requireString(input, 'url');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw const ToolInputException('网址必须以 http:// 或 https:// 开头');
    }

    return withDriver(ctx, (driver) async {
      await driver.open(url);
      final snapshot = await driver.snapshot();
      return ToolResult.ok(
        '已打开。\n\n${snapshot.toModelText()}',
        meta: {'url': snapshot.url},
      );
    });
  }
}

class BrowserSnapshotTool extends _BrowserTool {
  const BrowserSnapshotTool();

  @override
  String get name => 'browser_snapshot';

  @override
  String get description =>
      '查看当前页面上有什么——标题、可交互元素（带编号）、正文。'
      '每次点击或输入之后页面都会变，必须重新 snapshot 拿到最新编号，'
      '不能拿旧的编号接着点。'
      '页面内嵌的 iframe（登录框、支付框、验证码常见位置）看不到，'
      '碰上就停下来问用户。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      withDriver(ctx, (driver) async {
        final snapshot = await driver.snapshot();
        return ToolResult.ok(
          snapshot.toModelText(),
          meta: {'url': snapshot.url},
        );
      });
}

class BrowserClickTool extends _BrowserTool {
  const BrowserClickTool();

  @override
  String get name => 'browser_click';

  @override
  String get description => '点击页面上的一个元素。ref 必须是最近一次 browser_snapshot 给出的编号。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'ref': {'type': 'string', 'description': '元素编号，如 "3"'},
    },
    'required': ['ref'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final ref = N1Tool.requireString(input, 'ref');
    return withDriver(ctx, (driver) async {
      await driver.click(ref);
      final snapshot = await driver.snapshot();
      return ToolResult.ok(
        '点完了。页面现在是：\n\n${snapshot.toModelText()}',
        meta: {'url': snapshot.url},
      );
    });
  }
}

class BrowserTypeTool extends _BrowserTool {
  const BrowserTypeTool();

  @override
  String get name => 'browser_type';

  @override
  String get description =>
      '往输入框里填字。ref 必须是最近一次 browser_snapshot 给出的编号。'
      '填完页面上的值就变了，返回值里带着新快照，不用再单独 snapshot 一次。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'ref': {'type': 'string', 'description': '输入框编号'},
      'text': {'type': 'string', 'description': '要填的内容'},
    },
    'required': ['ref', 'text'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final ref = N1Tool.requireString(input, 'ref');
    final text = N1Tool.requireString(input, 'text');
    return withDriver(ctx, (driver) async {
      await driver.type(ref, text);
      // **必须重拍快照**，跟 click / scroll / back 保持一致。
      //
      // 原来只回一句"已填入"，不重拍——后果是模型手上还是**填之前**的那份编号表。
      // 而填字往往会触发页面重绘（下拉建议、表单校验、"搜到了 N 条"），
      // 重绘之后旧编号可能指到完全不同的元素上。模型照着旧编号点提交，
      // 点到的是别的东西，而且它不知道自己点错了。
      final snapshot = await driver.snapshot();
      return ToolResult.ok(
        '已填入 "$text"。页面现在是：\n\n${snapshot.toModelText()}',
        meta: {'url': snapshot.url},
      );
    });
  }
}

class BrowserScrollTool extends _BrowserTool {
  const BrowserScrollTool();

  @override
  String get name => 'browser_scroll';

  @override
  String get description =>
      '滚动页面。要找的东西不在快照里，多半是在下面还没加载出来——先滚一屏再看。'
      'direction 取 down/up/top/bottom，默认 down。滚完会自动带上新快照。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'direction': {
        'type': 'string',
        'enum': ['down', 'up', 'top', 'bottom'],
        'description': '往哪滚，默认 down',
      },
    },
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    final direction = parseDirection(input['direction']);
    return withDriver(ctx, (driver) async {
      await driver.scroll(direction);
      // 滚动是为了让下面那一截加载出来，所以**滚完必须重拍**，否则模型
      // 看到的是同一份快照，会以为"滚了没用"然后放弃。
      final snapshot = await driver.snapshot();
      return ToolResult.ok(
        '滚完了。页面现在是：\n\n${snapshot.toModelText()}',
        meta: {'url': snapshot.url},
      );
    });
  }

  /// 缺省当 down——"滚一下"这个意图本身就有方向，模型漏填时往下是合理的默认。
  /// 但**填了别的词就报错**，不要猜：猜错方向它会以为页面没有那个东西。
  static ScrollDirection parseDirection(Object? raw) {
    final wanted = raw == null ? 'down' : '$raw'.trim().toLowerCase();
    for (final d in ScrollDirection.values) {
      if (d.name == wanted) return d;
    }
    throw ToolInputException(
      'direction 只能是 down / up / top / bottom，收到的是 "$raw"',
    );
  }
}

class BrowserScreenshotTool extends _BrowserTool {
  const BrowserScreenshotTool();

  @override
  String get name => 'browser_screenshot';

  @override
  String get description =>
      '给当前页面截个图，显示给用户看。用来确认某一步操作的效果。'
      '不是每个平台都支持——不支持时会明确告诉你，那就改用 browser_snapshot。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      withDriver(ctx, (driver) async {
        final bytes = await driver.screenshot();
        if (bytes.isEmpty) {
          // 这里**只能**说"没截到"。原来写的是"页面可能还没加载出来"——
          // 而把空字节交给工具层的真正原因往往是"这个平台没有截图 API"，
          // 那句话是在替驱动撒谎，还会让模型白等一轮重试。
          // 平台不支持时由驱动自己抛 BrowserException 说明，不走这条分支。
          return ToolResult.fail(
            '截图没截到内容。等页面画出来再试一次；一直这样就用 browser_snapshot 看结构。',
          );
        }
        return ToolResult.ok(
          '截图好了，已经显示给用户。',
          meta: {'image_base64': base64Encode(bytes), 'mime': 'image/png'},
        );
      });
}

class BrowserBackTool extends _BrowserTool {
  const BrowserBackTool();

  @override
  String get name => 'browser_back';

  @override
  String get description => '返回上一页。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      withDriver(ctx, (driver) async {
        await driver.back();
        final snapshot = await driver.snapshot();
        return ToolResult.ok(
          '退回来了。现在是：\n\n${snapshot.toModelText()}',
          meta: {'url': snapshot.url},
        );
      });
}

/// 把浏览器工具打包成一组。
///
/// 平台不支持时返回**空列表**——不注册比注册了再报错好，模型看不到工具就不会反复去试。
List<N1Tool> browserTools({required bool available}) {
  if (!available) return const [];
  return const [
    BrowserOpenTool(),
    BrowserSnapshotTool(),
    BrowserClickTool(),
    BrowserTypeTool(),
    BrowserScrollTool(),
    BrowserScreenshotTool(),
    BrowserBackTool(),
  ];
}
