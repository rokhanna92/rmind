import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart';

import '../models/food_entry.dart';

/// SQLite-backed storage for [FoodEntry].
///
/// Its own database file, for the same reason the notes and workouts files are
/// separate: nothing here joins against another table, so a fourth file gets
/// the same result as a new table in an existing one without a schema
/// migration that could only ever endanger rows the user already has.
///
/// Every day boundary in here is calendar arithmetic on local time rather than
/// a Duration subtracted from a timestamp. On the two days a year the clocks
/// move, a day is 23 or 25 hours long, and `now.subtract(const Duration(days:
/// 1))` would put the boundary an hour out and quietly file a late meal under
/// the wrong day. `DateTime(y, m, d)` is always local midnight.
class FoodRepository {
  /// [factory] and [path] exist so tests can point at a temporary database.
  /// Left unset, the repository opens the real file on the device.
  FoodRepository({DatabaseFactory? factory, String? path}) {
    // Named parameters cannot be private initializing formals, so these are
    // assigned here rather than in the initializer list.
    _factory = factory;
    _path = path;
  }

  static const String _table = 'entries';
  static const String _fileName = 'rmind_food.db';
  static const int _version = 1;

  late final DatabaseFactory? _factory;
  late final String? _path;

  Database? _db;

  /// The in-flight open, so overlapping init() calls share one connection
  /// instead of racing.
  Future<void>? _opening;

  Database get _open {
    final db = _db;
    if (db == null) {
      throw StateError('FoodRepository.init() must be awaited before use');
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
  description TEXT NOT NULL,
  protein_grams INTEGER NOT NULL,
  eaten_at INTEGER NOT NULL,
  estimated INTEGER NOT NULL
)''');

    // Every read here is a range over eaten_at.
    await db.execute(
      'CREATE INDEX idx_${_table}_eaten_at ON $_table (eaten_at)',
    );
  }

  /// No-op at version 1. Migrations get an obvious home here.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {}

  /// Stores [entry], trimmed and clamped, and returns a copy with the row id.
  ///
  /// The grams go through [FoodEntry.clampGrams] rather than being rejected:
  /// a misheard quantity should not throw away the meal the user just
  /// dictated. An empty description is rejected, because speech recognition
  /// hands back a blank string often enough that this would otherwise fill the
  /// day with rows the user cannot see well enough to delete.
  Future<FoodEntry> add(FoodEntry entry) async {
    final saved = _sanitise(entry, 'entry');
    final id = await _open.insert(_table, saved.toMap());
    return saved.copyWith(id: id);
  }

  /// Writes [entry] back, trimmed and clamped, and returns what was stored.
  ///
  /// Holds add()'s guards rather than a looser set. Throws when the row is
  /// gone, because returning the entry as if saved loses the user's edit
  /// behind a success.
  Future<FoodEntry> update(FoodEntry entry) async {
    final id = entry.id;
    if (id == null) {
      throw ArgumentError.value(
        entry,
        'entry',
        'cannot update a food entry with no id',
      );
    }

    final saved = _sanitise(entry, 'entry');
    final changed = await _open.update(
      _table,
      saved.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) {
      throw StateError(
        'Food entry $id no longer exists, so the edit was not saved.',
      );
    }
    return saved;
  }

  Future<void> delete(int id) async {
    await _open.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  /// Everything eaten on the local calendar day containing [day], newest first.
  Future<List<FoodEntry>> forDay(DateTime day) async {
    final start = startOfDay(day);
    final end = startOfNextDay(day);

    final rows = await _open.query(
      _table,
      where: 'eaten_at >= ? AND eaten_at < ?',
      whereArgs: [_epoch(start), _epoch(end)],
      orderBy: 'eaten_at DESC',
    );
    return rows.map(FoodEntry.fromMap).toList();
  }

  /// Total grams on the local calendar day containing [day], 0 when empty.
  Future<int> proteinOn(DateTime day) async {
    final rows = await _open.rawQuery(
      'SELECT SUM(protein_grams) AS total FROM $_table '
      'WHERE eaten_at >= ? AND eaten_at < ?',
      [_epoch(startOfDay(day)), _epoch(startOfNextDay(day))],
    );
    // SUM over no rows is NULL, which is a zero total here.
    return (rows.first['total'] as int?) ?? 0;
  }

  /// Entries eaten at or after [from], newest first.
  Future<List<FoodEntry>> since(DateTime from) async {
    final rows = await _open.query(
      _table,
      where: 'eaten_at >= ?',
      whereArgs: [_epoch(from)],
      orderBy: 'eaten_at DESC',
    );
    return rows.map(FoodEntry.fromMap).toList();
  }

  /// Grams per day across the calendar days containing [from] and [to], both
  /// ends included, keyed by local midnight and ordered oldest first.
  ///
  /// A day with no entries is absent rather than present as zero, so the
  /// caller decides whether a gap reads as a miss, a blank, or nothing at all.
  /// This app cannot tell the difference between a day off and a day the user
  /// forgot to log, and pretending it can would be putting words in their
  /// mouth.
  ///
  /// The bucketing happens in Dart. SQLite's `localtime` modifier reads the C
  /// library's timezone rather than Dart's, so grouping in SQL would key some
  /// rows off a different midnight than [forDay] uses.
  Future<Map<DateTime, int>> dailyTotals(DateTime from, DateTime to) async {
    final start = startOfDay(from);
    final end = startOfNextDay(to);
    if (!end.isAfter(start)) return {};

    final rows = await _open.query(
      _table,
      columns: ['protein_grams', 'eaten_at'],
      where: 'eaten_at >= ? AND eaten_at < ?',
      whereArgs: [_epoch(start), _epoch(end)],
      orderBy: 'eaten_at ASC',
    );

    final totals = <DateTime, int>{};
    for (final row in rows) {
      final eatenAt = DateTime.fromMillisecondsSinceEpoch(
        row['eaten_at'] as int,
        isUtc: true,
      ).toLocal();
      final day = startOfDay(eatenAt);
      totals[day] = (totals[day] ?? 0) + (row['protein_grams'] as int);
    }
    return totals;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Local midnight at the start of the day containing [day].
  static DateTime startOfDay(DateTime day) =>
      DateTime(day.year, day.month, day.day);

  /// Local midnight at the start of the following day. DateTime normalises the
  /// overflow, so the last of the month and the last of the year are ordinary
  /// cases rather than special ones.
  static DateTime startOfNextDay(DateTime day) =>
      DateTime(day.year, day.month, day.day + 1);

  static int _epoch(DateTime at) => at.toUtc().millisecondsSinceEpoch;

  FoodEntry _sanitise(FoodEntry entry, String name) {
    final description = entry.description.trim();
    if (description.isEmpty) {
      throw ArgumentError.value(
        entry,
        name,
        'a food entry needs a description',
      );
    }
    return entry.copyWith(
      description: description,
      proteinGrams: FoodEntry.clampGrams(entry.proteinGrams),
    );
  }
}
