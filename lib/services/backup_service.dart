import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';

import '../data/note_repository.dart';
import '../data/task_repository.dart';
import '../data/workout_repository.dart';
import '../models/note.dart';
import '../models/task.dart';
import '../models/workout_session.dart';

/// A backup that could not be read, with a message written for the user.
///
/// Every message names the thing that was wrong and, where a restore was
/// asked for, says that nothing was written. "Invalid backup" would leave
/// someone holding the only copy of their data with no idea what to do next.
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a backup holds, or what is on the phone right now.
class BackupSummary {
  const BackupSummary({
    required this.tasks,
    required this.sessions,
    required this.notes,
    required this.createdAt,
    required this.appVersion,
  });

  final int tasks;
  final int sessions;
  final int notes;

  /// When the backup was written. For the live totals from
  /// [BackupService.currentTotals] this is simply when they were counted.
  final DateTime createdAt;

  /// The RMIND version that wrote the file, e.g. "1.1.0+2", or
  /// [BackupService.unknownVersion] when it could not be read.
  final String appVersion;

  @override
  String toString() =>
      'BackupSummary($tasks tasks, $sessions sessions, $notes notes, '
      'created $createdAt, app $appVersion)';
}

/// Exports every reminder, workout session and note to one JSON file, and
/// restores them from it.
///
/// The three SQLite files live on one phone and nowhere else, so this is the
/// only thing standing between a lost phone and lost data. Two rules follow
/// from that and shape the whole class:
///
/// * A backup is written from each model's own `toMap` and read back through
///   its `fromMap`. A second, hand written serialisation here would drift from
///   the models and the backup would start quietly lying about what it holds.
/// * [restore] validates the entire payload before it writes anything. A half
///   restore is the worst outcome available: the user cannot tell what they
///   have any more. A clean refusal is recoverable, a half restore is not.
///
/// Restoring does not reschedule notifications. The host calls back into the
/// app after a restore to reload and resync, because the task ids handed out
/// by the insert are new and the OS knows nothing about them yet.
class BackupService {
  BackupService({
    required TaskRepository tasks,
    required WorkoutRepository workouts,
    required NoteRepository notes,
    Future<String> Function()? appVersion,
    Future<Directory> Function()? cacheDirectory,
  }) {
    _tasks = tasks;
    _workouts = workouts;
    _notes = notes;
    _appVersion = appVersion;
    _cacheDirectory = cacheDirectory;
  }

  /// The format this app writes, and the newest it can read.
  static const int formatVersion = 1;

  /// Stands in for the app version when the platform will not say what it is,
  /// which is every test and any host without the plugin.
  static const String unknownVersion = 'unknown';

  late final TaskRepository _tasks;
  late final WorkoutRepository _workouts;
  late final NoteRepository _notes;

  /// Both exist so tests can run without the platform plugins behind
  /// package_info_plus and path_provider. Left unset the real ones are used.
  late final Future<String> Function()? _appVersion;
  late final Future<Directory> Function()? _cacheDirectory;

