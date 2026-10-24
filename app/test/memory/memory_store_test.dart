import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

MemoryEntry _entry(
  String content, {
  String id = '',
  int importance = 3,
  int updatedAt = 1000,
  MemoryKind kind = MemoryKind.fact,
  String? subject,
  List<String> tags = const [],
  int useCount = 0,
}) => MemoryEntry(
  id: id.isEmpty ? content : id,
  kind: kind,
  content: content,
  subject: subject,
  tags: tags,
  importance: importance,
  createdAt: 1,
  updatedAt: updatedAt,
  useCount: useCount,
);

void main() {
  group('索引排序', () {
    test('重要度优先', () async {
      final store = InMemoryMemoryStore([
        _entry('不重要', importance: 1),
        _entry('很重要', importance: 5),
        _entry('一般', importance: 3),
      ]);

      final index = await store.index();
      expect(index.map((e) => e.content).toList(), ['很重要', '一般', '不重要']);
    });

    test('同重要度时新的在前', () async {
      final store = InMemoryMemoryStore([
        _entry('旧的', updatedAt: 100),
        _entry('新的', updatedAt: 900),
      ]);

      final index = await store.index();
      expect(index.map((e) => e.content).toList(), ['新的', '旧的']);
    });

    test('多次调用顺序完全一致（提示缓存的前提）', () async {
      // 故意造一批重要度和时间全一样的，看有没有并列抖动
      final store = InMemoryMemoryStore([
        for (var i = 0; i < 20; i++)
          _entry('记忆$i', id: 'id$i', importance: 3, updatedAt: 500),
      ]);

      final first = (await store.index()).map((e) => e.id).toList();
      for (var round = 0; round < 5; round++) {
        expect((await store.index()).map((e) => e.id).toList(), first);
      }
    });

    test('limit 生效', () async {
      final store = InMemoryMemoryStore([
        for (var i = 0; i < 30; i++) _entry('记忆$i', id: 'id$i'),
      ]);
      expect((await store.index(limit: 5)).length, 5);
    });
  });

  group('检索', () {
    test('按子串命中（中文不分词）', () async {
      final store = InMemoryMemoryStore([
        _entry('用户不吃香菜'),
        _entry('用户喜欢猫'),
      ]);

      final hits = await store.search('香菜');
      expect(hits.single.content, '用户不吃香菜');
    });

    test('命中 subject 和 tags', () async {
      final store = InMemoryMemoryStore([
        _entry('在准备考研', subject: '学习计划'),
        _entry('养了只猫叫团子', tags: ['宠物', '猫']),
      ]);

      expect((await store.search('学习计划')).single.subject, '学习计划');
      expect((await store.search('宠物')).single.content, contains('团子'));
    });

    test('查不到就返回空，不塞不相干的东西', () async {
      final store = InMemoryMemoryStore([_entry('用户不吃香菜')]);
      expect(await store.search('量子力学'), isEmpty);
    });

    test('空查询退化成索引（按重要度排）', () async {
      final store = InMemoryMemoryStore([
        _entry('低', importance: 1),
        _entry('高', importance: 5),
      ]);

      final hits = await store.search('  ');
      expect(hits.first.content, '高');
    });

    test('重要度高的在同等命中下排前面', () async {
      final store = InMemoryMemoryStore([
        _entry('养猫', id: 'a', importance: 2),
        _entry('养猫很花时间', id: 'b', importance: 5),
      ]);

      final hits = await store.search('养猫');
      expect(hits.first.id, 'b');
    });
  });

  group('检索（中文按单字 + 二元组召回）', () {
    test('搜「猫咪」能找到「用户喜欢猫」——纯子串匹配做不到这件事', () async {
      final store = InMemoryMemoryStore([_entry('用户喜欢猫')]);
      final hits = await store.search('猫咪');
      expect(hits.single.content, '用户喜欢猫');
    });

    test('中间夹了别的词也能搜到：搜「不喜欢香菜」命中「用户不吃香菜」', () async {
      final store = InMemoryMemoryStore([_entry('用户不吃香菜')]);
      expect((await store.search('不喜欢香菜')).single.content, '用户不吃香菜');
    });

    test('单字也能搜', () async {
      final store = InMemoryMemoryStore([_entry('用户喜欢猫')]);
      expect((await store.search('猫')).single.content, '用户喜欢猫');
    });

    test('不相干的字别乱捞', () async {
      final store = InMemoryMemoryStore([_entry('用户不吃香菜')]);
      expect(await store.search('量子力学'), isEmpty);
      expect(await store.search('猫咪'), isEmpty);
    });
  });

  group('使用统计', () {
    test('搜到就算用过一次，并记下时间', () async {
      final store = InMemoryMemoryStore([_entry('用户喜欢猫')]);
      await store.search('猫');
      await store.search('猫');

      final e = (await store.all()).single;
      expect(e.useCount, 2);
      expect(e.lastUsedAt, isNotNull);
    });

    test('用户在记忆页里自己搜不算模型用过（track: false）', () async {
      final store = InMemoryMemoryStore([_entry('用户喜欢猫')]);
      await store.search('猫', track: false);
      expect((await store.all()).single.useCount, 0);
    });

    test('用过几次的排在同等重要的前面——但不越过更重要的', () async {
      final store = InMemoryMemoryStore([
        _entry('常用的', id: 'a', importance: 3, updatedAt: 100, useCount: 5),
        _entry('新的', id: 'b', importance: 3, updatedAt: 900),
        _entry('最重要的', id: 'c', importance: 5, updatedAt: 1),
      ]);

      final index = await store.index();
      expect(index.map((e) => e.id).toList(), ['c', 'a', 'b']);
    });
  });

  group('保存去重', () {
    test('同一句话只差标点：更新原条，不堆第二条', () async {
      final store = InMemoryMemoryStore();
      final first = MemoryEntry.create(
        kind: MemoryKind.preference,
        content: '用户不吃香菜',
        subject: '用户本人',
        now: 1000,
      );
      await store.saveSmart(first);

      final again = MemoryEntry.create(
        kind: MemoryKind.preference,
        content: '用户不吃香菜。',
        subject: '用户本人',
        now: 2000,
      );
      final result = await store.saveSmart(again);

      expect(result.action, MemorySaveAction.updated);
      expect(result.entry.id, first.id);
      expect(await store.count(), 1);
      expect((await store.all()).single.updatedAt, 2000);
    });

    test('新内容把旧内容包住了：用新的覆盖', () async {
      final store = InMemoryMemoryStore();
      await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.preference,
          content: '用户不吃香菜',
          subject: '用户本人',
          now: 1000,
        ),
      );

      final result = await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.preference,
          content: '用户不吃香菜和葱',
          subject: '用户本人',
          now: 2000,
        ),
      );

      expect(result.action, MemorySaveAction.updated);
      expect((await store.all()).single.content, '用户不吃香菜和葱');
    });

    test('类别不同就不合并——事实和偏好是两回事', () async {
      final store = InMemoryMemoryStore();
      await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '用户不吃香菜',
          subject: '用户本人',
          now: 1000,
        ),
      );
      final result = await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.preference,
          content: '用户不吃香菜',
          subject: '用户本人',
          now: 2000,
        ),
      );

      expect(result.action, MemorySaveAction.created);
      expect(await store.count(), 2);
    });

    test('主题不同就不合并——两只猫可以同时存在', () async {
      final store = InMemoryMemoryStore();
      await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '养了一只猫叫团子',
          subject: '用户的猫',
          now: 1000,
        ),
      );
      final result = await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '养了一只猫叫年糕',
          subject: '用户的猫二号',
          now: 2000,
        ),
      );

      expect(result.action, MemorySaveAction.created);
      expect(await store.count(), 2);
    });

    test('长得像但不确定：照样存下，同时把旧的报回去让人确认', () async {
      final store = InMemoryMemoryStore();
      await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '用户在准备考研数学',
          subject: '学习计划',
          now: 1000,
        ),
      );

      final result = await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '用户在准备考研英语',
          subject: '学习计划',
          now: 2000,
        ),
      );

      expect(result.action, MemorySaveAction.needsReview);
      expect(result.similar?.content, '用户在准备考研数学');
      // **不丢信息**：候选没确认之前，新的这条已经存下来了。
      expect(await store.count(), 2);
    });

    test('模型明确给了 replace_id：合并那一条，id 不变', () async {
      final store = InMemoryMemoryStore();
      final old = MemoryEntry.create(
        kind: MemoryKind.fact,
        content: '用户在准备考研数学',
        subject: '学习计划',
        now: 1000,
      );
      await store.saveSmart(old);

      final result = await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '用户改考计算机了',
          subject: '学习计划',
          now: 2000,
        ),
        replaceId: old.id,
      );

      expect(result.action, MemorySaveAction.updated);
      expect(await store.count(), 1);
      expect((await store.all()).single.id, old.id);
      expect((await store.all()).single.content, '用户改考计算机了');
    });

    test('replace_id 指向不存在的记忆：不报错，当普通新增', () async {
      final store = InMemoryMemoryStore();
      final result = await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.fact,
          content: '随便',
          now: 1000,
        ),
        replaceId: '没这个id',
      );
      expect(result.action, MemorySaveAction.created);
      expect(await store.count(), 1);
    });

    test('合并时标签取并集、重要度取大的', () async {
      final store = InMemoryMemoryStore();
      await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.preference,
          content: '用户不吃香菜',
          subject: '用户本人',
          tags: ['饮食'],
          importance: 2,
          now: 1000,
        ),
      );
      await store.saveSmart(
        MemoryEntry.create(
          kind: MemoryKind.preference,
          content: '用户不吃香菜和葱',
          subject: '用户本人',
          tags: ['饮食', '忌口'],
          importance: 4,
          now: 2000,
        ),
      );

      final e = (await store.all()).single;
      expect(e.tags, ['饮食', '忌口']);
      expect(e.importance, 4);
    });
  });

  group('容量淘汰', () {
    test('超过上限时先扔最不重要、最没用的', () async {
      final store = InMemoryMemoryStore();
      await store.save(_entry('最不重要', id: 'low', importance: 1));
      await store.save(_entry('中等', id: 'mid', importance: 2));
      await store.save(_entry('重要', id: 'high', importance: 3));
      await store.save(_entry('强调过的', id: 'top', importance: 5));

      await store.saveSmart(
        _entry('新来的', id: 'new', importance: 4),
        maxEntries: 4,
      );

      final ids = (await store.all()).map((e) => e.id).toSet();
      expect(ids.length, 4);
      expect(ids.contains('low'), isFalse);
      expect(ids.contains('top'), isTrue);
    });

    test('重要度 5 的永远不淘汰，哪怕超上限', () async {
      final store = InMemoryMemoryStore();
      for (var i = 0; i < 3; i++) {
        await store.save(_entry('强调过$i', id: 'top$i', importance: 5));
      }
      await store.saveSmart(_entry('新的', id: 'new', importance: 5), maxEntries: 2);
      expect(await store.count(), 4);
    });

    test('没超上限什么都不动', () async {
      final store = InMemoryMemoryStore();
      await store.save(_entry('旧的', id: 'old', importance: 1));
      await store.saveSmart(_entry('新的', id: 'new', importance: 2), maxEntries: 500);
      expect(await store.count(), 2);
    });
  });

  group('增删', () {
    test('存和删', () async {
      final store = InMemoryMemoryStore();
      expect(await store.count(), 0);

      await store.save(_entry('一条'));
      expect(await store.count(), 1);

      await store.delete('一条');
      expect(await store.count(), 0);
    });
  });

  group('序列化', () {
    test('往返一致', () {
      final original = MemoryEntry.create(
        kind: MemoryKind.preference,
        content: '用户不吃香菜',
        subject: '用户本人',
        tags: ['饮食'],
        importance: 4,
        now: 12345,
      );

      final restored = MemoryEntry.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.kind, MemoryKind.preference);
      expect(restored.content, original.content);
      expect(restored.subject, original.subject);
      expect(restored.tags, original.tags);
      expect(restored.importance, original.importance);
    });

    test('索引行的格式稳定（带日期，精确到天）', () {
      final e = _entry('用户不吃香菜', subject: '用户本人');
      expect(e.toIndexLine(), '- [fact][1970-01-01]（用户本人） 用户不吃香菜');
    });

    test('没 subject 时不出现空括号', () {
      expect(_entry('随便').toIndexLine(), '- [fact][1970-01-01] 随便');
    });

    test('没有时间戳时不硬塞一个 1970', () {
      final e = _entry('随手记', updatedAt: 0);
      expect(e.toIndexLine(), '- [fact] 随手记');
    });
  });

  test('重要度会被夹到 1..5', () {
    expect(
      MemoryEntry.create(kind: MemoryKind.fact, content: 'x', importance: 99)
          .importance,
      5,
    );
    expect(
      MemoryEntry.create(kind: MemoryKind.fact, content: 'x', importance: -3)
          .importance,
      1,
    );
  });
}
