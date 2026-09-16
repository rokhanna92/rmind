import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/models/task.dart';

Task _task({
  int? id,
  DateTime? dueAt,
  int lead = Task.defaultReminderMinutes,
  bool useAlarm = false,
  bool isDone = false,
}) {
  return Task(
    id: id,
    title: 'call the dentist',
    dueAt: dueAt ?? DateTime(2026, 9, 17, 15, 0),
    reminderMinutesBefore: lead,
    useAlarm: useAlarm,
    isDone: isDone,
    createdAt: DateTime(2026, 9, 16, 12, 0),
  );
}

void main() {
  group('remindAt', () {
    test('subtracts the lead time from the due time', () {
      expect(
        _task(lead: 30).remindAt,
        DateTime(2026, 9, 17, 14, 30),
      );
    });

    test('a zero lead means the reminder fires at the due time', () {
      expect(_task(lead: 0).remindAt, DateTime(2026, 9, 17, 15, 0));
    });

    test('crosses midnight backwards correctly', () {
      final t = _task(dueAt: DateTime(2026, 9, 17, 0, 15), lead: 30);
      expect(t.remindAt, DateTime(2026, 9, 16, 23, 45));
    });

    test('a 24 hour lead lands on the previous day', () {
      final t = _task(lead: 1440);
      expect(t.remindAt, DateTime(2026, 9, 16, 15, 0));
    });
  });

  group('isPending', () {
    final now = DateTime(2026, 9, 16, 12, 0);

    test('true when the reminder is still ahead', () {
      expect(_task(dueAt: DateTime(2026, 9, 16, 13, 0), lead: 30).isPending(now),
          isTrue);
    });

    test('false once the reminder time has passed, even if due is ahead', () {
      // Due in 20 minutes with a 30 minute lead, so the reminder moment is
      // already 10 minutes gone. Scheduling this would never fire.
      final t = _task(dueAt: DateTime(2026, 9, 16, 12, 20), lead: 30);
      expect(t.remindAt.isBefore(now), isTrue);
      expect(t.isPending(now), isFalse);
    });

    test('false when done regardless of timing', () {
      final t = _task(
        dueAt: DateTime(2026, 9, 20, 10, 0),
        isDone: true,
      );
      expect(t.isPending(now), isFalse);
    });
  });

  group('serialisation', () {
    test('round trips every field', () {
      final original = _task(id: 7, lead: 45, useAlarm: true, isDone: true);
      final restored = Task.fromMap(original.toMap());

      expect(restored.id, 7);
      expect(restored.title, original.title);
      expect(restored.dueAt, original.dueAt);
      expect(restored.reminderMinutesBefore, 45);
      expect(restored.useAlarm, isTrue);
      expect(restored.isDone, isTrue);
      expect(restored.createdAt, original.createdAt);
    });

    test('omits a null id so sqlite can assign one', () {
      expect(_task().toMap().containsKey('id'), isFalse);
      expect(_task(id: 3).toMap()['id'], 3);
    });

    test('stores times as UTC epoch millis', () {
      final t = _task(id: 1);
      expect(t.toMap()['due_at'], t.dueAt.toUtc().millisecondsSinceEpoch);
    });

    test('booleans are stored as sqlite integers', () {
      final map = _task(useAlarm: true, isDone: false).toMap();
      expect(map['use_alarm'], 1);
      expect(map['is_done'], 0);
    });
  });

  group('copyWith', () {
    test('changes only what is named', () {
      final original = _task(id: 4, lead: 30);
      final copy = original.copyWith(title: 'book the car service');

      expect(copy.title, 'book the car service');
      expect(copy.id, 4);
      expect(copy.dueAt, original.dueAt);
      expect(copy.reminderMinutesBefore, 30);
    });
  });
}