  /// Everything on the phone, as pretty printed JSON.
  ///
  /// Pretty printed on purpose: the file is the user's own copy of their data
  /// and they may well open it in a text editor to check it is not empty.
  Future<String> exportJson() async {
    final tasks = await _tasks.all();
    final sessions = await _workouts.all();
    final notes = await _notes.all();

    final payload = <String, Object?>{
      'format': formatVersion,
      'app': await _version(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tasks': tasks.map((t) => t.toMap()).toList(),
      'sessions': sessions.map((s) => s.toMap()).toList(),
      'notes': notes.map((n) => n.toMap()).toList(),
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Writes the backup into the app cache and returns the file.
  ///
  /// The cache is the right home for it: the file only has to survive long
  /// enough to be handed to the share sheet, and where it finally lands is the
  /// user's choice, not this app's.
  Future<File> exportToFile() async {
    final json = await exportJson();
    final directory = await _cache();
    final now = DateTime.now();
    final stamp = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final file = File(join(directory.path, 'rmind-backup-$stamp.json'));
    return file.writeAsString(json, flush: true);
  }

  /// Reads a backup without touching the database, so the user can be shown
  /// what they are about to restore before they commit to it.
  ///
  /// Throws a [BackupException] for anything it cannot read, which means the
  /// user finds out the file is damaged while their data is still intact.
  Future<BackupSummary> inspect(String json) async => _parse(json).summary;

  /// Restores a backup and returns what was written.
  ///
  /// With [replaceExisting] every table is emptied first, so the phone ends up
  /// holding exactly what the file holds. Without it the rows are added to
  /// what is already there.
  ///
  /// Ids in the file are never reused. They would collide with live rows, and
  /// a task id doubles as its OS notification id in this app, so a reused id
  /// would hand one reminder another reminder's alarm.
  Future<BackupSummary> restore(
    String json, {
    required bool replaceExisting,
  }) async {
    // Everything is parsed up front. Past this line no row can fail to read,
    // so the writes below cannot stop half way through a damaged file.
    final payload = _parse(json);

    if (replaceExisting) {
      await _wipe();
    }

    // A merge must leave what is on the phone alone, and inserting a session
    // closes whatever is running. The live session is noted here and put back
    // below if this restore closed it, so someone restoring a backup while
    // they are at the gym does not end up with a zero length workout.
    final live = replaceExisting ? null : await _workouts.running();

    for (final task in payload.tasks) {
      await _tasks.add(task);
    }

    // The workout repository has no plain insert: start() is the only way in
    // and it closes whatever session is already running. Finished sessions
    // therefore go first and a still running one last, so nothing this restore
    // has just written gets closed by the next row.
    for (final session in payload.sessions) {
      final inserted = await _workouts.start(
        session.type,
        at: session.startedAt,
      );
      final endedAt = session.endedAt;
      if (endedAt != null) {
        // update() writes the row back verbatim. end() would reject a session
        // the user had already corrected to end before it started, and a
        // backup has to be able to restore whatever the phone actually held.
        await _workouts.update(inserted.endedAtTime(endedAt));
      }
    }

    if (live != null) {
      await _reopenIfClosedByRestore(live);
    }

    for (final note in payload.notes) {
      await _notes.add(note.text, at: note.createdAt);
    }

    return payload.summary;
  }

  /// The three counts as they stand right now, for the backup screen.
  ///
  /// [BackupSummary.createdAt] is just the moment they were counted here.
  Future<BackupSummary> currentTotals() async {
    final tasks = await _tasks.all();
    final sessions = await _workouts.all();
    final notes = await _notes.count();

    return BackupSummary(
      tasks: tasks.length,
      sessions: sessions.length,
      notes: notes,
      createdAt: DateTime.now(),
      appVersion: await _version(),
    );
  }

  /// Puts [live] back the way it was if restoring a session closed it.
  ///
  /// Writes the original row verbatim rather than guessing, so the session the
  /// user is actually in the middle of survives a merge untouched. If the
  /// backup carried a running session of its own, that one is now open too,
  /// which the app already has an answer for: a session left open from an
  /// earlier day reads as stale and is offered up to be closed.
  Future<void> _reopenIfClosedByRestore(WorkoutSession live) async {
    final id = live.id;
    if (id == null) return;

    final now = await _workouts.byId(id);
    if (now == null || now.isRunning) return;
    await _workouts.update(live);
  }

  /// Empties all three tables.
  ///
  /// Row by row because the repositories expose no bulk delete and this is one
  /// phone's worth of reminders, not a dataset.
  Future<void> _wipe() async {
    for (final task in await _tasks.all()) {
      final id = task.id;
      if (id != null) await _tasks.delete(id);
    }
    for (final session in await _workouts.all()) {
      final id = session.id;
      if (id != null) await _workouts.delete(id);
    }
    for (final note in await _notes.all()) {
      final id = note.id;
      if (id != null) await _notes.delete(id);
    }
  }

  Future<Directory> _cache() {
    final override = _cacheDirectory;
    if (override != null) return override();
    return getTemporaryDirectory();
  }

  Future<String> _version() async {
    final override = _appVersion;
    if (override != null) return override();

    try {
      final info = await PackageInfo.fromPlatform();
      final name = info.version.trim();
      final build = info.buildNumber.trim();
      if (name.isEmpty) return unknownVersion;
      return build.isEmpty ? name : '$name+$build';
    } on MissingPluginException {
      return unknownVersion;
    } on PlatformException {
      return unknownVersion;
    }
  }

  /// Reads the whole file into models, or throws naming the first thing that
  /// was wrong with it. The single place [inspect] and [restore] agree, so the
  /// counts shown to the user are exactly the rows a restore would write.
  _Payload _parse(String json) {
    final map = _object(json);
    _checkFormat(map);
    final createdAt = _createdAt(map);

    final taskRows = _rows(map, 'tasks', 'Reminder');
    final sessionRows = _rows(map, 'sessions', 'Workout session');
    final noteRows = _rows(map, 'notes', 'Note');

    final tasks = <Task>[];
    for (var i = 0; i < taskRows.length; i++) {
      tasks.add(_task(taskRows[i], i));
    }

    final finished = <WorkoutSession>[];
    final running = <WorkoutSession>[];
    for (var i = 0; i < sessionRows.length; i++) {
      final session = _session(sessionRows[i], i);
      (session.isRunning ? running : finished).add(session);
    }

    final notes = <Note>[];
    for (var i = 0; i < noteRows.length; i++) {
      notes.add(_note(noteRows[i], i));
    }

    final sessions = [...finished, ...running];
    final app = map['app'];

    return _Payload(
      tasks: tasks,
      sessions: sessions,
      notes: notes,
      summary: BackupSummary(
        tasks: tasks.length,
        sessions: sessions.length,
        notes: notes.length,
        createdAt: createdAt,
        // Lenient where the date is strict: the version label is only ever
        // shown, so a file missing it is still worth restoring.
        appVersion: app is String ? app : unknownVersion,
      ),
    );
  }

  Map<String, Object?> _object(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw BackupException(
        'That file is not valid JSON, so RMIND cannot read it as a backup. '
        'The file says: ${e.message}',
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw BackupException(
        'A RMIND backup is a single JSON object. This file holds '
        '${_describe(decoded)} instead.',
      );
    }
    return decoded;
  }

  void _checkFormat(Map<String, Object?> map) {
    if (!map.containsKey('format')) {
      throw const BackupException(
        'This file has no "format" field, so it is not a RMIND backup.',
      );
    }

    final format = map['format'];
    if (format is! int) {
      throw BackupException(
        'The "format" field should be a whole number, but this file has '
        '${_describe(format)}.',
      );
    }
    if (format > formatVersion) {
      throw BackupException(
        'This backup was made by a newer version of RMIND (format $format). '
        'This app reads format $formatVersion, so update RMIND and try again.',
      );
    }
    if (format < 1) {
      throw BackupException(
        'This backup claims format $format, which no version of RMIND has '
        'ever written.',
      );
    }
  }

  DateTime _createdAt(Map<String, Object?> map) {
    if (!map.containsKey('createdAt')) {
      throw const BackupException(
        'This backup has no "createdAt" date, so it is either damaged or not '
        'a RMIND backup.',
      );
    }

    final value = map['createdAt'];
    if (value is! String) {
      throw BackupException(
        'This backup has a "createdAt" of ${_describe(value)} rather than a '
        'date.',
      );
    }

    // Strict, unlike the rest of the metadata: this is the date the user reads
    // to decide whether this is the right backup, and a guess there could talk
    // someone into replacing good data with old data.
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw BackupException(
        'This backup says it was made at "$value", which is not a date RMIND '
        'can read.',
      );
    }
    return parsed.toLocal();
  }

  List<Map<String, Object?>> _rows(
    Map<String, Object?> map,
    String key,
    String label,
  ) {
    if (!map.containsKey(key)) {
      throw BackupException(
        'This backup has no "$key" section, so it is either damaged or not a '
        'RMIND backup. Nothing was restored.',
      );
    }

    final value = map[key];
    if (value is! List) {
      throw BackupException(
        'The "$key" section of this backup should be a list of rows, but it '
        'holds ${_describe(value)}. Nothing was restored.',
      );
    }

    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < value.length; i++) {
      final row = value[i];
      if (row is! Map<String, Object?>) {
        throw BackupException(
          '$label ${i + 1} in this backup is ${_describe(row)} rather than a '
          'row of fields. Nothing was restored.',
        );
      }
      rows.add(row);
    }
    return rows;
  }

  Task _task(Map<String, Object?> row, int index) {
    const label = 'Reminder';
    _field<String>(row, 'title', label, index);
    _field<int>(row, 'due_at', label, index);
    _field<int>(row, 'reminder_minutes_before', label, index);
    _field<int>(row, 'use_alarm', label, index);
    _field<int>(row, 'is_done', label, index);
    _field<int>(row, 'created_at', label, index);
    return _build(() => Task.fromMap(_withoutId(row)), label, index);
  }

  WorkoutSession _session(Map<String, Object?> row, int index) {
    const label = 'Workout session';
    _field<String>(row, 'type', label, index);
    _field<int>(row, 'started_at', label, index);

    // The only genuinely optional column in any of the three tables: a null
    // ended_at is a session that is still running.
    final ended = row['ended_at'];
    if (ended != null && ended is! int) {
      throw BackupException(
        '$label ${index + 1} in this backup has an "ended_at" of '
        '${_describe(ended)}, which RMIND cannot read. Nothing was restored.',
      );
    }

    return _build(() => WorkoutSession.fromMap(_withoutId(row)), label, index);
  }

  Note _note(Map<String, Object?> row, int index) {
    const label = 'Note';
    final text = _field<String>(row, 'text', label, index);
    _field<int>(row, 'created_at', label, index);

    // Checked here rather than left to the insert, because the note repository
    // refuses blank text and that refusal would land half way through a
    // restore, after other rows had already been written.
    if (text.trim().isEmpty) {
      throw BackupException(
        '$label ${index + 1} in this backup has no text. Nothing was restored.',
      );
    }

    return _build(() => Note.fromMap(_withoutId(row)), label, index);
  }

  /// Reads a required field, naming it if it is missing or the wrong shape.
  T _field<T>(
    Map<String, Object?> row,
    String key,
    String label,
    int index,
  ) {
    final value = row[key];
    if (value is T) return value;

    if (!row.containsKey(key)) {
      throw BackupException(
        '$label ${index + 1} in this backup has no "$key". Nothing was '
        'restored.',
      );
    }
    throw BackupException(
      '$label ${index + 1} in this backup has a "$key" of '
      '${_describe(value)}, which RMIND cannot read. Nothing was restored.',
    );
  }

  /// Builds a model from a row, turning anything the model itself rejects into
  /// a readable failure rather than a raw type error.
  T _build<T>(T Function() build, String label, int index) {
    try {
      return build();
    } on BackupException {
      rethrow;
    } on Object {
      throw BackupException(
        '$label ${index + 1} in this backup could not be read. Nothing was '
        'restored.',
      );
    }
  }

  /// A row without its id, which is how every restored row is inserted.
  Map<String, Object?> _withoutId(Map<String, Object?> row) =>
      Map<String, Object?>.from(row)..remove('id');

  /// Names a JSON value in words the user can act on.
  String _describe(Object? value) {
    if (value == null) return 'nothing';
    if (value is String) return 'text';
    if (value is num) return 'a number';
    if (value is bool) return 'a true or false value';
    if (value is List) return 'a list';
    if (value is Map) return 'a group of fields';
    return 'something RMIND does not recognise';
  }
}

/// A fully validated backup, ready to write.
class _Payload {
  const _Payload({
    required this.tasks,
    required this.sessions,
    required this.notes,
    required this.summary,
  });

  final List<Task> tasks;

  /// Finished sessions first, any running one last. See [BackupService.restore].
  final List<WorkoutSession> sessions;

  final List<Note> notes;
  final BackupSummary summary;
}
