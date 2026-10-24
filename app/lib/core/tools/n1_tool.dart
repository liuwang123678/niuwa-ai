import '../llm/llm_client.dart';
import '../util/clip.dart';
import 'tool_context.dart';

/// 工具执行结果。
class ToolResult {
  const ToolResult({required this.ok, required this.content, this.meta});

  const ToolResult.ok(String content, {Map<String, Object?>? meta})
    : this(ok: true, content: content, meta: meta);

  const ToolResult.fail(String content) : this(ok: false, content: content);

  final bool ok;

  /// 回给模型的文本。写清楚、具体，模型全靠它判断下一步。
  final String content;

  /// 给界面用的附加信息（截图、结构化数据等），**不进模型上下文**。
  final Map<String, Object?>? meta;

  /// 失败时 [toModelText] 加的前缀。
  ///
  /// 提成常量是因为**重建历史时要靠它把 ok 认回来**：库里存的只有
  /// [toModelText] 的结果，没存 ok。见 `ChatProvider` 里的重建逻辑。
  static const String failurePrefix = '工具执行失败：';

  /// 回填进对话的文本。失败要显式标明，否则模型会以为成功了接着往下做。
  String toModelText() => ok ? content : '$failurePrefix$content';

  /// 内容截到 [limit] 个字，超出就**明说**截了。
  ///
  /// 由工作强度（`WorkLevel.toolResultChars`）驱动，在 `ToolRegistry.invoke`
  /// 那一个收口处调用——那里是**所有**工具结果的必经之路，也是回喂给模型的
  /// 那一刻。放进各个工具里做的话，以后新加一个工具忘了截，症状是账单突然
  /// 涨一截，而没有任何地方报错。
  ///
  /// ## 为什么必须写明"被截了"
  ///
  /// 不写的话模型会把半截内容当成全部，然后拿它下结论——那比看不到更糟，
  /// 因为它还会很自信。说明里还得写清**怎么拿全**：不然它会拿同一句话原样
  /// 重试同一个调用，把回合全烧在撞同一面墙上。
  ToolResult limitedTo(int limit) {
    if (limit <= 0 || content.length <= limit) return this;

    // 别从半个代理对中间切开——见 `clipAtCodeUnit` 上的说明。
    final head = clipAtCodeUnit(content, limit);
    final cut = head.length;

    final note =
        '\n\n（这条结果一共 ${content.length} 字，'
        '按当前的工作强度只回喂了前 $cut 字。'
        '要拿全就缩小范围再查一次——读文件指定行范围、命令加过滤、'
        '别原样重试同一个调用。）';
    return ToolResult(ok: ok, content: '$head$note', meta: meta);
  }

  /// [toModelText] 的逆运算。**只对得上本文件写出去的东西。**
  ///
  /// 已知的不精确：万一某个工具的**成功**内容本身就以「工具执行失败：」开头，
  /// 它会被认成失败。写出去的时候无条件加了前缀，而前缀和内容之间没有分隔
  /// 标记，收回来就分不清了。没有工具会这么写内容；真写了，那是它自己的问题。
  factory ToolResult.fromModelText(String text) {
    if (text.startsWith(failurePrefix)) {
      return ToolResult.fail(text.substring(failurePrefix.length));
    }
    return ToolResult.ok(text);
  }
}

/// 参数不对。工具内部抛这个，比每处返回 fail 省事。
class ToolInputException implements Exception {
  const ToolInputException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 一个可被模型调用的工具。
abstract class N1Tool {
  /// 声明成 const：绝大多数工具是无状态的，注册表里直接 `const XxxTool()` 就好。
  const N1Tool();

  /// 给模型看的名字。蛇形，别带空格。
  String get name;

  /// **写给模型看的说明，重点写"什么时候用"。** 这段直接进 system prompt。
  String get description;

  /// 参数的 JSON Schema。
  Map<String, Object?> get inputSchema;

  /// 执行前要不要弹窗问用户。涉及钱、删除、提交表单的设 true。
  bool get requiresApproval => false;

  /// 这次调用要不要先问用户。返回 null = 不用问。
  ///
  /// 为什么要一个方法而不是一个 `bool` 字段：**危不危险看参数才知道**。
  /// `python 算个数` 和 `del /s /q` 在工具表里是同一个 `run_command`，
  /// 一个静态的 true/false 表达不了这件事，只会在"总问"和"总不问"之间二选一。
  ///
  /// ⚠️ **这是"手滑拦截 + 知情同意"的触发器，不是安全边界。** 名字里
  /// 带"危险"的东西挡不住混淆（`d^el`、变量拼接）、编码、或者先写个脚本再跑。
  /// 真正的边界是那套组合：展示原样操作 + 用户能拒 + 超时杀进程 + 审计日志 +
  /// 总开关 + 绝不提权。别把它当成"安全防护"来宣传。
  ///
  /// 默认实现让已有的 [requiresApproval] 立刻有了语义——原来它是个死钩子，
  /// 三处声明零个读取方（见提交 `a8fc58c`）。判定发生在
  /// `ToolRegistry.invoke`，拒绝会变成一次普通的失败结果。
  String? approvalReason(Map<String, Object?> input) =>
      requiresApproval ? '这个操作需要你确认一下。' : null;

  /// 这次调用要不要进审计日志。
  ///
  /// 默认 false：常驻的那批（看时间、抓网页、记忆、提醒）**不碰用户的电脑**，
  /// 记进去只会把真正要紧的那几条淹掉，用户翻日志时更找不到东西。
  ///
  /// 开在 `_CodeTool` / `_FileTool` 两个基类上，而不是逐个工具上——
  /// 以后加 `delete_file` 之类的，走同一个基类就自动被审到，不会漏。
  bool get audited => false;

  /// 这次调用能不能和同一批里的其它调用**同时**跑。
  ///
  /// 默认 false。只有同时满足三条的才置 true：
  ///
  ///   1. **只读**：不写文件、不写记忆、不点页面；
  ///   2. **不共享可变状态**：比如浏览器驱动里"当前是哪一页"；
  ///   3. **不需要审批**：弹窗不能同时弹两个。
  ///
  /// 不满足就串行。串行的代价是多等一会儿，并行的代价是两个操作互相踩掉，
  /// 而后者查起来难得多。
  bool get runsInParallel => false;

  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx);

  ToolSpec get spec =>
      ToolSpec(name: name, description: description, parameters: inputSchema);

  // ---- 参数取值helper：缺参数就抛，别让工具里到处写 if ----

  static String requireString(Map<String, Object?> input, String key) {
    final v = input[key];
    if (v is! String || v.trim().isEmpty) {
      throw ToolInputException('缺少必填参数 `$key`');
    }
    return v.trim();
  }

  static String? optionalString(Map<String, Object?> input, String key) {
    final v = input[key];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  static int optionalInt(
    Map<String, Object?> input,
    String key, {
    required int fallback,
  }) {
    final v = input[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }
}
