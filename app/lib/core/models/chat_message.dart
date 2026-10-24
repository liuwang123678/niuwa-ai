import 'dart:convert';

import '../util/ids.dart';
import 'attachment.dart';

/// 消息角色。跟 OpenAI 兼容协议一一对应。
enum Role {
  system,
  user,
  assistant,
  tool;

  String get wire => name;
}

/// 一张附图（多模态输入）。以 `image_url` 收 base64 data URL 的形状发出去——
/// 这是 OpenAI 兼容接口的通行写法（在多模态的那家上实测过）。
///
/// 接的这家不支持看图的话，带了图的消息会报错。那是模型能力问题，
/// 不是协议问题。
class ImagePart {
  const ImagePart({required this.base64Data, this.mimeType = 'image/png'});

  final String base64Data;
  final String mimeType;

  String get dataUrl => 'data:$mimeType;base64,$base64Data';

  Map<String, Object?> toWire() => {
    'type': 'image_url',
    'image_url': {'url': dataUrl},
  };
}

/// 模型发起的一次工具调用。
///
/// 注意：线协议里 [arguments] 是 **JSON 字符串**（不是对象），流式响应里还会被切成
/// 碎片逐块推。`ChatMessage.fromWire` 负责收进来时解，这里对外一律是解好的 Map。
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;

  Map<String, Object?> toWire() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': jsonEncode(arguments)},
  };

  static ToolCall fromRequest(Map<String, Object?> call, Map<String, Object?> fn) {
    return ToolCall(
      id: (call['id'] as String?) ?? newId('call'),
      name: (fn['name'] as String?) ?? '',
      arguments: decodeArguments(fn['arguments']),
    );
  }

  /// 把线协议里的 arguments（JSON 字符串）解成 Map。
  ///
  /// 模型偶尔吐出非法 JSON。这里不抛——返回 `{'__raw': ...}` 让工具表去报"参数错误"，
  /// agent 看到明确失败原因后会自己重发，比整轮崩掉强。
  static Map<String, Object?> decodeArguments(Object? raw) {
    if (raw is Map<String, Object?>) return raw;
    if (raw is! String || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      // 模型偶尔会吐出非法 JSON（少个引号之类）。不抛，交给工具层去报参数错误，
      // 这样 agent 能看到"参数解析失败"并自己重试，比整轮崩掉好。
      return const {'__raw': 'invalid json'};
    }
  }
}

/// 一条消息是怎么来的。
///
/// `chat` = 用户和模型正常一来一回；`reminder` = 定时提醒到点后落进来的。
/// 界面靠它决定要不要在气泡下面显示那行「提醒 · 15:00」的小字。
///
/// **故意不做成线格式的一部分**：`toWire()` 一个字节都不带它。模型不需要知道
/// 自己上一句话是现场回的还是定时发的，多给它一个字段只会干扰判断。
enum MessageOrigin {
  chat,
  reminder;

  /// 认不出的一律当 [chat]。
  ///
  /// 这里**不丢整行**——跟 `_messageOf` 对坏 role 的处理相反。理由是：
  /// role 认错会让这条消息在协议层变得不合法（回传给接口会被拒），
  /// 而 origin 只是个装饰性标记，认错了最多是少显示一行小字，
  /// 为它丢掉用户的一句原话不划算。
  static MessageOrigin parse(String? raw) {
    for (final o in MessageOrigin.values) {
      if (o.name == raw) return o;
    }
    return MessageOrigin.chat;
  }
}

