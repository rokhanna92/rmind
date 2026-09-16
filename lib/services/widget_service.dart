import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../models/task.dart';
import '../models/workout_session.dart';

/// Pushes a glanceable snapshot of the app to the Android home screen widget.
///
/// Everything that crosses the channel is an already formatted string. The
/// widget is drawn by the launcher from a RemoteViews tree, with no access to
/// this app's formatting helpers and no cheap way to read the user's locale
/// rules, so any date maths on the Kotlin side would be a second
/// implementation that drifts from this one. The single exception is the
/// session start, sent as epoch milliseconds because a Chronometer needs a
/// number to tick from, and ticking in the launcher is exactly what keeps the
/// app asleep.
///
/// Values are strings even where a bool or an int would fit. home_widget maps
/// Dart types onto SharedPreferences types, so a value saved as an int and
/// read back with getLong throws a ClassCastException on the Kotlin side. One
/// type across every key removes that whole class of crash.
class WidgetService {
  /// The provider is addressed by its fully qualified name rather than by
  /// class name, which home_widget would otherwise resolve against the
  /// application id. The two agree today and would stop agreeing the moment a
  /// build adds an application id suffix.
  static const String androidProvider =
      'com.rmind.app.rmind.RmindWidgetProvider';

  // Keys. RmindWidgetProvider reads these exact strings.
  static const String keyWhen = 'rmind_when';
  static const String keyTitle = 'rmind_title';
  static const String keyIsAlarm = 'rmind_is_alarm';
  static const String keySessionRunning = 'rmind_session_running';
  static const String keySessionName = 'rmind_session_name';
  static const String keySessionStartedMs = 'rmind_session_started_ms';
  static const String keyEmpty = 'rmind_empty';

  /// Shown when there is nothing to show. A widget still displaying
  /// yesterday's reminder is worse than one admitting it has nothing.
  static const String emptyMessage = 'Nothing scheduled';

  /// Sends the current state to the widget.
  Future<void> push({
    required Task? nextTask,
    required WorkoutSession? runningSession,
    required DateTime now,
  }) {
    return _write(
      buildData(
        nextTask: nextTask,
        runningSession: runningSession,
        now: now,
      ),
    );
  }

  /// Drops back to the empty state, for a sign out or a wipe.
  Future<void> clear() {
    return _write(
      buildData(nextTask: null, runningSession: null, now: DateTime.now()),
    );
  }

  /// The whole formatting decision, as a pure function.
  ///
  /// Split out because the channel itself cannot be unit tested but this can,
  /// and this is where the bugs would be.
  static Map<String, String> buildData({
    required Task? nextTask,
    required WorkoutSession? runningSession,
    required DateTime now,
  }) {
    // A session that has already ended must not drive a ticking clock, so it
    // is treated as absent rather than trusted from the parameter name.
    final WorkoutSession? session =
        runningSession != null && runningSession.isRunning
            ? runningSession
            : null;

    // nextDueAt covers the one off case by returning dueAt, so a repeating
    // task cannot fall through to the original date by accident.
    final DateTime? due = nextTask?.nextDueAt(now);
    final bool nothing = nextTask == null && session == null;

    return <String, String>{
      keyWhen: due == null ? '' : _whenLine(due, now),
      keyTitle: nextTask?.title ?? '',
      keyIsAlarm: _flag(nextTask?.useAlarm ?? false),
      keySessionRunning: _flag(session != null),
      keySessionName: session == null ? '' : _sessionName(session),
      keySessionStartedMs: session == null
          ? '0'
          : session.startedAt.millisecondsSinceEpoch.toString(),
      keyEmpty: nothing ? emptyMessage : '',
    };
  }

  Future<void> _write(Map<String, String> data) async {
    try {
      for (final MapEntry<String, String> entry in data.entries) {
        await HomeWidget.saveWidgetData<String>(entry.key, entry.value);
      }
      await HomeWidget.updateWidget(qualifiedAndroidName: androidProvider);
    } on MissingPluginException {
      // No platform side at all: a unit test, or a host the widget does not
      // exist on. This runs on every data change, so it absorbs the failure.
    } on PlatformException {
      // Raised when the provider class cannot be resolved or the preferences
      // write is rejected. Same story: a home screen extra is never worth
      // taking the app down for.
    }
  }

  static String _flag(bool value) => value ? 'true' : 'false';

  static String _sessionName(WorkoutSession session) {
    final String type = session.type.trim();
    return type.isEmpty ? WorkoutSession.unnamed : type;
  }

  // Formatting is hand rolled here rather than reused from lib/ui/format.dart:
  // a service must not depend on the UI layer, and the widget wants shorter
  // labels than the app's rows do. The widget's big line is read at arm's
  // length on a 250dp tile, so it drops the "at" and abbreviates weekdays.

  static const List<String> _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// "Today 15:00", "Tomorrow 07:30", "Thu 18:00", "23 Sep 18:30".
  static String _whenLine(DateTime when, DateTime now) =>
      '${_dayLabel(when, now)} ${_two(when.hour)}:${_two(when.minute)}';

  static String _dayLabel(DateTime when, DateTime now) {
    final int diff = _daysBetween(now, when);
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff == -1) return 'Yesterday';
    if (diff > 1 && diff < 7) return _weekdays[when.weekday - 1];
    // The year is carried only when it differs, because without it a date in
    // another year is indistinguishable from the same day this year: a task
    // due 16 Sep 2027 would read "16 Sep" on a tile looked at in Sep 2026.
    final String year = when.year == now.year ? '' : ' ${when.year}';
    return '${when.day} ${_months[when.month - 1]}$year';
  }

  /// Calendar days apart, not elapsed hours. Subtracting durations makes
  /// "tomorrow" 23 or 25 hours away across a daylight saving change, and the
  /// label would then be wrong twice a year.
  static int _daysBetween(DateTime from, DateTime to) {
    final DateTime a = DateTime(from.year, from.month, from.day);
    final DateTime b = DateTime(to.year, to.month, to.day);
    return b.difference(a).inDays;
  }
}
