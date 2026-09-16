/// Something said out loud that has neither a time nor a duration.
///
/// The third shape the app records. Reminders have a moment, workouts have a
/// span, and a note has neither: it is just a thing worth keeping. Before this
/// existed, "the wifi password is hunter2" became a task scheduled for nine
/// tomorrow morning, which is a wrong answer dressed up as a right one.
class Note {
  const Note({this.id, required this.text, required this.createdAt});

  final int? id;

  /// Free text, exactly as spoken. Never parsed, never interpreted.
  final String text;

  final DateTime createdAt;

  /// The first line, for a collapsed row. Notes are dictated rather than
  /// typed, so most are one sentence and this is usually the whole thing.
  String get preview {
    final firstBreak = text.indexOf('\n');
    return firstBreak == -1 ? text : text.substring(0, firstBreak);
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return q.isEmpty || text.toLowerCase().contains(q);
  }

  Note copyWith({int? id, String? text, DateTime? createdAt}) {
    return Note(
      id: id ?? this.id,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Stored as UTC epoch milliseconds, matching every other table here.
  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'text': text,
      'created_at': createdAt.toUtc().millisecondsSinceEpoch,
    };
  }

  factory Note.fromMap(Map<String, Object?> map) {
    return Note(
      id: map['id'] as int?,
      text: map['text'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at'] as int,
        isUtc: true,
      ).toLocal(),
    );
  }

  @override
  String toString() => 'Note(id: $id, created: $createdAt, text: $text)';
}