/// 一条对话消息。
///
/// 设计成不可变的：agent 循环里到处在传消息列表，可变对象迟早会被某处就地改掉。
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.images = const [],
    this.attachments = const [],
    this.toolCalls,
    this.toolCallId,
    this.reasoning,
    this.toolName,
    this.origin = MessageOrigin.chat,
  });

  factory ChatMessage.user(
    String text, {
    List<ImagePart> images = const [],
    List<Attachment> attachments = const [],
  }) => ChatMessage(
    id: newId('msg'),
    role: Role.user,
    content: text,
    images: images,
    attachments: attachments,
    createdAt: _now(),
  );

  factory ChatMessage.system(String text) => ChatMessage(
    id: newId('msg'),
    role: Role.system,
    content: text,
    createdAt: _now(),
  );

  factory ChatMessage.assistant(
    String text, {
    List<ToolCall>? toolCalls,
    String? reasoning,
    MessageOrigin origin = MessageOrigin.chat,
  }) => ChatMessage(
    id: newId('msg'),
    role: Role.assistant,
    content: text,
    toolCalls: toolCalls,
    reasoning: reasoning,
    origin: origin,
    createdAt: _now(),
  );

  factory ChatMessage.toolResult({
    required String toolCallId,
    required String toolName,
    required String content,
  }) => ChatMessage(
    id: newId('msg'),
    role: Role.tool,
    content: content,
    toolCallId: toolCallId,
    toolName: toolName,
    createdAt: _now(),
  );

  final String id;
  final Role role;
  final String content;
  final int createdAt;
  final List<ImagePart> images;

  /// 仅 user：用户附上的文本文件。**不单独发线格式**，在 [toWire] 里拼进正文。
  final List<Attachment> attachments;

  /// 仅 assistant：本轮发起的工具调用。
  final List<ToolCall>? toolCalls;

  /// 仅 tool：回填给哪个调用。
  final String? toolCallId;

  /// 仅 tool：哪个工具的结果。界面展示用，也方便调试。
  final String? toolName;

  /// 仅 assistant：模型的思考过程（线格式里的字段名各家不一样）。
  ///
  /// 只用于界面展示，**绝不回传给接口**。回传也没意义——模型不需要上一轮的
  /// 草稿；而且探接口时实测过，把思考塞回上下文会被直接拒。
  final String? reasoning;

  /// 这条消息的来路。见 [MessageOrigin]。
  final MessageOrigin origin;

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;

  /// 发给模型的那份正文：用户打的字 + 附件内容。
  ///
  /// 附件只在这一刻拼进去，**不写回 [content]**——库里存的是用户原话，
  /// 界面上显示的也是那一句。不然一个 4 万字的 CSV 会把气泡撑得没法看，
  /// 而且下次启动重新渲染时还会再显示一遍。
  String get _textWithAttachments {
    if (attachments.isEmpty) return content;
    final buffer = StringBuffer(content.trimRight());
    for (final attachment in attachments) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(attachment.toPromptSection());
    }
    return buffer.toString();
  }

  /// 转成接口要的线格式。
  ///
  /// 几条容易踩的规矩：
  /// - assistant 带 tool_calls 时 `content` 可以是空串，但不能是 null
  /// - tool 消息必须带 `tool_call_id`
  /// - `reasoning` 一律丢掉，不回传
  Map<String, Object?> toWire() {
    switch (role) {
      case Role.tool:
        return {
          'role': 'tool',
          'tool_call_id': toolCallId,
          'content': content,
        };
      case Role.assistant:
        return {
          'role': 'assistant',
          'content': content,
          if (hasToolCalls)
            'tool_calls': toolCalls!.map((c) => c.toWire()).toList(),
        };
      case Role.system:
        return {'role': 'system', 'content': content};
      case Role.user:
        final text = _textWithAttachments;
        if (images.isEmpty) return {'role': 'user', 'content': text};
        return {
          'role': 'user',
          'content': [
            if (text.isNotEmpty) {'type': 'text', 'text': text},
            ...images.map((i) => i.toWire()),
          ],
        };
    }
  }

  static ChatMessage fromWire(Map<String, Object?> json) {
    final roleName = json['role'] as String? ?? 'user';
    final role = Role.values.firstWhere(
      (r) => r.name == roleName,
      orElse: () => Role.user,
    );

    List<ToolCall>? toolCalls;
    final rawCalls = json['tool_calls'];
    if (rawCalls is List) {
      toolCalls = rawCalls
          .whereType<Map<String, Object?>>()
          .map((c) {
            final fn = c['function'];
            return ToolCall.fromRequest(
              c,
              fn is Map<String, Object?> ? fn : const {},
            );
          })
          .toList();
    }

    return ChatMessage(
      id: (json['id'] as String?) ?? newId('msg'),
      role: role,
      content: (json['content'] as String?) ?? '',
      toolCalls: toolCalls,
      toolCallId: json['tool_call_id'] as String?,
      toolName: json['name'] as String?,
      reasoning: json['reasoning_content'] as String?,
      createdAt: (json['created_at'] as int?) ?? _now(),
    );
  }

  ChatMessage copyWith({String? content, String? reasoning}) => ChatMessage(
    id: id,
    role: role,
    content: content ?? this.content,
    images: images,
    attachments: attachments,
    toolCalls: toolCalls,
    toolCallId: toolCallId,
    toolName: toolName,
    reasoning: reasoning ?? this.reasoning,
    // origin 必须一起带上。它默认是 chat，漏了这一行的话
    // 提醒消息被 copyWith 一次就悄悄变成普通消息了——而且不报错、不掉字段，
    // 只是界面上那行「提醒 · 15:00」莫名消失。
    origin: origin,
    createdAt: createdAt,
  );

  /// 摘掉图，其余原样。
  ///
  /// `copyWith` 做不到这件事：它的 `images` 是透传的，而用可空参数表达
  /// "清空"会和"不改"撞车。与其给 `copyWith` 加一个别扭的 `bool` 开关，
  /// 不如把这个意图写成一个有名字的方法。
  ChatMessage withoutImages() => ChatMessage(
    id: id,
    role: role,
    content: content,
    images: const [],
    attachments: attachments,
    toolCalls: toolCalls,
    toolCallId: toolCallId,
    toolName: toolName,
    reasoning: reasoning,
    // origin 必须跟着带。漏了的话提醒消息被摘一次图就悄悄变成普通消息，
    // 界面上那行「提醒 · 15:00」莫名消失——而且不报错、不掉字段。
    // copyWith 上已经踩过一模一样的坑，别再踩第二遍。
    origin: origin,
    createdAt: createdAt,
  );

  /// 换掉 `tool_calls`，传 null 就是**清空**，其余原样。
  ///
  /// 跟 [withoutImages] 同一个理由：`copyWith` 的可空参数分不清"清空"和"不改"，
  /// 而这里两种都要能表达。发给上游前拆掉没配上的工具声明用得到它
  /// （`AgentLoop.sanitizeHistory`）。
  ChatMessage withToolCalls(List<ToolCall>? calls) => ChatMessage(
    id: id,
    role: role,
    content: content,
    images: images,
    attachments: attachments,
    toolCalls: calls,
    toolCallId: toolCallId,
    toolName: toolName,
    reasoning: reasoning,
    // origin 必须跟着带。漏了的话提醒消息被拆一次工具声明就悄悄变成普通消息，
    // 界面上那行「提醒 · 15:00」莫名消失——而且不报错、不掉字段。
    // copyWith 上已经踩过一模一样的坑，别再踩第二遍。
    origin: origin,
    createdAt: createdAt,
  );

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}
