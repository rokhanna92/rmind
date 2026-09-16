import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/models/workout_session.dart';

WorkoutSession _session({
  int? id,
  String type = 'Leg day',
  DateTime? startedAt,
  DateTime? endedAt,
}) {
  return WorkoutSession(
    id: id,
    type: type,
    startedAt: startedAt ?? DateTime(2026, 9, 16, 18, 5),
    endedAt: endedAt,
  );
}

void main() {
  group('running and duration', () {
    test('a session with no end time is running and has no duration', () {
      final s = _session();
      expect(s.isRunning, isTrue);
      expect(s.duration, isNull);
    });

    test('an ended session is not running and reports its length', () {
      final s = _session(endedAt: DateTime(2026, 9, 16, 19, 17));
      expect(s.isRunning, isFalse);
      expect(s.duration, const Duration(hours: 1, minutes: 12));
    });

    test('elapsed counts up from now while running', () {
      final s = _session(startedAt: DateTime(2026, 9, 16, 18, 5));
      expect(
        s.elapsed(DateTime(2026, 9, 16, 18, 52)),
        const Duration(minutes: 47),
      );
    });

    test('elapsed ignores now once the session has ended', () {
      final s = _session(
        startedAt: DateTime(2026, 9, 16, 18, 5),
        endedAt: DateTime(2026, 9, 16, 19, 17),
      );
      // Hours later, the answer must not have moved.
      expect(
        s.elapsed(DateTime(2026, 9, 17, 9, 0)),
        const Duration(hours: 1, minutes: 12),
      );
    });

    test('a session crossing midnight measures the real elapsed time', () {
      final s = _session(
        startedAt: DateTime(2026, 9, 16, 23, 30),
        endedAt: DateTime(2026, 9, 17, 0, 45),
      );
      expect(s.duration, const Duration(hours: 1, minutes: 15));
    });
  });

  group('isStale', () {
    test('an ended session is never stale, however old', () {
      final s = _session(
        startedAt: DateTime(2026, 1, 1, 10, 0),
        endedAt: DateTime(2026, 1, 1, 11, 0),
      );
      expect(s.isStale(DateTime(2026, 9, 16, 12, 0)), isFalse);
    });

    test('a normal running session on the same day is not stale', () {
      final s = _session(startedAt: DateTime(2026, 9, 16, 18, 5));
      expect(s.isStale(DateTime(2026, 9, 16, 19, 30)), isFalse);
    });

    test('running past the six hour limit is stale', () {
      final s = _session(startedAt: DateTime(2026, 9, 16, 8, 0));
      expect(s.isStale(DateTime(2026, 9, 16, 13, 59)), isFalse);
      expect(s.isStale(DateTime(2026, 9, 16, 14, 0)), isTrue);
    });

    test('still running on a later calendar day is stale', () {
      // The real case: left the gym last night without saying so, opened the
      // app in the morning. Only two hours elapsed, but the day has turned.
      final s = _session(startedAt: DateTime(2026, 9, 16, 23, 30));
      expect(s.isStale(DateTime(2026, 9, 17, 1, 30)), isTrue);
    });
  });

  group('ending and reopening', () {
    test('endedAtTime sets the end without disturbing anything else', () {
      final s = _session(id: 3);
      final ended = s.endedAtTime(DateTime(2026, 9, 16, 19, 17));

      expect(ended.id, 3);
      expect(ended.type, 'Leg day');
      expect(ended.startedAt, s.startedAt);
      expect(ended.endedAt, DateTime(2026, 9, 16, 19, 17));
      expect(ended.isRunning, isFalse);
    });

    test('reopened clears the end time, which copyWith cannot do', () {
      final ended = _session(id: 3, endedAt: DateTime(2026, 9, 16, 19, 17));

      // copyWith uses the `?? this` idiom, so passing null keeps the old value.
      // This is the exact trap that caused a data loss bug in the task code.
      expect(ended.copyWith().endedAt, isNotNull);
      expect(ended.reopened().endedAt, isNull);
      expect(ended.reopened().isRunning, isTrue);
      expect(ended.reopened().id, 3);
    });

    test('copyWith changes only what is named', () {
      final s = _session(id: 4);
      final renamed = s.copyWith(type: 'Push day');

      expect(renamed.type, 'Push day');
      expect(renamed.id, 4);
      expect(renamed.startedAt, s.startedAt);
    });
  });

  group('serialisation', () {
    test('round trips a completed session', () {
      final original = _session(
        id: 7,
        type: 'Chest & triceps',
        endedAt: DateTime(2026, 9, 16, 19, 17),
      );
      final restored = WorkoutSession.fromMap(original.toMap());

      expect(restored.id, 7);
      expect(restored.type, 'Chest & triceps');
      expect(restored.startedAt, original.startedAt);
      expect(restored.endedAt, original.endedAt);
    });

    test('round trips a running session, keeping the end null', () {
      final restored = WorkoutSession.fromMap(_session(id: 8).toMap());
      expect(restored.endedAt, isNull);
      expect(restored.isRunning, isTrue);
    });

    test('omits a null id so sqlite assigns one', () {
      expect(_session().toMap().containsKey('id'), isFalse);
      expect(_session(id: 2).toMap()['id'], 2);
    });

    test('stores times as UTC epoch millis', () {
      final s = _session(id: 1, endedAt: DateTime(2026, 9, 16, 19, 17));
      expect(
        s.toMap()['started_at'],
        s.startedAt.toUtc().millisecondsSinceEpoch,
      );
      expect(
        s.toMap()['ended_at'],
        s.endedAt!.toUtc().millisecondsSinceEpoch,
      );
    });

    test('a running session stores a null end rather than a zero', () {
      expect(_session().toMap()['ended_at'], isNull);
    });
  });
}
