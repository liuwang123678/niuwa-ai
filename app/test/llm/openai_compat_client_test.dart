import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 把若干段字节按顺序吐出去，模拟真实网络的分块。
http.Client _chunkedClient(List<List<int>> chunks, {void Function(http.BaseRequest)? onRequest}) {
  return MockClient.streaming((request, _) async {
    onRequest?.call(request);
    return http.StreamedResponse(Stream.fromIterable(chunks), 200);
  });
}

/// 把 SSE 事件编成字节流。
List<List<int>> _sseChunks(List<String> events) => [
  utf8.encode(events.map((e) => 'data: $e\n\n').join()),
];

http.Client _errorClient(int status, String body) => MockClient.streaming(
  (_, _) async => http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    status,
  ),
);

/// 测试默认用一个中立的假地址，不绑任何一家——这个客户端本来就不属于某一家。
const String _testBaseUrl = 'https://api.example.com/v1';

OpenAiCompatClient _client(http.Client c) => OpenAiCompatClient(
  apiKey: 'test-key',
  baseUrl: _testBaseUrl,
  model: 'test-model',
  clientFactory: () => c,
);

void main() {
  group('流式解析', () {
    test('正文增量按顺序拼出来', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"role":"assistant","content":"你好"},"finish_reason":null}]}',
            '{"choices":[{"delta":{"content":"，世界"},"finish_reason":null}]}',
            '{"choices":[{"delta":{"content":""},"finish_reason":"stop"}]}',
            '[DONE]',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        chunks.whereType<TextChunk>().map((c) => c.text).join(),
        '你好，世界',
      );
      expect(chunks.whereType<DoneChunk>().single.finishReason, 'stop');
    });

    test('reasoning_content 走独立通道', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"content":null,"reasoning_content":"让我"},"finish_reason":null}]}',
            '{"choices":[{"delta":{"content":null,"reasoning_content":"想想"},"finish_reason":null}]}',
            '{"choices":[{"delta":{"content":"答案"},"finish_reason":"stop"}]}',
            '[DONE]',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        chunks.whereType<ReasoningChunk>().map((c) => c.text).join(),
        '让我想想',
      );
      expect(
        chunks.whereType<TextChunk>().map((c) => c.text).join(),
        '答案',
      );
    });

    test('叫 reasoning 的那一派也认（换供应商时思考过程不会静静消失）', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"content":null,"reasoning":"琢磨"},"finish_reason":null}]}',
            '{"choices":[{"delta":{"content":"好了"},"finish_reason":"stop"}]}',
            '[DONE]',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        chunks.whereType<ReasoningChunk>().map((c) => c.text).join(),
        '琢磨',
      );
    });

    test('工具调用碎片原样吐出，由上层负责拼接', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}',
            '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"ci"}}]},"finish_reason":null}]}',
            '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\\":\\"北京\\"}"}}]},"finish_reason":null}]}',
            '{"choices":[{"delta":{"content":""},"finish_reason":"tool_calls"}]}',
            '[DONE]',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('天气')]).toList();
      final calls = chunks.whereType<ToolCallChunk>().toList();

      expect(calls.first.id, 'call_1');
      expect(calls.first.name, 'get_weather');
      expect(
        calls.map((c) => c.argumentsFragment ?? '').join(),
        '{"city":"北京"}',
      );
      expect(chunks.whereType<DoneChunk>().single.finishReason, 'tool_calls');
    });

    test('中文字符被切在两个网络分块之间也不会乱码', () async {
      final whole = utf8.encode(
        'data: {"choices":[{"delta":{"content":"牛蛙很好"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      );

      // 从中间劈开，正好劈在多字节字符中间
      final cut = whole.length ~/ 2;
      final client = _client(
        _chunkedClient([whole.sublist(0, cut), whole.sublist(cut)]),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        chunks.whereType<TextChunk>().map((c) => c.text).join(),
        '牛蛙很好',
      );
    });

    test('usage 里的缓存命中数能读出来（顶层那种写法）', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_cache_hit_tokens":64}}',
            '[DONE]',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();
      final usage = chunks.whereType<UsageChunk>().single;

      expect(usage.promptTokens, 100);
      expect(usage.cachedTokens, 64);
    });

    test('缓存命中数埋在 prompt_tokens_details 里也读得出来（另一派写法）', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":32}}}',
            '[DONE]',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(chunks.whereType<UsageChunk>().single.cachedTokens, 32);
    });

    test('一家都不给缓存数时是 0，不是崩', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}',
            '[DONE]',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(chunks.whereType<UsageChunk>().single.cachedTokens, 0);
    });

    test('没等到 [DONE] 就断流时，已有内容照样交出', () async {
      final client = _client(
        _chunkedClient(
          _sseChunks([
            '{"choices":[{"delta":{"content":"说了一半"},"finish_reason":null}]}',
          ]),
        ),
      );

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        chunks.whereType<TextChunk>().map((c) => c.text).join(),
        '说了一半',
      );
      expect(chunks.whereType<DoneChunk>().single.finishReason, 'incomplete');
    });
  });

  group('请求构造', () {
    test('地址是 base + /chat/completions，带上鉴权和流式标记', () async {
      late http.BaseRequest captured;
      final client = _client(
        _chunkedClient(_sseChunks(['[DONE]']), onRequest: (r) => captured = r),
      );

      await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        captured.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(captured.headers['Authorization'], 'Bearer test-key');
      expect(captured.headers['Accept'], contains('event-stream'));
    });

    test('base 末尾多带斜杠也拼得对（从地址栏复制的常见形态）', () async {
      late http.BaseRequest captured;
      final client = OpenAiCompatClient(
        apiKey: 'k',
        baseUrl: 'https://api.example.com/v1/',
        model: 'm',
        clientFactory: () =>
            _chunkedClient(_sseChunks(['[DONE]']), onRequest: (r) => captured = r),
      );

      await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        captured.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('整条接口地址粘进来也认（不再往后拼一段）', () async {
      late http.BaseRequest captured;
      final client = OpenAiCompatClient(
        apiKey: 'k',
        baseUrl: 'https://api.example.com/v1/chat/completions',
        model: 'm',
        clientFactory: () =>
            _chunkedClient(_sseChunks(['[DONE]']), onRequest: (r) => captured = r),
      );

      await client.stream([ChatMessage.user('hi')]).toList();

      expect(
        captured.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('本机服务不需要 Key 时不发空的 Authorization 头', () async {
      late http.BaseRequest captured;
      final client = OpenAiCompatClient(
        apiKey: '',
        baseUrl: 'http://localhost:11434/v1',
        model: 'm',
        clientFactory: () =>
            _chunkedClient(_sseChunks(['[DONE]']), onRequest: (r) => captured = r),
      );

      await client.stream([ChatMessage.user('hi')]).toList();

      expect(captured.headers.containsKey('Authorization'), isFalse);
    });

    test('地址空的当场报"还没填接口地址"，而不是走到网络层再报个看不懂的', () async {
      final client = OpenAiCompatClient(
        apiKey: 'k',
        baseUrl: '',
        model: 'm',
        clientFactory: () => _chunkedClient(_sseChunks(['[DONE]'])),
      );

      await expectLater(
        client.stream([ChatMessage.user('hi')]).toList(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('接口地址'),
          ),
        ),
      );
    });

    test('有工具时带 tools，没工具时不带', () async {
      Map<String, Object?>? sentBody;

      http.Client build() => MockClient.streaming((request, bodyStream) async {
        final raw = await bodyStream.bytesToString();
        sentBody = jsonDecode(raw) as Map<String, Object?>;
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: [DONE]\n\n')),
          200,
        );
      });

      await OpenAiCompatClient(
        apiKey: 'k',
        baseUrl: _testBaseUrl,
        model: 'm',
        clientFactory: build,
      ).stream([ChatMessage.user('hi')]).toList();
      expect(sentBody!.containsKey('tools'), isFalse);

      await OpenAiCompatClient(
        apiKey: 'k',
        baseUrl: _testBaseUrl,
        model: 'm',
        clientFactory: build,
      ).stream(
        [ChatMessage.user('hi')],
        tools: const [
          ToolSpec(
            name: 't',
            description: 'd',
            parameters: {'type': 'object', 'properties': {}},
          ),
        ],
      ).toList();
      expect((sentBody!['tools'] as List).length, 1);
    });

    test('请求体里的模型名就是传进来的那个', () async {
      Map<String, Object?>? sentBody;
      final c = MockClient.streaming((request, bodyStream) async {
        sentBody =
            jsonDecode(await bodyStream.bytesToString()) as Map<String, Object?>;
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: [DONE]\n\n')),
          200,
        );
      });

      await OpenAiCompatClient(
        apiKey: 'k',
        baseUrl: _testBaseUrl,
        model: '某家的-特别版',
        clientFactory: () => c,
      ).stream([ChatMessage.user('hi')]).toList();

      expect(sentBody!['model'], '某家的-特别版');
    });

    test('reasoning 绝不回传给接口', () async {
      Map<String, Object?>? sentBody;
      final c = MockClient.streaming((request, bodyStream) async {
        sentBody =
            jsonDecode(await bodyStream.bytesToString()) as Map<String, Object?>;
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: [DONE]\n\n')),
          200,
        );
      });

      await OpenAiCompatClient(
        apiKey: 'k',
        baseUrl: _testBaseUrl,
        model: 'm',
        clientFactory: () => c,
      ).stream([
        ChatMessage.assistant('答案', reasoning: '我的思考过程'),
      ]).toList();

      final messages = sentBody!['messages'] as List;
      expect(messages.single.toString(), isNot(contains('我的思考过程')));
    });
  });

  group('错误处理', () {
    test('401 翻译成"key 不对"', () async {
      final client = _client(
        _errorClient(401, '{"error":{"message":"Authentication Fails"}}'),
      );

      await expectLater(
        client.stream([ChatMessage.user('hi')]).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.message, 'message', contains('API Key'))
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('402 余额不足', () async {
      final client = _client(_errorClient(402, '{"error":{"message":"Insufficient Balance"}}'));

      await expectLater(
        client.stream([ChatMessage.user('hi')]).toList(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('余额'),
          ),
        ),
      );
    });

    test('404 说清是地址或模型名不对（换供应商后最常见的失败）', () async {
      final client = _client(
        _errorClient(404, '{"error":{"message":"model not found"}}'),
      );

      await expectLater(
        client.stream([ChatMessage.user('hi')]).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.message, 'message', contains('模型名'))
              // 原始的英文原因也要带上，不然用户搜都搜不出东西
              .having((e) => e.message, 'message', contains('model not found')),
        ),
      );
    });

    test('500 归为服务端问题', () async {
      final client = _client(_errorClient(500, 'oops'));

      await expectLater(
        client.stream([ChatMessage.user('hi')]).toList(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('服务端'),
          ),
        ),
      );
    });

    test('带图被 400 拒了，提示指向"换个能看图的"', () async {
      final client = _client(
        _errorClient(400, '{"error":{"message":"invalid content type"}}'),
      );

      await expectLater(
        client.stream([
          ChatMessage.user('这是什么', images: const [ImagePart(base64Data: 'AAAA')]),
        ]).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.message, 'message', contains('能看图'))
              // 原始的英文原因也要带上，不然用户搜都搜不出东西
              .having(
                (e) => e.message,
                'message',
                contains('invalid content type'),
              ),
        ),
      );
    });

    test('没图的 400 不许提图片', () async {
      final client = _client(_errorClient(400, '{"error":{"message":"bad request"}}'));

      await expectLater(
        client.stream([ChatMessage.user('在吗')]).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.message, 'message', isNot(contains('能看图'))),
        ),
      );
    });

    test('带图但 401 仍然说是 Key 的问题，不甩锅给模型', () async {
      final client = _client(
        _errorClient(401, '{"error":{"message":"Authentication Fails"}}'),
      );

      await expectLater(
        client.stream([
          ChatMessage.user('这是什么', images: const [ImagePart(base64Data: 'AAAA')]),
        ]).toList(),
        throwsA(
          isA<LlmException>()
              // 401 这件事跟有没有图无关。带图就把它也说成"模型不看图"，
              // 用户会去换模型、换完还是 401——那种白折腾最伤人。
              .having((e) => e.message, 'message', contains('API Key'))
              .having((e) => e.message, 'message', isNot(contains('能看图'))),
        ),
      );
    });
  });

  group('自动重试', () {
    /// 每次请求都走同一个 handler，但工厂每次给一个新 client，
    /// 和真实用法一致（取消订阅时要能真的掐断连接）。
    OpenAiCompatClient retrying(
      Future<http.StreamedResponse> Function(http.BaseRequest) handler,
    ) => OpenAiCompatClient(
      apiKey: 'k',
      baseUrl: _testBaseUrl,
      model: 'm',
      retryDelay: (_) async {},
      clientFactory: () => MockClient.streaming((req, _) => handler(req)),
    );

    test('500 之后自动重试，用户看不到报错', () async {
      var calls = 0;
      final client = retrying((_) async {
        calls++;
        if (calls == 1) {
          return http.StreamedResponse(Stream.value(utf8.encode('oops')), 500);
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              'data: {"choices":[{"delta":{"content":"好了"},"finish_reason":"stop"}]}\n\n'
              'data: [DONE]\n\n',
            ),
          ),
          200,
        );
      });

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(calls, 2);
      expect(
        chunks.whereType<TextChunk>().map((c) => c.text).join(),
        '好了',
      );
    });

    test('429 一直失败，重试到底后如实说"已重试 2 次"', () async {
      var calls = 0;
      final client = retrying((_) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"error":{"message":"rate limited"}}')),
          429,
        );
      });

      await expectLater(
        client.stream([ChatMessage.user('hi')]).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.message, 'message', contains('已重试 2 次')),
        ),
      );
      // 首发 + 两次重试
      expect(calls, 3);
    });

    test('401 不重试——Key 错了再问一遍还是错', () async {
      var calls = 0;
      final client = retrying((_) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"error":{"message":"bad key"}}')),
          401,
        );
      });

      await expectLater(
        client.stream([ChatMessage.user('hi')]).toList(),
        throwsA(isA<LlmException>()),
      );
      expect(calls, 1);
    });

    test('连不上（ClientException）也重试', () async {
      var calls = 0;
      final client = retrying((_) async {
        calls++;
        if (calls == 1) throw http.ClientException('connection reset by peer');
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: [DONE]\n\n')),
          200,
        );
      });

      final chunks = await client.stream([ChatMessage.user('hi')]).toList();

      expect(calls, 2);
      expect(chunks.whereType<DoneChunk>(), isNotEmpty);
    });

    test('已经把正文吐出去了，中途断开就不重试（否则同一段话出现两遍）', () async {
      var calls = 0;
      final client = retrying((_) async {
        calls++;
        return http.StreamedResponse(
          Stream<List<int>>.multi((controller) {
            controller.add(
              utf8.encode(
                'data: {"choices":[{"delta":{"content":"说了一半"},"finish_reason":null}]}\n\n',
              ),
            );
            controller.addError(http.ClientException('connection reset'));
            controller.close();
          }),
          200,
        );
      });

      final received = <LlmChunk>[];
      await expectLater(
        client.stream([ChatMessage.user('hi')]).forEach(received.add),
        throwsA(isA<LlmException>()),
      );

      expect(calls, 1);
      expect(
        received.whereType<TextChunk>().map((c) => c.text).join(),
        '说了一半',
      );
    });
  });

  group('消息线格式', () {
    test('用户带图时 content 变成 parts 数组', () {
      final msg = ChatMessage.user(
        '看这个',
        images: const [ImagePart(base64Data: 'AAAA')],
      );
      final wire = msg.toWire();

      final parts = wire['content'] as List;
      expect(parts.first, {'type': 'text', 'text': '看这个'});
      expect((parts.last as Map)['image_url'], {
        'url': 'data:image/png;base64,AAAA',
      });
    });

    test('工具结果消息带 tool_call_id', () {
      final msg = ChatMessage.toolResult(
        toolCallId: 'call_1',
        toolName: 'echo',
        content: '结果',
      );
      expect(msg.toWire(), {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': '结果',
      });
    });

    test('assistant 带工具调用时 content 是空串而不是 null', () {
      final msg = ChatMessage.assistant(
        '',
        toolCalls: const [
          ToolCall(id: 'c1', name: 'echo', arguments: {'a': 1}),
        ],
      );
      final calls = msg.toWire()['tool_calls'] as List;
      final fn = (calls.single as Map)['function'] as Map;

      expect(fn['name'], 'echo');
      expect(fn['arguments'], '{"a":1}');
    });
  });

  group('参数解码容错', () {
    test('非法 JSON 不抛，返回可识别的标记', () {
      expect(ToolCall.decodeArguments('{坏'), contains('__raw'));
    });

    test('空参数当空对象', () {
      expect(ToolCall.decodeArguments(''), isEmpty);
      expect(ToolCall.decodeArguments(null), isEmpty);
    });

    test('正常 JSON 解出 Map', () {
      expect(ToolCall.decodeArguments('{"a":1}'), {'a': 1});
    });
  });
}
