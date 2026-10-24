import '../models/chat_message.dart';

/// 发给模型时，保留最近几组带图的消息。
///
/// 每次发送都会把**整段历史**重发一遍（`chat_provider.dart` 里那个
/// `List<ChatMessage>.unmodifiable(_wire)`），而 base64 图片是这条链路上最贵的
/// 东西。3 组够覆盖"接着说上一张图"这种连续追问，又不至于让每轮请求都驮着
/// 十几张图。
const int kImageKeep = 3;

/// 把旧的图从**要发出去的历史**里摘掉。库里的一个字都不动。
///
/// 语义：从后往前数，最近 [keep] 条**带图**的消息原样保留；更早的把图摘掉、
/// 文字留着。用户往上翻还能看见老照片，只是模型看不见了。
///
/// 裁剪是"发什么"，不是"存什么"——`_wire` 是"真实发生过的对话"，
/// `retry()` 要靠它找目标，所以它保持完整。
///
/// **只有图、没有字的那种老消息整条剔除，不是留个空壳。** 摘掉图之后它会变成
/// `{'role': 'user', 'content': ''}`，上游直接 400。这个分支必须存在，
/// 而且必须有测试盯着。
List<ChatMessage> pruneOldImages(
  List<ChatMessage> history, {
  int keep = kImageKeep,
}) {
  final kept = <ChatMessage>[];
  var seen = 0;

  // 从后往前扫，这样"最近 keep 条"就是"最早遇到的那 keep 条"，
  // 不用先数总数再回头找边界。
  for (var i = history.length - 1; i >= 0; i--) {
    final message = history[i];

    if (message.images.isEmpty) {
      kept.add(message);
      continue;
    }

    seen++;
    if (seen <= keep) {
      kept.add(message);
      continue;
    }

    // 图没了、字也没了——整条丢掉。
    if (message.content.trim().isEmpty) continue;

    kept.add(message.withoutImages());
  }

  return kept.reversed.toList();
}
