import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

ImagePart tinyImage(String tag) =>
    ImagePart(base64Data: tag, mimeType: 'image/jpeg');

ChatMessage userText(String text) => ChatMessage.user(text);

ChatMessage userWithImage(String text, String tag) =>
    ChatMessage.user(text, images: [tinyImage(tag)]);

/// 造一段"每轮都是图 + 字"的历史。
List<ChatMessage> imageRounds(int count) => [
  for (var i = 0; i < count; i++)
    ...[
      userWithImage('第 $i 张', 'img$i'),
      ChatMessage.assistant('看到了 $i'),
    ],
];

void main() {
  test('带图的消息不超过 keep 条时，一张都不动', () {
    final history = imageRounds(3);
    final out = pruneOldImages(history, keep: 3);
    expect(out.map((m) => m.images.length).where((n) => n > 0), hasLength(3));
  });

  test('第 4 张带图的消息一来，最老那张的图被摘掉、文字还在', () {
    final out = pruneOldImages(imageRounds(4), keep: 3);

    final oldest = out.firstWhere((m) => m.content == '第 0 张');
    expect(oldest.images, isEmpty, reason: '最老那张的图应该被摘掉');
    expect(oldest.content, '第 0 张', reason: '文字一个字都不许动');

    final second = out.firstWhere((m) => m.content == '第 1 张');
    expect(second.images, hasLength(1), reason: '最近 3 张要留着');
  });

  test('纯文字消息不受影响，也不占额度', () {
    final history = [
      userText('你好'),
      ChatMessage.assistant('在的'),
      ...imageRounds(4),
    ];
    final out = pruneOldImages(history, keep: 3);

    expect(
      out.where((m) => m.content == '你好').single.images,
      isEmpty,
    );
    // 纯文字不占额度：最近 3 条带图的全留下，被摘的只有「第 0 张」。
    expect(
      out.where((m) => m.content == '第 1 张').single.images,
      hasLength(1),
    );
  });

  test('只有图、没有字的老消息整条剔除，不留空壳', () {
    // 摘掉图之后它会变成 content 为空串的消息，上游直接 400。
    final history = [
      userWithImage('', 'old'), // 只有图
      ...imageRounds(3),
    ];
    final out = pruneOldImages(history, keep: 3);

    expect(
      out.any((m) => m.id == history.first.id),
      isFalse,
      reason: '这条应该整条消失，不是变成一条空消息',
    );
  });

  test('裁完没有一条是空的', () {
    final out = pruneOldImages([
      userWithImage('', 'a'),
      userWithImage('', 'b'),
      ...imageRounds(3),
    ], keep: 3);

    for (final m in out) {
      final wire = m.toWire();
      final content = wire['content'];
      final isEmptyText = content is String && content.trim().isEmpty;
      expect(isEmptyText, isFalse, reason: '空内容发上去会被上游 400');
    }
  });

  test('不修改传进来的列表', () {
    final history = imageRounds(4);
    final before = history.map((m) => m.images.length).toList();
    pruneOldImages(history, keep: 3);
    expect(history.map((m) => m.images.length).toList(), before);
  });

  test('keep 传 0 就把所有的图都摘了', () {
    final out = pruneOldImages(imageRounds(2), keep: 0);
    expect(out.every((m) => m.images.isEmpty), isTrue);
  });

  test('空历史不出事', () {
    expect(pruneOldImages(const []), isEmpty);
  });

  test('摘图之后 origin 还在——提醒消息不能悄悄变成普通消息', () {
    final reminder = ChatMessage(
      id: 'reminder-1',
      role: Role.user,
      content: '提醒我喝水',
      images: [tinyImage('r')],
      origin: MessageOrigin.reminder,
      createdAt: 1,
    );

    // 这条够老（它前面还压着 3 组带图的），所以它的图会被摘掉。
    final out = pruneOldImages([reminder, ...imageRounds(3)], keep: 3);

    final survivor = out.firstWhere((m) => m.id == 'reminder-1');
    expect(survivor.images, isEmpty, reason: '前提：这条确实被摘了图');
    expect(
      survivor.origin,
      MessageOrigin.reminder,
      reason: '摘图只该摘图。origin 掉成 chat 的话，界面那行「提醒 · 15:00」'
          '会凭空消失，而且不报错、不掉字段',
    );
  });

  test('裁完的顺序跟原来一样——答必须在问后面', () {
    final history = [
      userText('第一句'),
      ChatMessage.assistant('第一答'),
      ...imageRounds(4),
    ];

    final out = pruneOldImages(history, keep: 3);

    // 「第 0 张」的图会被摘掉，但它文字还在、位置也不动——所以整串内容
    // 与输入完全一致，只是那条少了一张图。
    expect(
      out.map((m) => m.content).toList(),
      [
        '第一句',
        '第一答',
        '第 0 张',
        '看到了 0',
        '第 1 张',
        '看到了 1',
        '第 2 张',
        '看到了 2',
        '第 3 张',
        '看到了 3',
      ],
      reason: '这个函数唯一的用途就是产出发给模型的 payload；顺序一旦颠倒，'
          '模型看到的是"答在问之前"',
    );
  });
}
