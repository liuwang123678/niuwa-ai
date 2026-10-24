import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import 'llm_client.dart';
import 'providers.dart';

/// OpenAI 兼容接口（`POST {base_url}/chat/completions`）的客户端。
///
/// 接哪家由构造时的 [baseUrl] 和 [model] 决定，见 `providers.dart` 里的预置表。
/// 国内主流几家、以及本机跑的 Ollama，走的都是这一套字段，所以一个客户端够用。
///
/// ## 协议细节都是实测过的
///
/// 探针在 `D:\temp\n1-probe\`，结论记在 `docs/architecture.md`：
/// - 流式 tool_call 是**碎片**：首块带 id 和 name，后续只有 arguments 字符串碎片
/// - `finish_reason` 回 `tool_calls`
/// - `image_url` 收 base64 data URL
/// - 思考过程单独推一个字段（名字各家不一样，见下面 [_reasoningOf]）
///
/// ## 只认一家的字段会出什么问题
///
/// 同一件事各家起名不同：思考过程有的叫 `reasoning_content`、有的叫
/// `reasoning`；缓存命中数有的塞在顶层 `prompt_cache_hit_tokens`、有的埋在
/// `prompt_tokens_details.cached_tokens`。只读其中一个的话，接别家时**不报错**，
/// 只是那些功能静静消失——用户只会觉得"怎么没反应了"。
class OpenAiCompatClient implements LlmClient {
  OpenAiCompatClient({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.temperature,
    this.maxTokens,
    this.maxRetries = 2,
    Future<void> Function(int attempt)? retryDelay,
    http.Client Function()? clientFactory,
  }) : _retryDelay = retryDelay ?? _defaultRetryDelay,
       _clientFactory = clientFactory ?? http.Client.new;

  final String apiKey;
  final String baseUrl;

  @override
  final String model;

  final double? temperature;
  final int? maxTokens;

  /// 遇到 429、5xx、连不上时最多自动重试几次。
  ///
  /// 只重试**还没往外吐过任何一块**的请求。已经吐了正文再整轮重来，用户会
  /// 看到同一段话出现两遍——那比重试失败更糟。所以中途断流不重试，交给上层
  /// 标 `incomplete`。
  ///
  /// 重试不额外收钱：失败的请求不会产生 token 账单，反过来 429 本来就是在说
  /// "你太快了"，干等着才更容易被用户当成卡死。
  final int maxRetries;

  final Future<void> Function(int attempt) _retryDelay;

  /// 第一次等 500ms，第二次 1s。真撞上 429 时上游通常几秒内就恢复了。
  static Future<void> _defaultRetryDelay(int attempt) =>
      Future<void>.delayed(Duration(milliseconds: 500 * (1 << attempt)));

  /// 每次请求开一个新 client：取消订阅时直接 `close()` 就能真的把连接掐掉，
  /// 又不会连累别的并发请求。
  final http.Client Function() _clientFactory;

  Uri get _endpoint => Uri.parse(chatCompletionsUrl(baseUrl));

