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

  group('recurrence', () {
    Task repeating(Recurrence r, {DateTime? dueAt}) => Task(
          title: 'gym',
          dueAt: dueAt ?? DateTime(2026, 9, 14, 9, 0), // a Monday
          recurrence: r,
          createdAt: DateTime(2026, 9, 1),
        );

    test('defaults to a one off', () {
      expect(_task().recurrence, Recurrence.none);
    });

    test('an unknown stored name degrades to a one off rather than throwing', () {
      final map = _task(id: 1).toMap();
      map['recurrence'] = 'fortnightly';
      expect(Task.fromMap(map).recurrence, Recurrence.none);
    });

    test('a row written before recurrence existed reads as a one off', () {
      final map = _task(id: 1).toMap()..remove('recurrence');
      expect(Task.fromMap(map).recurrence, Recurrence.none);
    });

    test('round trips through the map', () {
      for (final r in Recurrence.values) {
        expect(Task.fromMap(_task(id: 1).copyWith(recurrence: r).toMap())
            .recurrence, r);
      }
    });

    group('nextDueAt', () {
      test('a one off never moves', () {
        final t = repeating(Recurrence.none);
        expect(t.nextDueAt(DateTime(2027, 1, 1)), t.dueAt);
      });

      test('a future first fire is already the next one', () {
        final t = repeating(Recurrence.weekly);
        expect(t.nextDueAt(DateTime(2026, 9, 10)), DateTime(2026, 9, 14, 9, 0));
      });

      test('daily rolls to the next day', () {
        final t = repeating(Recurrence.daily);
        expect(
          t.nextDueAt(DateTime(2026, 9, 16, 12, 0)),
          DateTime(2026, 9, 17, 9, 0),
        );
      });

      test('weekly keeps the same weekday', () {
        final t = repeating(Recurrence.weekly);
        final next = t.nextDueAt(DateTime(2026, 9, 16, 12, 0));
        expect(next, DateTime(2026, 9, 21, 9, 0));
        expect(next.weekday, DateTime.monday);
      });

      test('monthly keeps the same day of month', () {
        final t = repeating(Recurrence.monthly);
        expect(
          t.nextDueAt(DateTime(2026, 9, 20)),
          DateTime(2026, 10, 14, 9, 0),
        );
      });

      test('skips over many missed occurrences at once', () {
        // Left alone for half a year, it must land on the next real one, not
        // step out one week at a time into a wrong answer.
        final t = repeating(Recurrence.weekly);
        final next = t.nextDueAt(DateTime(2027, 3, 1));
        expect(next.isAfter(DateTime(2027, 3, 1)), isTrue);
        expect(next.weekday, DateTime.monday);
        expect(next.hour, 9);
      });

      test('the clock time survives a daylight saving boundary', () {
        // Stepping by calendar date rather than by adding 24 hours is what
        // keeps 09:00 at 09:00 across the change.
        final t = repeating(Recurrence.daily, dueAt: DateTime(2026, 10, 24, 9));
        expect(t.nextDueAt(DateTime(2026, 10, 25, 12)).hour, 9);
      });
    });

    group('isPending', () {
      final now = DateTime(2026, 9, 16, 12, 0);

      test('a repeating task stays pending after its first fire', () {
        expect(repeating(Recurrence.weekly).isPending(now), isTrue);
      });

      test('a one off in the past is not pending', () {
        expect(repeating(Recurrence.none).isPending(now), isFalse);
      });

      test('a done repeating task is not pending', () {
        expect(
          repeating(Recurrence.weekly).copyWith(isDone: true).isPending(now),
          isFalse,
        );
      });
    });
  });

  group('monthly recurrence on awkward days', () {
    Task monthly(int day) => Task(
          title: 'rent',
          dueAt: DateTime(2026, 1, day, 9, 0),
          recurrence: Recurrence.monthly,
          createdAt: DateTime(2026, 1, 1),
        );

    test('the 31st clamps to the last day of a shorter month', () {
      final t = monthly(31);
      // February 2026 has 28 days. Without clamping, DateTime normalises the
      // 31st into March and every later occurrence inherits the drift.
      expect(t.nextDueAt(DateTime(2026, 2, 1)), DateTime(2026, 2, 28, 9, 0));
      expect(t.nextDueAt(DateTime(2026, 4, 1)), DateTime(2026, 4, 30, 9, 0));
    });

    test('and returns to the 31st in a month that has one', () {
      final t = monthly(31);
      // Anchored on the original day, not on the clamped previous result.
      expect(t.nextDueAt(DateTime(2026, 3, 1)), DateTime(2026, 3, 31, 9, 0));
      expect(t.nextDueAt(DateTime(2026, 5, 1)), DateTime(2026, 5, 31, 9, 0));
    });

    test('the 29th survives a non leap February', () {
      expect(monthly(29).nextDueAt(DateTime(2026, 2, 1)),
          DateTime(2026, 2, 28, 9, 0));
    });

    test('crosses a year boundary', () {
      expect(monthly(15).nextDueAt(DateTime(2026, 12, 20)),
          DateTime(2027, 1, 15, 9, 0));
    });

    test('lands correctly years later without stepping month by month', () {
      expect(monthly(15).nextDueAt(DateTime(2031, 6, 20)),
          DateTime(2031, 7, 15, 9, 0));
    });
  });

  group('recurrence far in the past', () {
    test('a daily task set years ago still returns a future date', () {
      // The old implementation gave up after a fixed number of steps and
      // returned a date in the past, which the widget then displayed.
      final t = Task(
        title: 'vitamins',
        dueAt: DateTime(2019, 1, 1, 7, 0),
        recurrence: Recurrence.daily,
        createdAt: DateTime(2019, 1, 1),
      );
      final now = DateTime(2026, 9, 16, 12, 0);
      final next = t.nextDueAt(now);

      expect(next.isAfter(now), isTrue);
      expect(next, DateTime(2026, 9, 17, 7, 0));
    });

    test('a weekly task set years ago keeps its weekday', () {
      final t = Task(
        title: 'bins',
        dueAt: DateTime(2019, 1, 7, 19, 0), // a Monday
        recurrence: Recurrence.weekly,
        createdAt: DateTime(2019, 1, 1),
      );
      final next = t.nextDueAt(DateTime(2026, 9, 16, 12, 0));

      expect(next.isAfter(DateTime(2026, 9, 16, 12, 0)), isTrue);
      expect(next.weekday, DateTime.monday);
      expect(next.hour, 19);
    });
  });
}
