import '../../mcp/mcp_client.dart';
import '../n1_tool.dart';
import '../tool_context.dart';

/// 把一台 MCP 服务器上的一个工具包成 N1 的工具。
///
/// 描述里**标出它来自哪个服务器**：用户配了三台服务器时，"这个 read_file
/// 到底是本地的还是那个数据库服务器的"直接决定他看到结果后该不该信。
class McpToolAdapter extends N1Tool {
  const McpToolAdapter({
    required this.client,
    required this.serverName,
    required this.info,
    required this.prefixedName,
  });

  final McpClient client;
  final String serverName;
  final McpToolInfo info;

  /// 已经过 [mcpToolNameFor] 处理的名字。上游接口认这个名字。
  final String prefixedName;

  @override
  String get name => prefixedName;

  @override
  String get description {
    final text = info.description.trim();
    final body = text.isEmpty ? '（这台服务器没写说明）' : text;
    return '[$serverName 提供的工具] $body';
  }

  @override
  Map<String, Object?> get inputSchema => info.inputSchema;

  /// 外部服务器的工具能干什么完全取决于它，跟 `run_command` 是同一种风险，
  /// 所以进审计日志。**不弹审批**：这些服务器是用户自己在设置里加的，
  /// 每调一次问一次会把人逼到无脑点"允许"。
  @override
  bool get audited => true;

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    try {
      final result = await client.callTool(info.name, input);
      return result.isError
          ? ToolResult.fail(result.text)
          : ToolResult.ok(result.text);
    } on McpException catch (e) {
      return ToolResult.fail('$serverName 那边出错了：${e.message}');
    } on Object catch (e) {
      return ToolResult.fail('调 $serverName 的 ${info.name} 失败：$e');
    }
  }
}
