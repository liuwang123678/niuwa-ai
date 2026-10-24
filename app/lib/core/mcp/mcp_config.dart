import 'dart:convert';

/// 一台 MCP 服务器的配置。
///
/// 只有"怎么把它起来"这一件事：命令 + 参数 + 环境变量。远程的
/// （HTTP/SSE）没做——N1 现在没有网络代理那一层，接进来还得处理鉴权，
/// 而本地 stdio 这一种已经能覆盖绝大多数现成的 MCP 服务器。
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.command,
    this.args = const [],
    this.enabled = true,
  });

  /// 稳定标识。改显示名不会影响它——工具名前缀、连接的复用都认这个。
  final String id;

  /// 显示名。也用来做工具名前缀。
  final String name;

  /// 要跑的命令。`npx` / `python` / 一个绝对路径都行。
  final String command;

  final List<String> args;

  /// 关掉的服务器**不启动**，也不再占用工具名。
  final bool enabled;

  McpServerConfig copyWith({
    String? name,
    String? command,
    List<String>? args,
    bool? enabled,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    command: command ?? this.command,
    args: args ?? this.args,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'command': command,
    'args': args,
    'enabled': enabled,
  };

  /// 坏数据一律**整条丢掉**（返回 null），不是补默认值。
  ///
  /// 这里跟提醒那边的态度不同：一条命令是空的配置，跑起来只会是一个
  /// 立刻退出的子进程，留着它只会让"为什么这个工具不见了"更难查。
  static McpServerConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final id = raw['id'];
    final name = raw['name'];
    final command = raw['command'];
    if (id is! String || id.trim().isEmpty) return null;
    if (command is! String || command.trim().isEmpty) return null;

    final rawArgs = raw['args'];
    final args = rawArgs is List
        ? rawArgs.whereType<String>().toList(growable: false)
        : const <String>[];

    return McpServerConfig(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : id,
      command: command.trim(),
      args: args,
      enabled: raw['enabled'] != false,
    );
  }

  static List<McpServerConfig> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(McpServerConfig.fromJson)
          .whereType<McpServerConfig>()
          .toList(growable: false);
    } on FormatException {
      // 手改坏了的配置不该让整个 App 起不来。丢掉就当没配。
      return const [];
    }
  }

  static String encodeList(List<McpServerConfig> servers) =>
      jsonEncode(servers.map((s) => s.toJson()).toList());
}

/// 工具名里允许的字符。上游接口对工具名有正则要求，我们这里先归一。
///
/// 中文、空格、标点全换成 `_`：把服务器叫「我的工具」时，工具名不能是
/// `mcp_我的工具_read`。
String mcpToolNameFor(String serverName, String toolName) {
  String clean(String s) {
    final ascii = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (ascii.isNotEmpty) return ascii;

    // 纯中文的名字（「查天气」）会被上面整段抹掉。退回原名的短哈希，
    // 而不是一个固定的 'tool'——固定值会让这台服务器的每个工具都叫
    // 同一个名字，然后互相覆盖，最后只剩一个。
    var hash = 0;
    for (final unit in s.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return 'x${hash.toRadixString(36)}';
  }

  final server = clean(serverName);
  final tool = clean(toolName);

  var name = 'mcp_${server}_$tool';

  // 上游普遍限 64 字符。截断时**留尾巴**：真正的工具名在最后，
  // 前面那截服务器名通常是重复的。
  if (name.length > 64) name = name.substring(name.length - 64);
  return name;
}
