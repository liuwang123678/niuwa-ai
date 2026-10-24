import '../core/n1_core.dart';

/// 界面上的一条聊天记录。
///
/// 为什么不直接用内核的 [ChatMessage]：那是**协议格式**，字段是按接口要求排的
/// （tool 消息要带 tool_call_id、assistant 带工具调用时 content 得是空串不是
/// null……）。界面上需要的是另一套东西——"这条还在流式输出吗""思考过程折叠
/// 没有""工具跑到哪一步了"。两件事混成一个类，改协议会连带改界面。
///
/// 内核是真相，界面是它的投影。转换在 ChatProvider 里做。
sealed class ChatItem {
  const ChatItem(this.id);

  final String id;
}

/// 用户说的话。
final class UserItem extends ChatItem {
  const UserItem(
    super.id, {
    required this.text,
    this.images = const [],
    this.attachments = const [],
  });

  final String text;
  final List<ImagePart> images;

  /// 附上的文本文件。气泡里只显示文件名，**不显示正文**——正文是给模型看的。
  final List<Attachment> attachments;
}

/// N1 说的话。**字段可变**——流式输出时它一直在长。
///
/// 只有 ChatProvider 能改这里的东西，界面只读。
final class AssistantItem extends ChatItem {
  AssistantItem(
    super.id, {
    this.text = '',
    this.reasoning = '',
    this.streaming = true,
    // 参数**不写 `this.`**，下面要拷一份，见那个初始化列表里的说明。
    List<ToolTrace> tools = const [],
    this.error,
    this.stopReason,
    this.usage,
    this.contextTrimmed = false,
    this.fromReminder = false,
    DateTime? at,
  }) : at = at ?? DateTime.now(),
       // **必须拷一份。** 默认值 `const []` 是不可变的，而流式过程中
       // `ChatProvider` 要往这个 list 里 `add`。不拷的话那句 add 直接抛
       // `Unsupported operation: Cannot add to an unmodifiable list`，
       // 而这个异常发生在流事件回调里——界面不会报错，只是**
       // 工具痕迹永远不出现**。表现就是"它好像什么都没干"，
       // 连"模型到底用没用技能"都无从判断。
       tools = List.of(tools);

  /// 正文。流式过程中一点点长。
  String text;

  /// 思考过程。跟正文分开存，界面上折叠显示——这个字段是意外收获，
  /// 探接口时发现有模型会把它单独推一个字段出来（各家叫法不一样，
  /// 客户端负责归一）。
  String reasoning;

  bool streaming;

  /// 这条是**到点响的提醒**，不是模型当场说的话。
  ///
  /// 界面上要标出来，否则用户会以为 N1 无缘无故自己冒了一句——尤其是隔了
  /// 一晚上再打开，那条消息就挂在最下面。
  bool fromReminder;

  /// 这条消息里模型调过的工具，按顺序。
  List<ToolTrace> tools;

  /// 出错时的中文提示。非空表示这条是失败态。
  String? error;

  /// `stop` / `tool_calls` / `max_turns` / `length` / `incomplete`。
  String? stopReason;

  UsageChunk? usage;

  /// 这一步发出去之前，老内容因为超出预算被裁过。
  ///
  /// 界面要说一句：模型不记得早先的事不是它变笨，是上下文装不下。
  bool contextTrimmed;

  final DateTime at;

  /// 有没有东西可显示。空 assistant 气泡（还没吐字）不该占位。
  bool get isEmpty => text.isEmpty && reasoning.isEmpty && tools.isEmpty;

  /// 被轮数上限截断了。界面要告诉用户，不然会以为模型话没说完是 bug。
  bool get wasTruncated => stopReason == 'length' || stopReason == 'max_turns';
}

/// 一次工具调用在界面上的样子。
///
/// [result] 为空表示还在跑。
class ToolTrace {
  ToolTrace(this.call);

  final ToolCall call;
  ToolResult? result;
  Duration? duration;

  bool get running => result == null;
  bool get ok => result?.ok ?? false;

  void finish(ToolInvocation invocation) {
    result = invocation.result;
    duration = invocation.duration;
  }
}
