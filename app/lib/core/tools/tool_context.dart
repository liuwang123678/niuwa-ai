import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../browser/browser_driver.dart';
import '../memory/memory_store.dart';
import '../reminder/reminder_store.dart';
import '../skills/skill_registry.dart';
import '../todo/todo_list.dart';
import 'tool_approval.dart';

/// `ToolContext.fetch` 的返回。
class HttpFetchResult {
  const HttpFetchResult({
    required this.statusCode,
    required this.body,
    this.contentType,
    this.truncated = false,
    this.garbled = false,
  });

  final int statusCode;
  final String body;
  final String? contentType;
  final bool truncated;

  /// 解码出来是乱码（页面多半是 GBK）。工具要如实告诉模型，别让它拿乱码去分析。
  final bool garbled;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// 工具运行时的依赖集合。
///
/// 工具只通过这里拿外部能力，不自己 new 任何东西——测试里塞假的就能跑，
/// 也不用担心哪个工具偷偷发了个网络请求。
class ToolContext {
  ToolContext({
    required this.memory,
    required this.skills,
    required this.browser,
    required this.reminders,
    this.approver,
    TodoList? todos,
    http.Client? httpClient,
    this.defaultTimeout = const Duration(seconds: 30),
    void Function(String message)? logger,
  }) : todos = todos ?? TodoList(),
       _http = httpClient ?? http.Client(),
       // 用具名参数没法写 `this._logger`（私有名字不能做具名参数），
       // 所以这里只能手写赋值，linter 的建议在此不适用。
       // ignore: prefer_initializing_formals
       _logger = logger;

  final MemoryStore memory;
  final SkillRegistry skills;
  final BrowserDriver browser;

  /// 提醒存储。`reminder_*` 工具靠它读写。
  final ReminderStore reminders;

  /// 这次会话的任务清单。`todo_write` 写它，界面读它。
  final TodoList todos;

  /// 需要审批时怎么问用户。界面层注入，内核不关心它长什么样。
  ///
  /// ⚠️ **null 不是"不用问"，是"没法问"。** `ToolRegistry.invoke` 拿到 null 时
  /// 按**拒绝**处理（`unavailable`）。改成"放行"的话，任何忘了接审批界面的环境
  /// ——新平台、命令行工具、某个漏了这条参数的测试——都会**静默执行危险操作**，
  /// 而且完全看不出来。宁可当场失败。
  final ToolApprover? approver;

  final Duration defaultTimeout;

  final http.Client _http;
  final void Function(String message)? _logger;

  void log(String message) => _logger?.call(message);

  /// 抓一个 URL 的原始内容。
  ///
  /// 故意不做 HTML 转文本——那是 `http_fetch` 工具的事。这里只管"拿到字节"，
  /// 以后别的工具（比如下载）能直接复用。
  Future<HttpFetchResult> fetch(
    String url, {
    int maxBytes = 512 * 1024,
    Duration? timeout,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw ArgumentError('URL 不合法：$url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('只支持 http/https，收到的是 ${uri.scheme}');
    }

    final request = http.Request('GET', uri)
      ..headers.addAll({
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      })
      ..followRedirects = true;

    final client = _http;
    final response = await client
        .send(request)
        .timeout(timeout ?? defaultTimeout);

    final bytes = <int>[];
    var truncated = false;
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) {
        truncated = true;
        break;
      }
    }

    // 网页编码不做自动识别。
    //
    // dart:convert 只有 utf8 / latin1 / ascii，GBK 要自己带码表（太重，不引）。
    // 所以策略是：一律按 UTF-8 解，坏字节变成 U+FFFD。如果坏字节多到离谱，
    // 说明这页是 GBK，**如实标出来**——让模型知道内容不可信、改用浏览器抓，
    // 而不是塞一堆乱码让它瞎猜。
    final contentType = response.headers['content-type'];
    final text = utf8.decode(bytes, allowMalformed: true);
    final garbled = _looksGarbled(text, bytes.length);

    return HttpFetchResult(
      statusCode: response.statusCode,
      body: text,
      contentType: contentType,
      truncated: truncated,
      garbled: garbled,
    );
  }

  /// 派生一个上下文：共享记忆、技能、浏览器、提醒和 **HTTP 连接**，但可以
  /// 换一条审批通道。
  ///
  /// 子代理用它——它跑在同一台机器上、读同一批文件，唯独"能不能问用户"
  /// 这件事必须跟主对话不一样（它背对着用户，弹窗没人点）。
  ///
  /// ⚠️ **派生出来的不要 dispose**：HTTP 连接是共用的，关掉会把主对话
  /// 正在跑的请求一起掐断。
  ToolContext fork({ToolApprover? approver}) => ToolContext(
    memory: memory,
    skills: skills,
    browser: browser,
    reminders: reminders,
    todos: todos,
    approver: approver ?? this.approver,
    httpClient: _http,
    defaultTimeout: defaultTimeout,
    logger: _logger,
  );

  void dispose() => _http.close();

  /// 替换字符占比超过 2% 就当解码失败。正常页面里 U+FFFD 几乎不会出现。
  static bool _looksGarbled(String text, int byteLength) {
    if (byteLength == 0) return false;
    var bad = 0;
    for (final rune in text.runes) {
      if (rune == 0xFFFD) bad++;
    }
    return bad > 0 && bad / text.length > 0.02;
  }
}
