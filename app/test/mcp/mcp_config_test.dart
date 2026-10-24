import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/mcp/mcp_config.dart';

void main() {
  group('mcpToolNameFor', () {
    test('普通英文名拼成 mcp_服务器_工具', () {
      expect(mcpToolNameFor('files', 'read'), 'mcp_files_read');
    });

    test('纯中文名字退化成稳定哈希，不同工具不会撞名', () {
      final weather = mcpToolNameFor('我的 工具', '查天气');
      final stock = mcpToolNameFor('我的 工具', '查股票');

      expect(weather, startsWith('mcp_x'));
      expect(weather, isNot(stock));
      // 同一份配置每次算出来必须一样，否则重启后模型认得工具、我们认不得。
      expect(mcpToolNameFor('我的 工具', '查天气'), weather);
    });

    test('首尾的下划线去掉，不会出现 mcp__x__', () {
      expect(mcpToolNameFor('--db--', '__query__'), 'mcp_db_query');
    });

    test('全是符号的名字有兜底，不会变成空串', () {
      final name = mcpToolNameFor('***', '???');
      expect(name, startsWith('mcp_x'));
      expect(name.length, greaterThan(6));
    });

    test('超长名字截断到 64，并且保留工具名那一头', () {
      final name = mcpToolNameFor('a' * 80, 'the_real_tool');
      expect(name.length, 64);
      expect(name.endsWith('the_real_tool'), isTrue);
    });
  });

  group('配置读写', () {
    test('编码再解码回来是一模一样的东西', () {
      const servers = [
        McpServerConfig(
          id: 's1',
          name: '文件服务器',
          command: 'npx',
          args: ['-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
        ),
        McpServerConfig(
          id: 's2',
          name: 'off',
          command: 'x',
          enabled: false,
        ),
      ];

      final decoded = McpServerConfig.decodeList(
        McpServerConfig.encodeList(servers),
      );

      expect(decoded, hasLength(2));
      expect(decoded[0].name, '文件服务器');
      expect(decoded[0].args, hasLength(3));
      expect(decoded[1].enabled, isFalse);
    });

    test('坏 JSON 当成没配，不抛', () {
      expect(McpServerConfig.decodeList('{不是 json'), isEmpty);
      expect(McpServerConfig.decodeList(null), isEmpty);
      expect(McpServerConfig.decodeList(''), isEmpty);
    });

    test('缺命令的条目整条丢掉，其余照留', () {
      final raw = jsonEncode([
        {'id': 'ok', 'name': '好的', 'command': 'node'},
        {'id': 'bad', 'name': '没有命令'},
        {'name': '连 id 都没有', 'command': 'node'},
        '这不是对象',
      ]);

      final decoded = McpServerConfig.decodeList(raw);
      expect(decoded.map((s) => s.id), ['ok']);
    });

    test('没写 name 就用 id 顶上', () {
      final decoded = McpServerConfig.decodeList(
        jsonEncode([
          {'id': 'abc', 'command': 'node'},
        ]),
      );

      expect(decoded.single.name, 'abc');
    });

    test('args 里混进非字符串会被剔掉，不是整个崩', () {
      final decoded = McpServerConfig.decodeList(
        jsonEncode([
          {
            'id': 'a',
            'command': 'node',
            'args': ['x', 3, null, 'y'],
          },
        ]),
      );

      expect(decoded.single.args, ['x', 'y']);
    });
  });
}
