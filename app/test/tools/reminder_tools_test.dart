import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

void main() {
  final now = DateTime(2026, 9, 25, 20, 30);

  late InMemoryReminderStore store;
  late ToolContext ctx;
  late ReminderCreateTool tool;

  setUp(() {
    store = InMemoryReminderStore();
    ctx = testContext(reminders: store);
    tool = ReminderCreateTool(clock: () => now);
  });

  Future<ToolResult> create(Map<String, Object?> args) => tool.call(args, ctx);

  group('reminder_create', () {
    test('设成功：写进库、回一句带时间的确认', () async {
      final r = await create({
        'fire_at': '2026-09-26 15:00',
        'say': '三点了，作业交了没？',
        'source_text': '明天下午三点提醒我交作业',
      });

      expect(r.ok, isTrue);
      expect(r.content, contains('9月26日 15:00'));

      final saved = await store.pending();
      expect(saved, hasLength(1));
      expect(saved.single.fireAt, DateTime(2026, 9, 26, 15, 0));
      expect(saved.single.message, '三点了，作业交了没？');
      expect(saved.single.sourceText, '明天下午三点提醒我交作业');
    });

    test('source_text 不给就用 say 兜底', () async {
      await create({'fire_at': '2026-09-26 15:00', 'say': '该走了'});
      expect((await store.pending()).single.sourceText, '该走了');
    });

    test('自然语言时间要报错，并说清该写成什么样', () async {
      await expectLater(
        create({'fire_at': '明天下午三点', 'say': 'x'}),
        throwsA(isA<ToolInputException>()),
      );
      expect(await store.count(), 0);
    });

    test('带 Z 的 UTC 写法要拒绝，不能默默差几小时', () async {
      await expectLater(
        create({'fire_at': '2026-09-26T15:00:00Z', 'say': 'x'}),
        throwsA(isA<ToolInputException>()),
      );
    });

    test('过去的时间要报错', () async {
      await expectLater(
        create({'fire_at': '2026-09-25 10:00', 'say': 'x'}),
        throwsA(isA<ToolInputException>()),
      );
      expect(await store.count(), 0);
    });

    test('超过一年要报错（防年份写错）', () async {
      await expectLater(
        create({'fire_at': '2062-09-25 20:31', 'say': 'x'}),
        throwsA(isA<ToolInputException>()),
      );
    });

    test('刚好一年以内是允许的', () async {
      final r = await create({'fire_at': '2027-09-25 20:00', 'say': 'x'});
      expect(r.ok, isTrue);
    });

    test('2 月 30 日这种不存在的日期要报错', () async {
      await expectLater(
        create({'fire_at': '2027-02-30 10:00', 'say': 'x'}),
        throwsA(isA<ToolInputException>()),
      );
    });

    test('25 点 70 分这种越界数字要报错', () async {
      await expectLater(
        create({'fire_at': '2026-09-26 25:70', 'say': 'x'}),
        throwsA(isA<ToolInputException>()),
      );
    });

    test('say 为空要报错', () async {
      await expectLater(
        create({'fire_at': '2026-09-26 15:00', 'say': '   '}),
        throwsA(isA<ToolInputException>()),
      );
    });

    test('say 太长要截断，并在返回里说明', () async {
      final r = await create({
        'fire_at': '2026-09-26 15:00',
        'say': '啊' * 250,
      });

      expect(r.ok, isTrue);
      expect(r.content, contains('截到'));
      expect(
        (await store.pending()).single.message.length,
        kReminderMessageMaxChars,
      );
    });
  });

  group('reminder_list', () {
    const listTool = ReminderListTool();

    test('一条都没有时如实说', () async {
      final r = await listTool.call(const {}, ctx);
      expect(r.ok, isTrue);
      expect(r.content, contains('没有'));
    });

    test('列出还没响的，按时间正序，时间用机器好读的写法', () async {
      await store.save(
        Reminder.create(
          fireAt: DateTime(2026, 9, 27, 9, 0),
          message: '晚的那条',
          sourceText: 'x',
          now: now,
        ),
      );
      await store.save(
        Reminder.create(
          fireAt: DateTime(2026, 9, 26, 15, 0),
          message: '早的那条',
          sourceText: 'x',
          now: now,
        ),
      );

      final r = await listTool.call(const {}, ctx);
      expect(r.content, contains('2026-09-26 15:00'));
      expect(r.content, contains('2026-09-27 09:00'));
      expect(
        r.content.indexOf('2026-09-26'),
        lessThan(r.content.indexOf('2026-09-27')),
      );
    });

    test('默认不列已响的，include_fired 为 true 才列', () async {
      await store.save(
        Reminder.create(
          fireAt: now,
          message: '响过了',
          sourceText: 'x',
          now: now,
        ).copyWith(state: ReminderState.fired, firedAt: now),
      );

      expect((await listTool.call(const {}, ctx)).content, contains('没有'));
      expect(
        (await listTool.call(const {'include_fired': true}, ctx)).content,
        contains('响过了'),
      );
    });
  });
}
