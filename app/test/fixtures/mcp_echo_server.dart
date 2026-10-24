// 一台最小的 MCP 服务器，只为了让 stdio 传输那条路有个真东西可跑。
//
// 不是测试文件（名字不以 _test.dart 结尾），`flutter test` 不会把它当用例。
// 由 `test/mcp/mcp_stdio_e2e_test.dart` 用 `dart` 起起来。
import 'dart:convert';
import 'dart:io';

void main() {
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.trim().isEmpty) return;

        final Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException {
          return;
        }
        if (decoded is! Map<String, Object?>) return;

        final id = decoded['id'];
        // 通知（没有 id）不用回。
        if (id == null) return;

        switch (decoded['method']) {
          case 'initialize':
            _reply(id, {
              'protocolVersion': '2024-11-05',
              'capabilities': <String, Object?>{},
              'serverInfo': {'name': 'echo-test', 'version': '1.0'},
            });
          case 'tools/list':
            _reply(id, {
              'tools': [
                {
                  'name': 'echo',
                  'description': '把输入原样说回来',
                  'inputSchema': {
                    'type': 'object',
                    'properties': {
                      'text': {'type': 'string'},
                    },
                    'required': ['text'],
                  },
                },
                {
                  'name': 'boom',
                  'description': '总是失败，用来验 isError',
                  'inputSchema': {'type': 'object', 'properties': {}},
                },
              ],
            });
          case 'tools/call':
            final params = decoded['params'];
            final name = params is Map ? params['name'] : null;
            final args = params is Map ? params['arguments'] : null;

            if (name == 'echo') {
              final text = args is Map ? args['text'] : '';
              _reply(id, {
                'content': [
                  {'type': 'text', 'text': '$text'},
                ],
                'isError': false,
              });
            } else {
              _reply(id, {
                'content': [
                  {'type': 'text', 'text': '炸了'},
                ],
                'isError': true,
              });
            }
          default:
            _replyError(id, '不认识的方法 ${decoded['method']}');
        }
      });
}

void _reply(Object? id, Map<String, Object?> result) {
  stdout.writeln(jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  }));
}

void _replyError(Object? id, String message) {
  stdout.writeln(jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': -32601, 'message': message},
  }));
}
