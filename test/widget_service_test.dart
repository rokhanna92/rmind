import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/models/task.dart';
import 'package:rmind/models/workout_session.dart';
import 'package:rmind/services/widget_service.dart';

/// Fixed so the day labels are deterministic. 16 Sep 2026 is a Wednesday.
final DateTime _now = DateTime(2026, 9, 16, 8, 0);

Task _task({
  String title = 'call the dentist',
  DateTime? dueAt,
  bool useAlarm = false,
  Recurrence recurrence = Recurrence.none,
}) {
  return Task(
    id: 1,
    title: title,
    dueAt: dueAt ?? DateTime(2026, 9, 16, 15, 0),
    useAlarm: useAlarm,
    recurrence: recurrence,
    createdAt: DateTime(2026, 9, 1, 12, 0),
  );
}

Map<String, String> _data({
  Task? task,
  WorkoutSession? session,
  DateTime? now,
}) {
  return WidgetService.buildData(
    nextTask: task,
    runningSession: session,
    now: now ?? _now,
  );
}

void main() {
  group('a normal task', () {
    test('sends the when line, the title and no session', () {
      final data = _data(task: _task());

      expect(data[WidgetService.keyWhen], 'Today 15:00');
      expect(data[WidgetService.keyTitle], 'call the dentist');
      expect(data[WidgetService.keyIsAlarm], 'false');
      expect(data[WidgetService.keySessionRunning], 'false');
      expect(data[WidgetService.keySessionName], '');
      expect(data[WidgetService.keySessionStartedMs], '0');
      expect(data[WidgetService.keyEmpty], '');
    });

    test('labels tomorrow and a date further out', () {
      expect(
        _data(task: _task(dueAt: DateTime(2026, 9, 17, 7, 30)))[
            WidgetService.keyWhen],
        'Tomorrow 07:30',
      );
      expect(
        _data(task: _task(dueAt: DateTime(2026, 9, 18, 18, 0)))[
            WidgetService.keyWhen],
        'Fri 18:00',
      );
      expect(
        _data(task: _task(dueAt: DateTime(2026, 10, 2, 9, 5)))[
            WidgetService.keyWhen],
        '2 Oct 09:05',
      );
    });

    test('carries the year only when it is not this one', () {
      // Without the year, a date twelve months out reads as this year's.
      expect(
        _data(task: _task(dueAt: DateTime(2027, 9, 16, 8, 0)))[
            WidgetService.keyWhen],
        '16 Sep 2027 08:00',
      );
    });
  });

  group('a repeating task', () {
    test('uses the next occurrence, not the original due date', () {
      final data = _data(
        task: _task(
          dueAt: DateTime(2026, 9, 10, 7, 0),
          recurrence: Recurrence.daily,
        ),
      );

      // The task started on the 10th, so the original date would read
      // "10 Sep". What matters is the next one.
      expect(data[WidgetService.keyWhen], 'Tomorrow 07:00');
    });

    test('steps past today when today\'s occurrence has gone', () {
      final data = _data(
        task: _task(
          dueAt: DateTime(2026, 9, 2, 7, 0),
          recurrence: Recurrence.weekly,
        ),
      );

      // 07:00 today is already behind [_now], so the next one is a week out.
      expect(data[WidgetService.keyWhen], '23 Sep 07:00');
    });
  });

  group('an alarm task', () {
    test('raises the alarm flag', () {
      final data = _data(task: _task(useAlarm: true));

      expect(data[WidgetService.keyIsAlarm], 'true');
      expect(data[WidgetService.keyWhen], 'Today 15:00');
    });
  });

  group('a running session', () {
    test('sends the name and the start as epoch milliseconds', () {
      final started = DateTime(2026, 9, 16, 7, 12);
      final data = _data(
        task: _task(),
        session: WorkoutSession(type: 'Bicep and shoulder', startedAt: started),
      );

      expect(data[WidgetService.keySessionRunning], 'true');
      expect(data[WidgetService.keySessionName], 'Bicep and shoulder');
      expect(
        data[WidgetService.keySessionStartedMs],
        started.millisecondsSinceEpoch.toString(),
      );
      expect(data[WidgetService.keyEmpty], '');
    });

    test('shows alone when there is no next task', () {
      final data = _data(
        session: WorkoutSession(
          type: 'Legs',
          startedAt: DateTime(2026, 9, 16, 7, 12),
        ),
      );

      expect(data[WidgetService.keySessionRunning], 'true');
      expect(data[WidgetService.keyWhen], '');
      expect(data[WidgetService.keyTitle], '');
      expect(data[WidgetService.keyEmpty], '');
    });

    test('names an untyped session rather than sending a blank line', () {
      final data = _data(
        session: WorkoutSession(
          type: '  ',
          startedAt: DateTime(2026, 9, 16, 7, 12),
        ),
      );

      expect(data[WidgetService.keySessionName], WorkoutSession.unnamed);
    });

    test('ignores a session that has already ended', () {
      final data = _data(
        session: WorkoutSession(
          type: 'Legs',
          startedAt: DateTime(2026, 9, 16, 6, 0),
          endedAt: DateTime(2026, 9, 16, 7, 0),
        ),
      );

      expect(data[WidgetService.keySessionRunning], 'false');
      expect(data[WidgetService.keySessionStartedMs], '0');
      // Nothing left to show, so it must fall back to the empty state rather
      // than leave a finished session on the home screen.
      expect(data[WidgetService.keyEmpty], WidgetService.emptyMessage);
    });
  });

  group('the empty state', () {
    test('sends a message and clears every other field', () {
      final data = _data();

      expect(data[WidgetService.keyEmpty], WidgetService.emptyMessage);
      expect(data[WidgetService.keyWhen], '');
      expect(data[WidgetService.keyTitle], '');
      expect(data[WidgetService.keyIsAlarm], 'false');
      expect(data[WidgetService.keySessionRunning], 'false');
      expect(data[WidgetService.keySessionName], '');
      expect(data[WidgetService.keySessionStartedMs], '0');
    });

    test('writes every key every time, so nothing stale survives', () {
      // The widget reads keys it was not given from the previous push, so a
      // push that omitted a key would leave the old value on screen.
      expect(_data().keys.toSet(), _data(task: _task()).keys.toSet());
    });
  });
}
