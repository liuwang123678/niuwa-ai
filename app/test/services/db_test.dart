import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MemoryEntry _entry(
  String content, {
  String id = '',
  int importance = 3,
  int updatedAt = 1000,
  MemoryKind kind = MemoryKind.fact,
  String? subject,
  List<String> tags = const [],
}) => MemoryEntry(
  id: id.isEmpty ? content : id,
  kind: kind,
  content: content,
  subject: subject,
  tags: tags,
  importance: importance,
  createdAt: 1,
  updatedAt: updatedAt,
);

void main() {
  // sqflite 只有移动端有原生实现，桌面/CI 上跑测试得换成 FFI 版的工厂。
  // 这两行写在 setUpAll 里（而不是 setUp）：初始化一次就够，重复设也没意义。
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late SqliteMemoryStore store;

  setUp(() async {
    store = await SqliteMemoryStore.forTesting();
  });

  tearDown(() => store.close());

  group('索引排序（提示缓存的前提）', () {
    test('重要度优先，其次时间新的在前', () async {
      await store.save(_entry('不重要', id: 'a', importance: 1, updatedAt: 100));
      await store.save(_entry('很重要', id: 'b', importance: 5, updatedAt: 100));
      await store.save(_entry('一般', id: 'c', importance: 3, updatedAt: 100));
      await store.save(_entry('同级别但更新', id: 'd', importance: 3, updatedAt: 900));

      final index = await store.index();
      expect(index.map((e) => e.content).toList(), [
        '很重要',
        '同级别但更新',
        '一般',
        '不重要',
      ]);
    });

    test('多次调用顺序完全一致（并列抖动会让提示缓存全灭）', () async {
      // 故意造一批重要度和时间全一样的：没有 id 兜底时 SQLite 返回顺序是没定义的
      final ids = [for (var i = 0; i < 20; i++) 'id${i.toString().padLeft(2, '0')}'];
      for (final id in ids) {
        await store.save(_entry('记忆$id', id: id, updatedAt: 500));
      }

      final first = (await store.index()).map((e) => e.id).toList();
      expect(first, ids); // id 升序兜底，所以是 id00..id19 而不是插入顺序

      for (var round = 0; round < 5; round++) {
        expect((await store.index()).map((e) => e.id).toList(), first);
      }
    });

    test('limit 生效', () async {
      for (var i = 0; i < 30; i++) {
        await store.save(_entry('记忆$i', id: 'id${i.toString().padLeft(2, '0')}'));
      }
      expect((await store.index(limit: 5)).length, 5);
      expect((await store.index(limit: 5)).map((e) => e.id).first, 'id00');
    });
  });

  group('检索', () {
    test('空查询退化成索引，跟 InMemoryMemoryStore 一致', () async {
      await store.save(_entry('低', importance: 1));
      await store.save(_entry('高', importance: 5));

      for (final query in ['', '   ', '\n']) {
        final hits = await store.search(query);
        expect(hits.map((e) => e.content).toList(), ['高', '低'], reason: '查询=$query');
      }
    });

    test('按子串命中（中文不分词）', () async {
      await store.save(_entry('用户不吃香菜'));
      await store.save(_entry('用户喜欢猫'));

      final hits = await store.search('香菜');
      expect(hits.single.content, '用户不吃香菜');
    });

    test('content / subject / tags 三列都参与匹配', () async {
      await store.save(_entry('在准备考研', subject: '学习计划'));
      await store.save(_entry('养了只猫叫团子', tags: ['宠物', '猫']));

      expect((await store.search('学习计划')).single.subject, '学习计划');
      expect((await store.search('宠物')).single.content, contains('团子'));
    });

    test('查不到就返回空，不塞不相干的东西', () async {
      await store.save(_entry('用户不吃香菜'));
      expect(await store.search('量子力学'), isEmpty);
    });

    test('命中掉在标签之间的查询也找得到（SQL 粗筛不许漏）', () async {
      // tags.join(' ') 在 Dart 端是"宠物 猫"，在库里是 ["宠物","猫"]，
      // 两个词一起搜时粗筛最容易漏掉这种行。
      await store.save(_entry('养了只猫叫团子', tags: ['宠物', '猫']));
      final hits = await store.search('宠物 猫');
      expect(hits.single.content, contains('团子'));
    });

    test('排序跟 InMemoryMemoryStore 完全一致（含分数并列的情况）', () async {
      final fixtures = [
        _entry('养猫', id: 'a', importance: 2),
        _entry('养猫很花时间', id: 'b', importance: 5),
        _entry('养猫和养狗', id: 'c', importance: 5),
        _entry('养猫很花时间', id: 'd', importance: 5),
        _entry('完全无关', id: 'e', importance: 5),
      ];
      final memory = InMemoryMemoryStore(fixtures);
      for (final f in fixtures) {
        await store.save(f);
      }

      for (final query in ['养猫', '养', '养猫 花时间', '', '不存在的东西']) {
        expect(
          (await store.search(query)).map((e) => e.id).toList(),
          (await memory.search(query)).map((e) => e.id).toList(),
          reason: '查询="$query" 两个实现的顺序必须一模一样',
        );
      }
    });

    test('limit 生效，且取的是得分最高的几条', () async {
      await store.save(_entry('养猫', id: 'a', importance: 2));
      await store.save(_entry('养猫很花时间', id: 'b', importance: 5));

      expect((await store.search('养猫', limit: 1)).single.id, 'b');
    });
  });

  group('特殊字符（用户搜的是文本，不是模式）', () {
    test('搜 50% 不会命中所有记忆', () async {
      await store.save(_entry('进度 50% 完成'));
      await store.save(_entry('进度 80% 完成'));

      final hits = await store.search('50%');
      expect(hits.map((e) => e.content).toList(), ['进度 50% 完成']);
    });

    test('下划线不会被当成单字符通配符', () async {
      await store.save(_entry('变量叫 a_b'));
      await store.save(_entry('变量叫 axb'));

      final hits = await store.search('a_b');
      expect(hits.single.content, '变量叫 a_b');
    });

    test('反斜杠本身能搜到（不转义的话条件会被悄悄改写）', () async {
      await store.save(_entry(r'路径是 C:\Users\liuwa'));
      await store.save(_entry('路径是 D:/temp'));

      final hits = await store.search(r'\');
      expect(hits.single.content, r'路径是 C:\Users\liuwa');
    });
  });

  group('增删', () {
    test('存、读、数数', () async {
      expect(await store.count(), 0);
      await store.save(_entry('一条'));
      expect(await store.count(), 1);
      await store.delete('一条');
      expect(await store.count(), 0);
    });

    test('同 id 覆盖而不是插两条', () async {
      await store.save(_entry('旧内容', id: 'same'));
      await store.save(_entry('新内容', id: 'same'));

      expect(await store.count(), 1);
      expect((await store.index()).single.content, '新内容');
    });

    test('删不存在的 id 不报错', () async {
      await store.delete('没有这个');
      expect(await store.count(), 0);
    });
  });

  group('往返', () {
    test('所有字段都能原样存下来再读回来', () async {
      final original = MemoryEntry(
        id: 'mem-1',
        kind: MemoryKind.relation,
        content: '用户养了只猫叫团子',
        subject: '用户的猫',
        tags: ['宠物', '猫'],
        importance: 4,
        createdAt: 1000,
        updatedAt: 2000,
        lastUsedAt: 3000,
        useCount: 7,
      );
      await store.save(original);

      final restored = (await store.index()).single;
      expect(restored.id, original.id);
      expect(restored.kind, MemoryKind.relation);
      expect(restored.content, original.content);
      expect(restored.subject, original.subject);
      expect(restored.tags, original.tags);
      expect(restored.importance, original.importance);
      expect(restored.createdAt, original.createdAt);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.lastUsedAt, original.lastUsedAt);
      expect(restored.useCount, original.useCount);
    });

    test('没 subject / 没 lastUsedAt 的行也能读回来', () async {
      await store.save(_entry('随便一条'));
      final restored = (await store.index()).single;
      expect(restored.subject, isNull);
      expect(restored.lastUsedAt, isNull);
      expect(restored.tags, isEmpty);
    });

    test('落盘的 tags 是 JSON 数组字符串', () async {
      await store.save(_entry('带标签', tags: ['宠物', '猫']));
      final rows = await store.rawRowsForTesting();
      expect(rows.single['tags'], '["宠物","猫"]');
    });

    test('一行脏数据不会让整次检索崩掉', () async {
      await store.save(_entry('好的一行'));
      // tags 不是合法 JSON —— 用户导入/旧版本升级都可能留下这种东西
      await store.insertRawForTesting({
        'id': 'broken',
        'kind': 'fact',
        'content': '坏的一行',
        'tags': '这不是 JSON',
        'importance': 3,
        'created_at': 1,
        'updated_at': 1,
        'use_count': 0,
      });

      final index = await store.index();
      expect(index.map((e) => e.id).toList(), ['好的一行']);
      expect(await store.count(), 2); // 脏行还在库里，只是被跳过了
    });
  });
}
