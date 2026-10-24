import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/mcp/mcp_client.dart';

/// 内存里的假通道：发出去的消息记下来，`reply` 决定怎么回。
class FakeTransport implements McpTransport {
  final StreamController<String> _incoming = StreamController<String>();
  final List<Map<String, Object?>> sent = [];

  /// 收到请求时返回要回的行；返回 null 表示这次不回（用来测超时）。
  String? Function(Map<String, Object?> request)? reply;

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  String get stderrTail => '';

  @override
  void send(String message) {
    final decoded = jsonDecode(message) as Map<String, Object?>;
    sent.add(decoded);
    final response = reply?.call(decoded);
    if (response != null) _incoming.add(response);
  }

  void push(String line) => _incoming.add(line);

  void closeStream() => _incoming.close();

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// 自动回一个正常结果。
String respond(Map<String, Object?> request, Object? result) => jsonEncode({
  'jsonrpc': '2.0',
  'id': request['id'],
  'result': result,
});

void main() {
  late FakeTransport transport;
  late McpClient client;

  setUp(() {
    transport = FakeTransport();
    client = McpClient(
      transport: transport,
      timeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    await client.close();
  });

  group('握手', () {
    test('先 initialize，再发 initialized 通知', () async {
      transport.reply = (req) {
        if (req['method'] == 'initialize') {
          return respond(req, {
            'protocolVersion': '2024-11-05',
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': 'fake', 'version': '1.0'},
          });
        }
        return null;
      };

      await client.connect(serverName: 'fake');

      expect(transport.sent.first['method'], 'initialize');
      expect(
        (transport.sent.first['params'] as Map)['protocolVersion'],
        '2024-11-05',
      );
      expect(transport.sent.last['method'], 'notifications/initialized');
      expect(transport.sent.last.containsKey('id'), isFalse);
    });

    test('服务端回了别的协议版本也照常往下走', () async {
      transport.reply = (req) => respond(req, {
        'protocolVersion': '2025-03-26',
        'capabilities': <String, Object?>{},
      });

      await client.connect();
      // 没抛就是过了。
    });

    test('服务端报错时把它的原话带出来', () async {
      transport.reply = (req) => jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'error': {'code': -32601, 'message': 'Method not found'},
      });

      await expectLater(
        client.connect(serverName: '老服务'),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('老服务'), contains('Method not found')),
          ),
        ),
      );
    });
  });

  group('列工具', () {
    test('解析出名字、描述和 JSON Schema', () async {
      transport.reply = (req) {
        if (req['method'] == 'initialize') return respond(req, {});
        if (req['method'] == 'tools/list') {
          return respond(req, {
            'tools': [
              {
                'name': 'search',
                'description': '搜一下',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'q': {'type': 'string'},
                  },
                },
              },
              {'name': '', 'description': '没有名字的扔掉'},
            ],
          });
        }
        return null;
      };

      await client.connect();
      final tools = await client.listTools();

      expect(tools.length, 1);
      expect(tools.single.name, 'search');
      expect(tools.single.description, '搜一下');
      expect(tools.single.inputSchema['type'], 'object');
    });

    test('服务端没给 inputSchema 时补一个空对象，不是 null', () async {
      transport.reply = (req) {
        if (req['method'] == 'initialize') return respond(req, {});
        if (req['method'] == 'tools/list') {
          return respond(req, {
            'tools': [
              {'name': 'noargs'},
            ],
          });
        }
        return null;
      };

      await client.connect();
      final tools = await client.listTools();

      expect(tools.single.inputSchema['type'], 'object');
    });
  });

  group('调工具', () {
    Future<void> connect() async {
      transport.reply = (req) => req['method'] == 'initialize'
          ? respond(req, {})
          : null;
      await client.connect();
    }

    test('把文本块拼成一段', () async {
      await connect();
      transport.reply = (req) {
        if (req['method'] != 'tools/call') return null;
        return respond(req, {
          'content': [
            {'type': 'text', 'text': '第一行'},
            {'type': 'text', 'text': '第二行'},
          ],
        });
      };

      final result = await client.callTool('echo', {'x': 1});

      expect(result.text, '第一行\n\n第二行');
      expect(result.isError, isFalse);
    });

    test('isError 透传，别把失败说成成功', () async {
      await connect();
      transport.reply = (req) => respond(req, {
        'content': [
          {'type': 'text', 'text': '文件不存在'},
        ],
        'isError': true,
      });

      final result = await client.callTool('read', {'path': 'nope'});

      expect(result.isError, isTrue);
      expect(result.text, '文件不存在');
    });

    test('图片块给一句说明，不悄悄丢', () async {
      await connect();
      transport.reply = (req) => respond(req, {
        'content': [
          {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
        ],
      });

      final result = await client.callTool('shot', {});

      expect(result.text, contains('图片'));
      expect(result.text, isNotEmpty);
    });

    test('空内容也说一句，别让模型以为工具没返回', () async {
      await connect();
      transport.reply = (req) => respond(req, {'content': <Object?>[]});

      final result = await client.callTool('noop', {});

      expect(result.text, isNotEmpty);
    });

    test('参数原样发出去', () async {
      await connect();
      transport.reply = (req) => respond(req, {'content': <Object?>[]});

      await client.callTool('search', {'q': '牛蛙', 'limit': 3});

      final call = transport.sent.last;
      expect(call['method'], 'tools/call');
      expect((call['params'] as Map)['name'], 'search');
      expect((call['params'] as Map)['arguments'], {'q': '牛蛙', 'limit': 3});
    });
  });

  group('坏掉的时候', () {
    test('一直不回就超时，提示里带服务器名', () async {
      transport.reply = null;

      await expectLater(
        client.connect(serverName: '装死的服务'),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('装死的服务'), contains('没回应')),
          ),
        ),
      );
    });

    test('stdout 里混进日志行不会打断解析', () async {
      transport.reply = (req) {
        if (req['method'] == 'initialize') {
          // 先推一行不是 JSON 的日志，再给正常响应。
          transport.push('Starting server...');
          return respond(req, {});
        }
        return null;
      };

      await client.connect();
    });

    test('连接断了，还在等的那条请求立刻失败，不是干等到超时', () async {
      transport.reply = (req) => req['method'] == 'initialize'
          ? respond(req, {})
          : null;
      await client.connect();

      final pending = client.callTool('slow', {});
      transport.closeStream();

      await expectLater(pending, throwsA(isA<McpException>()));
    });

    test('关掉之后再发请求，当场就报错', () async {
      transport.reply = (req) => respond(req, {});
      await client.connect();
      await client.close();

      await expectLater(
        client.listTools(),
        throwsA(isA<McpException>()),
      );
    });
  });
}
