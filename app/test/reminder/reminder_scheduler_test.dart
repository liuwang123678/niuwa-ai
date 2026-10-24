import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 提醒调度。
///
/// 全用假时钟 + 内存库：真等 15 秒一轮的测试跑一轮要几分钟，而这里要验的是
/// "该不该响""响几次""补不补",跟真实时间没关系。
void main() {
  late InMemoryReminderStore store;
  late DateTime now;
  late List<Reminder> fired;

  setUp(() {
    store = InMemoryReminderStore();
    now = DateTime(2026, 10, 17, 9);
    fired = [];
  });

  ReminderScheduler make({
    Future<String?> Function(Reminder)? onFire,
    Duration tick = const Duration(hours: 1),
  }) => ReminderScheduler(
    store: store,
    onFire: onFire ?? (r) async {
      fired.add(r);
      return null;
    },
    clock: () => now,
    tick: tick,
  );

  Reminder at(Duration offset, {String message = '该喝水了'}) => Reminder.create(
    fireAt: now.add(offset),
    message: message,
    sourceText: message,
    now: now,
  );

  test('到点的那条变成已响，还没到的不动', () async {
    final due = at(const Duration(minutes: -1));
    final future = at(const Duration(hours: 1));
    await store.save(due);
    await store.save(future);

    final scheduler = make();
    await scheduler.checkNow();

    expect(fired.map((r) => r.id), [due.id]);
    expect((await store.byId(due.id))!.state, ReminderState.fired);
    expect((await store.byId(future.id))!.state, ReminderState.pending);
  });

  test('响过之后不再重复响', () async {
    await store.save(at(const Duration(minutes: -1)));
    final scheduler = make();

    await scheduler.checkNow();
    await scheduler.checkNow();

    expect(fired, hasLength(1));
  });

  test('App 没开着时到点的，start 之后立刻补响', () async {
    await store.save(at(const Duration(hours: -3), message: '昨天交代的事'));

    final scheduler = make();
    scheduler.start();
    // start 里的第一轮 checkNow 是 unawaited 的，让它跑完。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await scheduler.dispose();

    expect(fired.map((r) => r.message), ['昨天交代的事']);
    expect(fired.single.firedAt, now, reason: '补响的 firedAt 应该是"现在"，不是原定的时间');
  });

  test('onFire 抛异常也算响过，不会每轮重复烦用户', () async {
    await store.save(at(const Duration(minutes: -1)));

    final scheduler = make(
      onFire: (r) async => throw StateError('落库失败了'),
    );
    await scheduler.checkNow();
    await scheduler.checkNow();

    expect(await store.pending(), isEmpty, reason: '应该已经不 pending 了');
    expect(await store.count(), 1, reason: '提醒本身还在，只是标记成已响');
  });

  test('回调返回的消息 id 记回提醒上', () async {
    final r = at(const Duration(minutes: -1));
    await store.save(r);

    final scheduler = make(onFire: (_) async => 'msg-1');
    await scheduler.checkNow();

    expect((await store.byId(r.id))!.messageId, 'msg-1');
  });

  test('同一条只响一次：两轮重叠时也不会重复', () async {
    await store.save(at(const Duration(minutes: -1)));

    var calls = 0;
    final scheduler = make(
      onFire: (_) async {
        calls++;
        // 故意拖一下，让第二轮 checkNow 撞进来
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return null;
      },
    );

    await Future.wait([scheduler.checkNow(), scheduler.checkNow()]);

    expect(calls, 1);
  });

  test('存了新提醒之后手动查一次，立刻就能响', () async {
    final scheduler = make();
    await scheduler.checkNow();
    expect(fired, isEmpty);

    await store.save(at(const Duration(seconds: -1)));
    await scheduler.checkNow();

    expect(fired, hasLength(1));
  });

  test('dispose 之后不再响', () async {
    await store.save(at(const Duration(minutes: -1)));
    final scheduler = make();
    await scheduler.dispose();
    await scheduler.checkNow();

    expect(fired, isEmpty);
  });

  test('空库不报错', () async {
    final scheduler = make();
    await scheduler.checkNow();
    expect(fired, isEmpty);
  });
}
