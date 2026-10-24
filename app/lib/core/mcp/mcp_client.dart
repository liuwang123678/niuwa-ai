import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// MCP 服务器返回的一个工具。
class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;

  /// JSON Schema，和 N1 自己的工具是同一套写法，可以直接转给上游模型。
  final Map<String, Object?> inputSchema;
}

/// 一次工具调用的结果。
class McpCallResult {
  const McpCallResult({required this.text, required this.isError});

  /// 已经把服务端返回的 content 块拼成了一段文字。
  final String text;

  /// 服务端说这次工具执行失败了（不是传输失败）。
  final bool isError;
}

class McpException implements Exception {
  const McpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一条消息的传输通道。
///
/// 抽出来是为了测试：真实实现要起子进程，测试里直接塞两端的假通道更快、
/// 也不会因为 CI 上没有某个命令而挂。
abstract class McpTransport {
  /// 收到的消息，**一条一行**。MCP 的 stdio 传输就是换行分隔的 JSON。
  Stream<String> get incoming;

  /// 发一条消息（实现负责补上换行）。
  void send(String message);

  /// 服务端最近写到 stderr 的内容，出错时附在提示里帮助排查。
  String get stderrTail;

  Future<void> close();
}

/// 通过子进程的 stdin/stdout 通信。
class StdioMcpTransport implements McpTransport {
  StdioMcpTransport(this._process) {
    // **必须把 stderr 读掉。** 管道缓冲区满了之后子进程会卡在 write 上，
    // 表现是"工具调用永远不返回"，而 stdout 那边看起来一切正常。
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _stderr.add(line);
          if (_stderr.length > 40) _stderr.removeAt(0);
        });
    // 进程退出时把 stdout 流结束掉，让上层知道对面没了。
    _process.exitCode.then((_) {
      if (!_incoming.isClosed) _incoming.close();
    });
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _incoming.add,
          onError: _incoming.addError,
          onDone: () {
            if (!_incoming.isClosed) _incoming.close();
          },
        );
  }

  static Future<StdioMcpTransport> start({
    required String command,
    required List<String> args,
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      command,
      args,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    return StdioMcpTransport(process);
  }

  final Process _process;
  final StreamController<String> _incoming = StreamController<String>();
  final List<String> _stderr = [];
  StreamSubscription<String>? _stderrSub;

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  String get stderrTail => _stderr.join('\n');

  @override
  void send(String message) {
    _process.stdin.writeln(message);
  }

  @override
  Future<void> close() async {
    await _stderrSub?.cancel();
    try {
      _process.stdin.writeln('');
      await _process.stdin.close();
    } catch (_) {
      // 对面可能已经退出了。关不上不是错误。
    }
    _process.kill();
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// 一个 MCP 服务器的客户端。
///
/// 只实现了工具这一块（`initialize` / `tools/list` / `tools/call`）——
/// N1 需要的就是这个。资源、提示词模板、采样这些暂时不碰：模型自己用不上，
/// 加上去只是让设置页更复杂。
class McpClient {
  McpClient({
    required this.transport,
    this.timeout = const Duration(seconds: 30),
  });

  final McpTransport transport;
  final Duration timeout;

  int _nextId = 1;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  StreamSubscription<String>? _sub;
  bool _closed = false;
  String _serverName = '';

  /// 握手。成功之后才能 [listTools]。
  Future<void> connect({String serverName = 'mcp'}) async {
    _serverName = serverName;
    _sub = transport.incoming.listen(
      _onLine,
      onError: (Object e) => _failAll('连接断了：$e'),
      onDone: () => _failAll('服务器关闭了连接'),
    );

    // 协议版本写一个我们认识的；服务端会回它自己支持的那个。版本不一致
    // 不当作失败——工具这套东西在 2024-11-05 之后没变过。
    await _request('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'niuwa-ai', 'version': '1.0'},
    });

    // 规范要求握手后发这个通知。不发的话有些实现会一直等着，不回 tools/list。
    _send({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
  }

  Future<List<McpToolInfo>> listTools() async {
    final result = await _request('tools/list');
    final raw = result['tools'];
    if (raw is! List) return const [];

    return [
      for (final item in raw)
        if (item is Map<String, Object?>)
          McpToolInfo(
            name: item['name'] as String? ?? '',
            description: item['description'] as String? ?? '',
            inputSchema:
                (item['inputSchema'] as Map<String, Object?>?) ??
                const {'type': 'object', 'properties': <String, Object?>{}},
          ),
    ].where((t) => t.name.isNotEmpty).toList();
  }

  Future<McpCallResult> callTool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    });

    return McpCallResult(
      text: _renderContent(result['content']),
      isError: result['isError'] == true,
    );
  }

  /// MCP 的 content 是一组块。模型只读得了文字，所以非文字块给一句说明，
  /// 而不是悄悄丢掉——不然用户会以为工具什么都没返回。
  static String _renderContent(Object? content) {
    if (content is! List || content.isEmpty) return '（服务端没有返回内容）';

    final parts = <String>[];
    for (final block in content) {
      if (block is! Map<String, Object?>) continue;
      final type = block['type'];
      if (type == 'text') {
        final text = block['text'];
        if (text is String && text.isNotEmpty) parts.add(text);
      } else if (type == 'image') {
        parts.add('（服务端返回了一张图片，这里看不了）');
      } else if (type == 'resource') {
        parts.add('（服务端返回了一个资源链接，这里看不了）');
      }
    }
    return parts.isEmpty ? '（服务端返回的内容里没有可读的文字）' : parts.join('\n\n');
  }

  Future<Map<String, Object?>> _request(
    String method, [
    Map<String, Object?>? params,
  ]) {
    if (_closed) {
      return Future.error(const McpException('连接已经关了'));
    }

    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;

    try {
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      });
    } catch (e) {
      _pending.remove(id);
      return Future.error(McpException('发送 $method 失败：$e'));
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw McpException(
          '$_serverName 的 $method 超过 ${timeout.inSeconds} 秒没回应。'
          '${_stderrHint()}',
        );
      },
    );
  }

  void _send(Map<String, Object?> message) =>
      transport.send(jsonEncode(message));

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    final Map<String, Object?> message;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, Object?>) return;
      message = decoded;
    } on FormatException {
      return; // 服务端往 stdout 打了日志。不是我们的消息，忽略。
    }

    final id = message['id'];
    if (id is! int) return; // 通知（比如 tools/list_changed）暂时不处理

    final completer = _pending.remove(id);
    if (completer == null) return;

    final error = message['error'];
    if (error != null) {
      final msg = error is Map<String, Object?> ? error['message'] : null;
      completer.completeError(
        McpException('$_serverName 报告错误：${msg ?? error}'),
      );
      return;
    }

    final result = message['result'];
    completer.complete(
      result is Map<String, Object?> ? result : <String, Object?>{},
    );
  }

  String _stderrHint() {
    final tail = transport.stderrTail.trim();
    if (tail.isEmpty) return '';
    final lines = tail.split('\n');
    final shown = lines.length <= 5 ? tail : lines.sublist(lines.length - 5).join('\n');
    return '\n服务端最后几行输出：\n$shown';
  }

  void _failAll(String reason) {
    final pending = List.of(_pending.entries);
    _pending.clear();
    for (final entry in pending) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(
          McpException('$_serverName：$reason${_stderrHint()}'),
        );
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    _failAll('连接已关闭');
    await transport.close();
  }
}
