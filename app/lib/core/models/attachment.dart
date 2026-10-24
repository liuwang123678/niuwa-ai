import 'dart:convert';

/// 用户附进对话的一段文本。
///
/// 为什么把正文**拷进消息里**，而不是只存一个路径：路径在第二次启动、
/// 换台机器、或者用户把源文件删掉之后就失效了。附件是"用户当时给我看的东西"，
/// 它得跟那条消息一起活着。
///
/// 这里只有文本。图片走的是另一条路（`ImagePart`，走多模态线格式），
/// 二进制文件（PDF/Word/压缩包）目前**不读内容**——没有对应的解析器，
/// 硬塞一段乱码比直说"这个格式不行"更糟。
class Attachment {
  const Attachment({
    required this.name,
    required this.text,
    this.sizeBytes = 0,
    this.truncated = false,
  });

  /// 只留文件名，不带路径：路径既是隐私，也只在当时那台机器上有效。
  final String name;

  /// 文件正文（可能已被截断，见 [truncated]）。
  final String text;

  /// 原始字节数。界面显示"12 KB"用。
  final int sizeBytes;

  /// 太长只取了前面一段。**必须告诉模型**，否则它会拿半截内容下结论。
  final bool truncated;

  /// 转成喂给模型的一段文字。
  ///
  /// 首尾都带标记：附件正文里完全可能自己出现 `【附件…` 这种字眼，只有
  /// 成对出现、并且带上文件名，模型才分得清哪一段是文件、哪一段是用户的话。
  String toPromptSection() {
    final note = truncated ? '，内容已截断' : '';
    return '【附件：$name$note】\n$text\n【附件结束：$name】';
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'text': text,
    'sizeBytes': sizeBytes,
    'truncated': truncated,
  };

  /// 坏数据返回 null。附件是"附加信息"，丢一段不该让整条消息消失——
  /// 调用方会把 null 过滤掉，用户自己的那句话照留。
  static Attachment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final text = raw['text'];
    if (name is! String || name.trim().isEmpty) return null;
    if (text is! String) return null;

    final size = raw['sizeBytes'];
    return Attachment(
      name: name,
      text: text,
      sizeBytes: size is int ? size : 0,
      truncated: raw['truncated'] == true,
    );
  }

  static List<Attachment> decodeList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map(Attachment.fromJson)
        .whereType<Attachment>()
        .toList(growable: false);
  }

  /// 跟 images 那一列保持一致：空表存成 `[]`，不是 null。
  static String encodeList(List<Attachment> attachments) =>
      jsonEncode([for (final a in attachments) a.toJson()]);
}
