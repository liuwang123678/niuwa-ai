import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

void main() {
  final fireAt = DateTime(2026, 9, 26, 15, 0);
  final now = DateTime(2026, 9, 25, 20, 30);

  Reminder make() => Reminder.create(
    fireAt: fireAt,
    message: '三点了，作业交了没？',
    sourceText: '明天下午三点提醒我交作业',
    now: now,
  );

  group('Reminder', () {
    test('create 默认是待响的一次性提醒', () {
      final r = make();
      expect(r.id, startsWith('rem_'));
      expect(r.kind, ReminderKind.once);
      expect(r.state, ReminderState.pending);
      expect(r.isPending, isTrue);
      expect(r.createdAt, now);
      expect(r.firedAt, isNull);
      expect(r.messageId, isNull);
    });

    test('toJson / fromJson 往返，字段一个不丢', () {
      final r = make().copyWith(
        state: ReminderState.fired,
        firedAt: fireAt,
        messageId: 'msg_abc',
      );
      final back = Reminder.fromJson(r.toJson());

      expect(back.id, r.id);
      expect(back.fireAt, r.fireAt);
      expect(back.message, r.message);
      expect(back.sourceText, r.sourceText);
      expect(back.kind, r.kind);
      expect(back.state, r.state);
      expect(back.createdAt, r.createdAt);
      expect(back.firedAt, r.firedAt);
      expect(back.messageId, r.messageId);
    });

    test('没响过的提醒往返后 firedAt / messageId 仍是 null', () {
      final back = Reminder.fromJson(make().toJson());
      expect(back.firedAt, isNull);
      expect(back.messageId, isNull);
    });

    test('kind / state 认不出时退回默认，不丢整条', () {
      final json = make().toJson()
        ..['kind'] = '每周三'
        ..['state'] = '???';
      final back = Reminder.fromJson(json);

      expect(back.kind, ReminderKind.once);
      expect(back.state, ReminderState.pending);
      // 类型认不出只是个分类问题，时间和内容必须还在
      expect(back.fireAt, fireAt);
      expect(back.message, '三点了，作业交了没？');
    });

    test('时间列坏掉时退回 epoch 0，不抛', () {
      final json = make().toJson()
        ..['fire_at'] = '明天下午三点'
        ..['created_at'] = null;

      final back = Reminder.fromJson(json);
      expect(back.fireAt, DateTime.fromMillisecondsSinceEpoch(0));
      expect(back.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('copyWith 保留 id、kind、createdAt', () {
      final r = make();
      final later = r.copyWith(state: ReminderState.cancelled);

      expect(later.id, r.id);
      expect(later.kind, r.kind);
      expect(later.createdAt, r.createdAt);
      expect(later.state, ReminderState.cancelled);
      expect(later.isPending, isFalse);
    });
  });
}
