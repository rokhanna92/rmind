import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart';

import '../models/workout_session.dart';

/// SQLite-backed storage for [WorkoutSession].
///
/// Deliberately a second database file rather than a new table inside
/// 'rmind.db'. The user already has reminder data in that file and nothing here
/// joins against it, so a separate file buys the same result without a schema
/// migration that could only ever lose rows.
class WorkoutRepository {
  /// [factory] and [path] exist so tests can point at an in-memory database.
  /// Left unset, the repository opens the real file on the device.
  WorkoutRepository({DatabaseFactory? factory, String? path}) {
    // Named parameters cannot be private initializing formals, so these are
    // assigned here rather than in the initializer list.
    _factory = factory;
    _path = path;
  }

  static const String _table = 'sessions';
  static const String _fileName = 'rmind_workouts.db';
  static const int _version = 1;

  late final DatabaseFactory? _factory;
  late final String? _path;

  Database? _db;

  /// The in-flight open, so overlapping init() calls share one connection
  /// instead of racing. This matters for the ':memory:' path, where sqflite
  /// forces singleInstance off and a second open would silently produce a
  /// second, empty database.
  Future<void>? _opening;

  Database get _open {
    final db = _db;
    if (db == null) {
      throw StateError('WorkoutRepository.init() must be awaited before use');
    }
    return db;
  }

  /// Safe to call more than once and safe to call concurrently. Repeat calls
  /// during startup await the same open rather than each starting their own.
  Future<void> init() async {
    if (_db != null) return;

    final existing = _opening;
    if (existing != null) return existing;

    final opening = _openDatabase();
    _opening = opening;
    try {
      await opening;
    } finally {
      // Cleared either way: a failure has to stay retryable, and a success must
      // not leave a settled future behind that would answer an init() after
      // close() without ever reopening the database.
      _opening = null;
    }
  }

  Future<void> _openDatabase() async {
    final factory = _factory ?? databaseFactory;
    final path = _path ?? join(await factory.getDatabasesPath(), _fileName);

    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
CREATE TABLE $_table (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at INTEGER
)''');

    // Every read either sorts or filters on started_at.
    await db.execute(
      'CREATE INDEX idx_${_table}_started_at ON $_table (started_at)',
    );
  }

  /// No-op at version 1. Migrations get an obvious home here.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {}

  /// Starts a session and returns a copy carrying the row id.
  ///
  /// At most one session runs at a time, and that rule lives here rather than
  /// in the UI: a crash, a second entry point or a voice command could all
  /// otherwise open a second one. An already running session is closed at the
  /// new session's start time, so the timeline never holds two overlapping open
  /// sessions and no time is double counted. The close time is clamped to the
  /// old session's own start, since a backdated [at] would otherwise write a
  /// negative duration.
  ///
  /// The read and the two writes run in one transaction because two callers
  /// starting at once (a tap and a voice command) would otherwise both see no
  /// running session and both insert one.
  Future<WorkoutSession> start(String type, {DateTime? at}) async {
    final startedAt = at ?? DateTime.now();
    final session = WorkoutSession(type: type, startedAt: startedAt);

    final id = await _open.transaction<int>((txn) async {
      final rows = await txn.query(
        _table,
        where: 'ended_at IS NULL',
        orderBy: 'started_at DESC',
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final current = WorkoutSession.fromMap(rows.first);
        final closeAt = startedAt.isBefore(current.startedAt)
            ? current.startedAt
            : startedAt;
        await txn.update(
          _table,
          {'ended_at': closeAt.toUtc().millisecondsSinceEpoch},
          where: 'id = ?',
          whereArgs: [current.id],
        );
      }
      return txn.insert(_table, session.toMap());
    });

    return session.copyWith(id: id);
  }

  /// The open session, or null if the user is not at the gym.
  Future<WorkoutSession?> running() async {
    final rows = await _open.query(
      _table,
      where: 'ended_at IS NULL',
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WorkoutSession.fromMap(rows.first);
  }

  /// Closes a running session and returns it with its final duration.
  ///
  /// Throws [StateError] rather than failing quietly, because every caller of
  /// this either just read the session or just took the user's word for it, and
  /// a silent no-op would leave a session running forever. An [endedAt] before
  /// the start is rejected for the same reason: one negative duration poisons
  /// the median that drives every later estimate.
  Future<WorkoutSession> end(int id, DateTime endedAt) async {
    final session = await byId(id);
    if (session == null) {
      throw StateError('no workout session with id $id');
    }
    if (!session.isRunning) {
      throw StateError(
        'workout session $id already ended at ${session.endedAt}',
      );
    }
    if (endedAt.isBefore(session.startedAt)) {
      throw StateError(
        'cannot end workout session $id at $endedAt, before its start '
        '${session.startedAt}',
      );
    }

    final ended = session.endedAtTime(endedAt);
    await _open.update(_table, ended.toMap(), where: 'id = ?', whereArgs: [id]);
    return ended;
  }

  /// Writes an edited session back verbatim, including clearing [endedAt].
  ///
  /// Unlike [start] this does not police the one-running rule: it exists for
  /// correcting a past session, where the caller already decided what the row
  /// should say.
  Future<WorkoutSession> update(WorkoutSession session) async {
    final id = session.id;
    if (id == null) {
      throw ArgumentError.value(
        session,
        'session',
        'cannot update a workout session with no id',
      );
    }
    await _open.update(
      _table,
      session.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
    return session;
  }

  Future<void> delete(int id) async {
    await _open.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Future<WorkoutSession?> byId(int id) async {
    final rows = await _open.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WorkoutSession.fromMap(rows.first);
  }

  /// Newest first, which is the order every history view shows.
  Future<List<WorkoutSession>> all() async {
    final rows = await _open.query(_table, orderBy: 'started_at DESC');
    return rows.map(WorkoutSession.fromMap).toList();
  }

  /// Sessions started at or after [from], newest first.
  Future<List<WorkoutSession>> since(DateTime from) async {
    final rows = await _open.query(
      _table,
      where: 'started_at >= ?',
      whereArgs: [from.toUtc().millisecondsSinceEpoch],
      orderBy: 'started_at DESC',
    );
    return rows.map(WorkoutSession.fromMap).toList();
  }

  /// Median length of the completed sessions, or null when there are none.
  ///
  /// Median, not mean, because this is what the app offers as the end time for
  /// a session left open overnight, and a single forgotten twelve hour session
  /// would drag a mean far enough to make the guess useless. Null rather than
  /// zero so an empty history reads as "no idea" instead of "zero minutes".
  ///
  /// Rows that end before they start are skipped: [update] writes an edited
  /// session back verbatim, so one mistyped correction would otherwise hand the
  /// app a negative estimate.
  Future<Duration?> medianDuration() async {
    final rows = await _open.rawQuery(
      'SELECT (ended_at - started_at) AS d FROM $_table '
      'WHERE ended_at IS NOT NULL AND ended_at >= started_at ORDER BY d ASC',
    );
    if (rows.isEmpty) return null;

    final values = rows.map((row) => row['d'] as int).toList();
    final middle = values.length ~/ 2;
    final millis = values.length.isOdd
        ? values[middle]
        : (values[middle - 1] + values[middle]) ~/ 2;
    return Duration(milliseconds: millis);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
