import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart';

import '../models/note.dart';

/// SQLite-backed storage for [Note].
///
/// Its own database file, for the same reason the workouts file is separate:
/// nothing here joins against reminders or sessions, so a third file gets the
/// same result as a new table in an existing one without a schema migration
/// that could only ever endanger rows the user already has.
class NoteRepository {
  /// [factory] and [path] exist so tests can point at an in-memory database.
  /// Left unset, the repository opens the real file on the device.
  NoteRepository({DatabaseFactory? factory, String? path}) {
    // Named parameters cannot be private initializing formals, so these are
    // assigned here rather than in the initializer list.
    _factory = factory;
    _path = path;
  }

  static const String _table = 'notes';
  static const String _fileName = 'rmind_notes.db';
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
      throw StateError('NoteRepository.init() must be awaited before use');
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
  text TEXT NOT NULL,
  created_at INTEGER NOT NULL
)''');

    // Every read sorts on created_at.
    await db.execute(
      'CREATE INDEX idx_${_table}_created_at ON $_table (created_at)',
    );
  }

  /// No-op at version 1. Migrations get an obvious home here.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {}

  /// Stores the trimmed [text] and returns a copy carrying the row id.
  ///
  /// Empty or whitespace-only text is rejected rather than stored: a note with
  /// no content is never worth a row, and speech recognition hands back an
  /// empty string often enough that this would otherwise fill the list with
  /// blanks the user cannot even see to delete.
  Future<Note> add(String text, {DateTime? at}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(text, 'text', 'cannot add an empty note');
    }

    final note = Note(text: trimmed, createdAt: at ?? DateTime.now());
    final id = await _open.insert(_table, note.toMap());
    return note.copyWith(id: id);
  }

  /// Writes [note] back, trimmed, and returns what was actually stored.
  ///
  /// Holds add()'s guards rather than a looser set: an edit that clears the
  /// field would otherwise store a blank row the user cannot see well enough
  /// to delete. Throws when the row is gone, because returning the note as if
  /// saved loses the user's edit behind a success.
  Future<Note> update(Note note) async {
    final id = note.id;
    if (id == null) {
      throw ArgumentError.value(note, 'note', 'cannot update a note with no id');
    }
    final trimmed = note.text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        note,
        'note',
        'cannot update a note to empty text',
      );
    }

    final saved = note.copyWith(text: trimmed);
    final changed = await _open.update(
      _table,
      saved.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) {
      throw StateError('Note $id no longer exists, so the edit was not saved.');
    }
    return saved;
  }

  Future<void> delete(int id) async {
    await _open.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Future<Note?> byId(int id) async {
    final rows = await _open.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Note.fromMap(rows.first);
  }

  /// Newest first, which is the order every note list shows.
  Future<List<Note>> all() async {
    final rows = await _open.query(_table, orderBy: 'created_at DESC');
    return rows.map(Note.fromMap).toList();
  }

  /// Notes containing [query] anywhere in their text, newest first.
  ///
  /// Filtered in Dart rather than in SQL. SQLite's LOWER is ASCII only, while
  /// Dart's toLowerCase is Unicode aware, so folding one side in each language
  /// made any note containing a character such as C with a caron unfindable by
  /// the very word it contains. Matching through [Note.matches] also means the
  /// repository and the model can never disagree about what a query matches,
  /// and it removes the LIKE wildcard escaping entirely.
  ///
  /// Reading every row is acceptable here: notes are dictated sentences, not a
  /// corpus. Revisit with a folded shadow column if that ever stops being true.
  ///
  /// An empty query means "no filter", not "no results", so the list keeps
  /// showing everything while the search box is empty.
  Future<List<Note>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return all();
    final notes = await all();
    return notes.where((n) => n.matches(trimmed)).toList();
  }

  Future<int> count() async {
    final rows = await _open.rawQuery('SELECT COUNT(*) AS c FROM $_table');
    return rows.first['c'] as int;
  }


  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
