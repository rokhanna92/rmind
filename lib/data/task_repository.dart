import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart';

import '../models/task.dart';

/// SQLite-backed storage for [Task].
///
/// Every screen and the reminder scheduler read through this one class, so the
/// ordering and filtering rules live here rather than being re-derived by each
/// caller.
class TaskRepository {
  /// [factory] and [path] exist so tests can point at an in-memory database.
  /// Left unset, the repository opens the real file on the device.
  TaskRepository({DatabaseFactory? factory, String? path}) {
    // Named parameters cannot be private initializing formals, so these are
    // assigned here rather than in the initializer list.
    _factory = factory;
    _path = path;
  }

  static const String _table = 'tasks';
  static const String _fileName = 'rmind.db';
  static const int _version = 2;

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
      throw StateError('TaskRepository.init() must be awaited before use');
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
      // Cleared on success as well as failure. Clearing only on failure left a
      // settled future cached, so init() after close() returned immediately
      // without reopening and every later call threw.
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
  title TEXT NOT NULL,
  due_at INTEGER NOT NULL,
  reminder_minutes_before INTEGER NOT NULL,
  use_alarm INTEGER NOT NULL,
  is_done INTEGER NOT NULL,
  recurrence TEXT NOT NULL DEFAULT 'none',
  created_at INTEGER NOT NULL
)''');

    // Every read either sorts or filters on due_at.
    await db.execute('CREATE INDEX idx_${_table}_due_at ON $_table (due_at)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _addRecurrenceColumn(db);
    }
  }

  /// Adds the v2 recurrence column to a v1 table.
  ///
  /// The column list is checked first because SQLite has no ADD COLUMN IF NOT
  /// EXISTS and a duplicate column is a hard error. That matters more here than
  /// anywhere else in the app: sqflite runs the upgrade inside a transaction and
  /// leaves the version untouched when it throws, so a migration that fails once
  /// fails on every launch and the user is left with an app that cannot open its
  /// own database.
  ///
  /// The default is written into the column rather than backfilled, so existing
  /// rows read as [Recurrence.none] without a second statement touching them.
  Future<void> _addRecurrenceColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info($_table)');
    final exists = columns.any((column) => column['name'] == 'recurrence');
    if (exists) return;

    await db.execute(
      "ALTER TABLE $_table ADD COLUMN recurrence TEXT NOT NULL DEFAULT 'none'",
    );
  }

  /// Returns a copy carrying the row id, which is also the notification id.
  Future<Task> add(Task task) async {
    final id = await _open.insert(_table, task.toMap());
    return task.copyWith(id: id);
  }

  Future<void> update(Task task) async {
    final id = task.id;
    if (id == null) {
      throw ArgumentError.value(
        task,
        'task',
        'cannot update a task with no id',
      );
    }
    await _open.update(_table, task.toMap(), where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(int id) async {
    await _open.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Future<Task?> byId(int id) async {
    final rows = await _open.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Task.fromMap(rows.first);
  }

  Future<List<Task>> all() async {
    final rows = await _open.query(_table, orderBy: 'due_at ASC');
    return rows.map(Task.fromMap).toList();
  }

  /// Open tasks that have not happened yet.
  Future<List<Task>> upcoming(DateTime now) async {
    final rows = await _open.query(
      _table,
      where: 'is_done = 0 AND due_at >= ?',
      whereArgs: [now.millisecondsSinceEpoch],
      orderBy: 'due_at ASC',
    );
    return rows.map(Task.fromMap).toList();
  }

  /// Tasks whose reminder still has to fire.
  ///
  /// The lead time is per task, so the cutoff is computed in SQL and the
  /// database does the filtering instead of loading every row into Dart.
  ///
  /// A repeating task is always pending, even once its first fire has gone, and
  /// this mirrors [Task.isPending] rather than inventing a second rule. A row
  /// dropped here is a reminder the OS never hears about.
  Future<List<Task>> pendingReminders(DateTime now) async {
    final rows = await _open.query(
      _table,
      where: 'is_done = 0 AND (recurrence != ? '
          'OR (due_at - reminder_minutes_before * 60000) > ?)',
      whereArgs: [Recurrence.none.name, now.millisecondsSinceEpoch],
      orderBy: 'due_at ASC',
    );
    return rows.map(Task.fromMap).toList();
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
