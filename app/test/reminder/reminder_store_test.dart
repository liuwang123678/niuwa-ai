import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

void main() {
  final base = DateTime(2026, 9, 25, 12, 0);

  Reminder at(int hoursFromBase, {String say = 'x'}) => Reminder.create(
    fireAt: base.add(Duration(hours: hoursFromBase)),
    message: say,
    sourceText: '原话',
    now: base,
  );

  late InMemoryReminderStore store;

  setUp(() => store = InMemoryReminderStore());

  group('InMemoryReminderStore', () {
    test('存进去能按 id 取回来', () async {
      final r = at(3);
      await store.save(r);

      expect(await store.byId(r.id), isNotNull);
      expect((await store.byId(r.id))!.message, 'x');
      expect(await store.byId('没有这个'), isNull);
    });

    test('同 id 覆盖，不会变成两条', () async {
      final r = at(3);
      await store.save(r);
      await store.save(r.copyWith(message: '改了'));

      expect(await store.count(), 1);
      expect((await store.byId(r.id))!.message, '改了');
    });

    test('pending 按响的时间正序——最早要响的排最前', () async {
      await store.save(at(5));
      await store.save(at(1));
      await store.save(at(3));

      final times = (await store.pending()).map((r) => r.fireAt).toList();
      expect(times, [
        base.add(const Duration(hours: 1)),
        base.add(const Duration(hours: 3)),
        base.add(const Duration(hours: 5)),
      ]);
    });

    test('pending 不含已响和已取消的', () async {
      await store.save(at(1));
      await store.save(at(2).copyWith(state: ReminderState.fired));
      await store.save(at(3).copyWith(state: ReminderState.cancelled));

      final pending = await store.pending();
      expect(pending, hasLength(1));
      expect(pending.single.fireAt, base.add(const Duration(hours: 1)));
    });

    test('fired 按响过的时刻倒序——最近响的排最前', () async {
      final early = at(1).copyWith(
        state: ReminderState.fired,
        firedAt: base.add(const Duration(hours: 1)),
      );
      final late_ = at(2).copyWith(
        state: ReminderState.fired,
        firedAt: base.add(const Duration(hours: 9)),
      );
      await store.save(early);
      await store.save(late_);

      final fired = await store.fired();
      expect(fired.map((r) => r.id).toList(), [late_.id, early.id]);
    });

    test('时间完全并列时用 id 兜底，顺序稳定', () async {
      final a = at(2);
      final b = at(2);
      final c = at(2);
      await store.save(c);
      await store.save(a);
      await store.save(b);

      final ids = (await store.pending()).map((r) => r.id).toList();
      final expected = [a.id, b.id, c.id]..sort();
      expect(ids, expected);
    });

    test('delete 删得掉，删不存在的 id 不抛', () async {
      final r = at(1);
      await store.save(r);
      await store.delete(r.id);
      await store.delete(r.id);

      expect(await store.count(), 0);
    });

    test('limit 为 0 或负数返回空，不是不限量', () async {
      await store.save(at(1));
      expect(await store.pending(limit: 0), isEmpty);
      expect(await store.pending(limit: -1), isEmpty);
      expect(await store.fired(limit: 0), isEmpty);
    });
  });
}