  @override
  Stream<LlmChunk> stream(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
  }) async* {
    final endpoint = _endpoint;
    // 地址没填就现在说清楚。让它走到 http 层去，报出来的会是
    // "无效的 URL" 之类，看不出是"设置里少填了一栏"。
    if (!endpoint.hasScheme || endpoint.host.isEmpty) {
      throw const LlmException('还没填接口地址，去设置里补一下。');
    }

    // 请求体只编一次：重试时原样再发，不重新序列化。
    final body = jsonEncode(_buildBody(messages, tools));
    final hadImages = messages.any((m) => m.images.isNotEmpty);

    for (var attempt = 0; ; attempt++) {
      final client = _clientFactory();
      // 已经吐出去的块不能再收回来，所以重试只在 `emitted == false` 时开。
      var emitted = false;
      try {
        final request = http.Request('POST', endpoint)
          ..headers.addAll({
            'Content-Type': 'application/json; charset=utf-8',
            // 本机 Ollama 不需要 Key，但带着一个空的 Bearer 也能跑；
            // 空串就干脆不发这个头，免得某些网关把空 Authorization 当鉴权失败。
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            'Accept': 'text/event-stream',
          })
          ..body = body;

        final response = await client.send(request);

        if (response.statusCode != 200) {
          final errorBody = await response.stream.bytesToString();
          final message = _humanizeError(
            response.statusCode,
            errorBody,
            // 这次请求里有没有图，决定了 400 类的错误该往哪边解释。
            hadImages: hadImages,
          );

          // 429 和 5xx 是"等一会儿可能就好了"；其余 4xx 是配置问题，
          // 重试只会让用户多等几秒，然后看到同一句话。
          if (_retryableStatus(response.statusCode) && attempt < maxRetries) {
            await _retryDelay(attempt);
            continue;
          }

          throw LlmException(
            attempt == 0 ? message : '$message（已重试 $attempt 次）',
            statusCode: response.statusCode,
            body: errorBody,
          );
        }

        // LineSplitter 会自己缓冲半行；utf8.decoder 会自己缓冲半个多字节字符。
        // 中文流式不会断字，就是因为这两层。
        final lines = response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());

        String? finishReason;

        await for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

          final payload = trimmed.substring(5).trim();
          if (payload == '[DONE]') {
            emitted = true;
            yield DoneChunk(finishReason);
            return;
          }

          final Map<String, Object?> event;
          try {
            event = jsonDecode(payload) as Map<String, Object?>;
          } on FormatException {
            continue; // 单块脏数据不值得把整轮打断
          }

          if (event['error'] != null) {
            throw LlmException(_readErrorField(event['error']));
          }

          final usage = event['usage'];
          if (usage is Map<String, Object?>) {
            emitted = true;
            yield UsageChunk(
              promptTokens: _int(usage['prompt_tokens']),
              completionTokens: _int(usage['completion_tokens']),
              cachedTokens: _cachedTokensOf(usage),
            );
          }

          final choices = event['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final choice = choices.first;
          if (choice is! Map<String, Object?>) continue;

          if (choice['finish_reason'] is String) {
            finishReason = choice['finish_reason'] as String;
          }

          final delta = choice['delta'];
          if (delta is! Map<String, Object?>) continue;

          final reasoning = _reasoningOf(delta);
          if (reasoning != null && reasoning.isNotEmpty) {
            emitted = true;
            yield ReasoningChunk(reasoning);
          }

          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            emitted = true;
            yield TextChunk(content);
          }

          final calls = delta['tool_calls'];
          if (calls is List) {
            for (final raw in calls) {
              if (raw is! Map<String, Object?>) continue;
              final fn = raw['function'];
              emitted = true;
              yield ToolCallChunk(
                index: _int(raw['index']),
                id: raw['id'] as String?,
                name: fn is Map<String, Object?> ? fn['name'] as String? : null,
                argumentsFragment: fn is Map<String, Object?>
                    ? fn['arguments'] as String?
                    : null,
              );
            }
          }
        }

        // 没等到 [DONE] 就断了。不抛错，把已有的内容交出去，标个原因。
        // 这时候不重试：前半段已经交给界面了，重来会看到同一段话两遍。
        emitted = true;
        yield DoneChunk(finishReason ?? 'incomplete');
        return;
      } on LlmException {
        rethrow;
      } catch (e) {
        // http 包把底层的 socket 错误统一包成 ClientException。
        // 别的异常（比如解析炸了）是真 bug，重试只会把同一个 bug 演两遍。
        if (!_isConnectionError(e)) rethrow;
        if (!emitted && attempt < maxRetries) {
          await _retryDelay(attempt);
          continue;
        }
        throw LlmException(
          '连不上模型服务'
          '${attempt == 0 ? '' : '（已重试 $attempt 次）'}：$e',
        );
      } finally {
        client.close();
      }
    }
  }

  /// 值得重试的状态码：限流和服务端故障。4xx 的其余都是"再问一遍也一样"。
  static bool _retryableStatus(int status) => status == 429 || status >= 500;

  static bool _isConnectionError(Object e) =>
      e is http.ClientException || e is TimeoutException;

  /// 思考过程。`reasoning_content` 是常见写法，`reasoning` 是另一派。
  /// 两个都不是字符串就当作这家不推思考过程。
  static String? _reasoningOf(Map<String, Object?> delta) {
    final a = delta['reasoning_content'];
    if (a is String) return a;
    final b = delta['reasoning'];
    if (b is String) return b;
    return null;
  }

  /// 缓存命中的 token 数。顶层和 `prompt_tokens_details` 里各找一次。
  /// 两家都不给就回 0——这个数只用于界面展示，缺了不影响对话。
  static int _cachedTokensOf(Map<String, Object?> usage) {
    final flat = usage['prompt_cache_hit_tokens'];
    if (flat is num) return flat.toInt();

    final details = usage['prompt_tokens_details'];
    if (details is Map<String, Object?>) {
      final nested = details['cached_tokens'];
      if (nested is num) return nested.toInt();
    }
    return 0;
  }

  Map<String, Object?> _buildBody(
    List<ChatMessage> messages,
    List<ToolSpec> tools,
  ) => {
    'model': model,
    'messages': messages.map((m) => m.toWire()).toList(),
    'stream': true,
    if (tools.isNotEmpty) 'tools': tools.map((t) => t.toWire()).toList(),
    if (temperature != null) 'temperature': temperature,
    if (maxTokens != null) 'max_tokens': maxTokens,
  };

  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  static String _readErrorField(Object? error) {
    if (error is Map<String, Object?>) {
      final msg = error['message'];
      if (msg is String) return msg;
    }
    return error.toString();
  }

  /// 走不通时给一句人话。
  ///
  /// [hadImages] 表示这一次请求里带着图。它只影响**几个特定的 4xx**——
  /// 见下面那段。带上它是因为用户手里真可能配了个纯文本模型（这个 App 的
  /// 卖点就是"不绑任何一家模型"），而那种情况下上游回的是一句英文的
  /// "invalid content"，指不到"换个模型"这个动作上。
  static String _humanizeError(int status, String body, {bool hadImages = false}) {
    String? detail;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        detail = _readErrorField(decoded['error']);
      }
    } on FormatException {
      detail = null;
    }

    final suffix = detail == null ? '' : '：$detail';

    // 只有这几个状态码能往"模型不看图"上靠：
    //   400 笼统的请求不合法   415 不支持的媒体类型
    //   413 载荷太大（图太大）  422 内容无法处理
    //
    // **401/403/402/404/429/5xx 一律不靠**：那些是 Key、余额、地址、限流、
    // 服务端的问题，跟有没有图无关。带图时把它们也说成"模型不看图"，
    // 是让用户白折腾一场——那种失败最伤人。
    const imageCodes = {400, 413, 415, 422};
    if (hadImages && imageCodes.contains(status)) {
      return '这个模型可能不支持图片，或者这张图太大了。'
          '去设置里换一个能看图的试试$suffix';
    }

    return switch (status) {
      401 || 403 => 'API Key 不对或没权限，去设置里检查一下$suffix',
      402 => '账户余额不足了$suffix',
      // 2026-10-10：这句改过。原来是"去设置里对一下这两栏"，但用户实际撞到的
      // 十有八九**不是地址写错了，是模型名退役了**——平台回的是 404
      // 「模型不存在」，而它看起来特别像网络故障或者 Key 不对，人会往错的方向查。
      // 现在直接把设置页里那个动作指出来。
      404 => '地址或模型名不对（HTTP 404）$suffix。'
          '最可能是模型名过期了——去设置里点「拉取模型列表」，'
          '挑一个现在还在的名字，顺便对一下地址。',
      429 => '请求太频繁，等一下再试$suffix',
      >= 500 => '模型服务端出错了（$status），过会儿再试$suffix',
      _ => '请求失败（HTTP $status）$suffix',
    };
  }
}
