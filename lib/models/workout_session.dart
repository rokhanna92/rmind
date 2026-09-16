/// One visit to the gym.
///
/// A session with a null [endedAt] is still running. There is at most one of
/// those at a time, which the repository enforces rather than the UI.
class WorkoutSession {
  const WorkoutSession({
    this.id,
    required this.type,
    required this.startedAt,
    this.endedAt,
  });

  /// How long a running session may go before the app stops believing it and
  /// offers to close it. Six hours is well past any real workout but short
  /// enough to catch one left open at bedtime.
  static const Duration staleAfter = Duration(hours: 6);

  /// Used when the user said they arrived but not what they were training.
  static const String unnamed = 'Workout';

  final int? id;

  /// What is being trained, e.g. "Bicep and shoulder". Free text, since the
  /// user says it out loud and the model just capitalises it.
  final String type;

  final DateTime startedAt;

  /// Null while the session is running.
  final DateTime? endedAt;

  bool get isRunning => endedAt == null;

  /// Final length, or null while still running.
  Duration? get duration => endedAt?.difference(startedAt);

  /// Length so far, which is the final length once ended.
  Duration elapsed(DateTime now) => (endedAt ?? now).difference(startedAt);

  /// A running session the app should stop trusting: either it has run past
  /// [staleAfter], or it started on an earlier calendar day. The second test
  /// catches the real case, someone leaving the gym without saying so and
  /// opening the app the next morning.
  bool isStale(DateTime now) {
    if (!isRunning) return false;
    if (now.difference(startedAt) >= staleAfter) return true;
    final startDay = DateTime(startedAt.year, startedAt.month, startedAt.day);
    final today = DateTime(now.year, now.month, now.day);
    return today.isAfter(startDay);
  }

  WorkoutSession copyWith({
    int? id,
    String? type,
    DateTime? startedAt,
    DateTime? endedAt,
  }) {
    return WorkoutSession(
      id: id ?? this.id,
      type: type ?? this.type,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
    );
  }

  /// Ends the session. Separate from [copyWith] because copyWith cannot set a
  /// nullable field back to null, and confusing the two has already caused one
  /// data loss bug in this codebase.
  WorkoutSession endedAtTime(DateTime when) => WorkoutSession(
        id: id,
        type: type,
        startedAt: startedAt,
        endedAt: when,
      );

  /// Reopens a session, clearing the end time.
  WorkoutSession reopened() =>
      WorkoutSession(id: id, type: type, startedAt: startedAt);

  /// Times are stored as UTC epoch milliseconds, matching the tasks table, so
  /// rows stay correct across a timezone change.
  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'type': type,
      'started_at': startedAt.toUtc().millisecondsSinceEpoch,
      'ended_at': endedAt?.toUtc().millisecondsSinceEpoch,
    };
  }

  factory WorkoutSession.fromMap(Map<String, Object?> map) {
    final ended = map['ended_at'] as int?;
    return WorkoutSession(
      id: map['id'] as int?,
      type: map['type'] as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        map['started_at'] as int,
        isUtc: true,
      ).toLocal(),
      endedAt: ended == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ended, isUtc: true).toLocal(),
    );
  }

  @override
  String toString() =>
      'WorkoutSession(id: $id, type: $type, started: $startedAt, '
      'ended: $endedAt)';
}
