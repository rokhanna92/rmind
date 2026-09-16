/// How often a reminder comes back.
///
/// Deliberately only the three shapes the notification plugin can repeat by
/// itself: it matches on time, on weekday plus time, or on day of month plus
/// time. Anything richer, "every second Tuesday", would mean the app
/// rescheduling by hand after each fire, which does not survive being force
/// stopped. Better to have three that always work than five that mostly do.
enum Recurrence {
  none,
  daily,
  weekly,
  monthly;

  static Recurrence fromName(String? value) {
    return Recurrence.values.firstWhere(
      (r) => r.name == value,
      orElse: () => Recurrence.none,
    );
  }

  bool get repeats => this != Recurrence.none;

  /// How the editor and the list rows say it.
  String get label => switch (this) {
        Recurrence.none => 'Once',
        Recurrence.daily => 'Every day',
        Recurrence.weekly => 'Every week',
        Recurrence.monthly => 'Every month',
      };
}

/// A single reminder task.
///
/// [dueAt] is the moment the thing actually happens. The reminder fires
/// [reminderMinutesBefore] minutes ahead of it, either as an ordinary
/// notification or, when [useAlarm] is set, as a loud alarm.
class Task {
  const Task({
    this.id,
    required this.title,
    required this.dueAt,
    this.reminderMinutesBefore = defaultReminderMinutes,
    this.useAlarm = false,
    this.isDone = false,
    this.recurrence = Recurrence.none,
    required this.createdAt,
  });

  /// Default lead time, matching the "remind me 30 minutes before" case.
  static const int defaultReminderMinutes = 30;

  /// Default lead time when the task is escalated to an alarm.
  static const int defaultAlarmMinutes = 10;

  /// Null until the row has been inserted. Once set it doubles as the
  /// notification id, which is why it must stay stable for the task's life.
  final int? id;

  final String title;
  final DateTime dueAt;
  final int reminderMinutesBefore;
  final bool useAlarm;
  final bool isDone;

  /// A repeating task is never finished, only snoozed until the next one, so
  /// completing one is handled differently from completing a one off.
  final Recurrence recurrence;

  final DateTime createdAt;

  /// The moment the notification should fire.
  DateTime get remindAt =>
      dueAt.subtract(Duration(minutes: reminderMinutesBefore));

  /// Whether the reminder is still in the future and worth scheduling.
  ///
  /// A repeating task stays pending once its first fire has passed, because
  /// the OS keeps firing it on the matching component rather than once.
  bool isPending(DateTime now) =>
      !isDone && (recurrence.repeats || remindAt.isAfter(now));

  /// The next time this fires at or after [from].
  ///
  /// Used by the list, the widget and the scheduler, which must all agree on
  /// when this next happens rather than showing the original date, which for a
  /// weekly task may be months ago. They share this one method precisely so
  /// they cannot disagree.
  DateTime nextDueAt(DateTime from) {
    if (!recurrence.repeats || dueAt.isAfter(from)) return dueAt;

    // Jumped most of the way in one calculation, then stepped for the
    // remainder. The jump keeps this cheap for a task set years ago, and the
    // steps absorb daylight saving and short months rather than assuming every
    // period is the same length.
    if (recurrence == Recurrence.monthly) {
      var months = (from.year - dueAt.year) * 12 + (from.month - dueAt.month);
      if (months < 0) months = 0;
      var next = _addMonths(dueAt, months);
      while (!next.isAfter(from)) {
        next = _addMonths(dueAt, ++months);
      }
      return next;
    }

    final step = recurrence == Recurrence.daily ? 1 : 7;
    var periods = from.difference(dueAt).inDays ~/ step;
    if (periods < 0) periods = 0;
    var next = _addDays(dueAt, periods * step);
    while (!next.isAfter(from)) {
      next = _addDays(dueAt, ++periods * step);
    }
    return next;
  }

  /// Calendar arithmetic, not a Duration, so the clock time survives a
  /// daylight saving change instead of drifting by an hour.
  static DateTime _addDays(DateTime base, int days) =>
      DateTime(base.year, base.month, base.day + days, base.hour, base.minute);

  /// [months] later, always anchored on the ORIGINAL day of the month and
  /// clamped to the length of the target month.
  ///
  /// DateTime normalises an out of range day, so the 31st plus a month became
  /// the 1st of the month after, and every later occurrence inherited the
  /// drift. Anchoring on the original day means the 31st shows as the 30th in
  /// June and returns to the 31st in July.
  static DateTime _addMonths(DateTime base, int months) {
    final total = base.month - 1 + months;
    final year = base.year + (total ~/ 12);
    final month = total % 12 + 1;
    // Day zero of the following month is the last day of this one.
    final lastDay = DateTime(year, month + 1, 0).day;
    final day = base.day < lastDay ? base.day : lastDay;
    return DateTime(year, month, day, base.hour, base.minute);
  }

  Task copyWith({
    int? id,
    String? title,
    DateTime? dueAt,
    int? reminderMinutesBefore,
    bool? useAlarm,
    bool? isDone,
    Recurrence? recurrence,
    DateTime? createdAt,
  }) {
    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      dueAt: dueAt ?? this.dueAt,
      reminderMinutesBefore:
          reminderMinutesBefore ?? this.reminderMinutesBefore,
      useAlarm: useAlarm ?? this.useAlarm,
      isDone: isDone ?? this.isDone,
      recurrence: recurrence ?? this.recurrence,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Times are stored as UTC epoch milliseconds so the rows stay correct if
  /// the device changes timezone, and are converted back to local on read.
  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'due_at': dueAt.toUtc().millisecondsSinceEpoch,
      'reminder_minutes_before': reminderMinutesBefore,
      'use_alarm': useAlarm ? 1 : 0,
      'is_done': isDone ? 1 : 0,
      'recurrence': recurrence.name,
      'created_at': createdAt.toUtc().millisecondsSinceEpoch,
    };
  }

  factory Task.fromMap(Map<String, Object?> map) {
    return Task(
      id: map['id'] as int?,
      title: map['title'] as String,
      dueAt: DateTime.fromMillisecondsSinceEpoch(
        map['due_at'] as int,
        isUtc: true,
      ).toLocal(),
      reminderMinutesBefore: map['reminder_minutes_before'] as int,
      useAlarm: (map['use_alarm'] as int) == 1,
      isDone: (map['is_done'] as int) == 1,
      // Read leniently: rows written before recurrence existed have no column
      // value, and an unknown name must degrade to a one off rather than throw.
      recurrence: Recurrence.fromName(map['recurrence'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at'] as int,
        isUtc: true,
      ).toLocal(),
    );
  }

  @override
  String toString() =>
      'Task(id: $id, title: $title, dueAt: $dueAt, '
      'reminder: ${reminderMinutesBefore}m, alarm: $useAlarm, done: $isDone, '
      'recurrence: ${recurrence.name})';
}
