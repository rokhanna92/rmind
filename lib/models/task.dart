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
  final DateTime createdAt;

  /// The moment the notification should fire.
  DateTime get remindAt =>
      dueAt.subtract(Duration(minutes: reminderMinutesBefore));

  /// Whether the reminder is still in the future and worth scheduling.
  bool isPending(DateTime now) => !isDone && remindAt.isAfter(now);

  Task copyWith({
    int? id,
    String? title,
    DateTime? dueAt,
    int? reminderMinutesBefore,
    bool? useAlarm,
    bool? isDone,
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
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at'] as int,
        isUtc: true,
      ).toLocal(),
    );
  }

  @override
  String toString() =>
      'Task(id: $id, title: $title, dueAt: $dueAt, '
      'reminder: ${reminderMinutesBefore}m, alarm: $useAlarm, done: $isDone)';
}
