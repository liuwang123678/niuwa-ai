import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/mcp/mcp_client.dart';

/// stdio 传输的端到端：**真起一个子进程**说话。
///
/// 协议层本身已经用假通道测过了；这里要验的只有假通道测不到的那部分——
/// 换行分隔的 stdin/stdout、进程退出、UTF-8 中文过来会不会乱码。
void main() {
  late StdioMcpTransport transport;
  late McpClient client;

  /// 找 dart 可执行文件。
  ///
  /// Windows 上不能直接写 `dart`：`Process.start` 不做 PATHEXT 补全，
  /// 不写 `.exe` 就是"系统找不到指定的文件"。Flutter SDK 的 `bin/cache/
  /// dart-sdk/bin/dart.exe` 一定在，比依赖 PATH 稳。
  String dartExecutable() {
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null) {
      final candidate = File(
        '$flutterRoot/bin/cache/dart-sdk/bin/'
        '${Platform.isWindows ? 'dart.exe' : 'dart'}',
      );
      if (candidate.existsSync()) return candidate.path;
    }
    return Platform.isWindows ? 'dart.exe' : 'dart';
  }

  setUp(() async {
    transport = await StdioMcpTransport.start(
      command: dartExecutable(),
      args: ['test/fixtures/mcp_echo_server.dart'],
    );
    client = McpClient(transport: transport);
    await client.connect(serverName: 'echo');
  });

  tearDown(() async {
    await client.close();
  });

  test('握手、列工具、调工具，一整条都通', () async {
    final tools = await client.listTools();
    expect(tools.map((t) => t.name), containsAll(['echo', 'boom']));

    final echo = tools.firstWhere((t) => t.name == 'echo');
    expect(echo.description, '把输入原样说回来');
    expect(echo.inputSchema['required'], ['text']);
  });

  test('中文参数过去、中文结果回来，不被编码搞坏', () async {
    final result = await client.callTool('echo', {'text': '你好，世界'});

    expect(result.isError, isFalse);
    expect(result.text, '你好，世界');
  });

  test('服务端的 isError 原样透传', () async {
    final result = await client.callTool('boom', const {});

    expect(result.isError, isTrue);
    expect(result.text, '炸了');
  });

  test('关掉之后请求当场失败，不是干等到超时', () async {
    await client.close();

    await expectLater(
      client.callTool('echo', const {'text': 'x'}),
      throwsA(isA<McpException>()),
    );
  });
}
