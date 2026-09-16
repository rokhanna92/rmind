import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:rmind/data/note_repository.dart';
import 'package:rmind/data/task_repository.dart';
import 'package:rmind/data/workout_repository.dart';
import 'package:rmind/models/task.dart';
import 'package:rmind/services/backup_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late _Store store;
  late BackupService service;
  late Directory cache;

  final made = DateTime(2026, 5, 1, 18, 30);

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('rmind-backup-test');
    store = await _Store.open(cache, 'phone');
    service = _serviceFor(store, cache);
  });

  tearDown(() async {
    await store.close();
    if (cache.existsSync()) await cache.delete(recursive: true);
  });

  /// A second, empty phone, so a restore can be checked against nothing but
  /// the file itself.
  Future<_Store> emptyPhone() async {
    final other = await _Store.open(cache, 'other');
    addTearDown(other.close);
    return other;
  }

  group('round trip', () {
    test('preserves every field of a reminder', () async {
      await store.tasks.add(
        Task(
          title: 'Dentist',
          dueAt: DateTime(2026, 6, 2, 9, 15),
          reminderMinutesBefore: 45,
          useAlarm: true,
          isDone: true,
          recurrence: Recurrence.weekly,
          createdAt: DateTime(2026, 5, 30, 21, 4),
        ),
      );

      final json = await service.exportJson();
      final phone = await emptyPhone();
      await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      final restored = (await phone.tasks.all()).single;
      expect(restored.title, 'Dentist');
      expect(restored.dueAt, DateTime(2026, 6, 2, 9, 15));
      expect(restored.reminderMinutesBefore, 45);
      expect(restored.useAlarm, isTrue);
      expect(restored.isDone, isTrue);
      expect(restored.recurrence, Recurrence.weekly);
      expect(restored.createdAt, DateTime(2026, 5, 30, 21, 4));
    });

    test('preserves every field of a finished workout session', () async {
      final started = await store.workouts.start(
        'Bicep and shoulder',
        at: DateTime(2026, 5, 20, 17),
      );
      await store.workouts.end(started.id!, DateTime(2026, 5, 20, 18, 12));

      final json = await service.exportJson();
      final phone = await emptyPhone();
      await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      final restored = (await phone.workouts.all()).single;
      expect(restored.type, 'Bicep and shoulder');
      expect(restored.startedAt, DateTime(2026, 5, 20, 17));
      expect(restored.endedAt, DateTime(2026, 5, 20, 18, 12));
      expect(restored.isRunning, isFalse);
    });

    test('preserves a session that is still running', () async {
      await store.workouts.start('Legs', at: DateTime(2026, 5, 21, 17));

      final json = await service.exportJson();
      final phone = await emptyPhone();
      await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      final restored = (await phone.workouts.all()).single;
      expect(restored.startedAt, DateTime(2026, 5, 21, 17));
      expect(restored.endedAt, isNull);
      expect(restored.isRunning, isTrue);
    });

    test('preserves every field of a note', () async {
      await store.notes.add('the wifi password is hunter2', at: made);

      final json = await service.exportJson();
      final phone = await emptyPhone();
      await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      final restored = (await phone.notes.all()).single;
      expect(restored.text, 'the wifi password is hunter2');
      expect(restored.createdAt, made);
    });

    test('a finished session restored alongside a running one is not '
        'closed by it', () async {
      final first = await store.workouts.start(
        'Chest',
        at: DateTime(2026, 5, 18, 17),
      );
      await store.workouts.end(first.id!, DateTime(2026, 5, 18, 18));
      await store.workouts.start('Back', at: DateTime(2026, 5, 19, 17));

      final json = await service.exportJson();
      final phone = await emptyPhone();
      await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      final restored = await phone.workouts.all();
      expect(restored.length, 2);
      expect(
        restored.singleWhere((s) => s.type == 'Chest').endedAt,
        DateTime(2026, 5, 18, 18),
      );
      expect(restored.singleWhere((s) => s.type == 'Back').isRunning, isTrue);
    });

    test('reports what it wrote', () async {
      await _seed(store);

      final json = await service.exportJson();
      final phone = await emptyPhone();
      final summary =
          await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      expect(summary.tasks, 3);
      expect(summary.sessions, 2);
      expect(summary.notes, 2);
      expect(summary.appVersion, '1.1.0+2');
    });
  });

  group('export', () {
    test('writes the format, the app version and every section', () async {
      await _seed(store);

      final map = jsonDecode(await service.exportJson()) as Map<String, Object?>;

      expect(map['format'], BackupService.formatVersion);
      expect(map['app'], '1.1.0+2');
      expect(DateTime.tryParse(map['createdAt']! as String), isNotNull);
      expect((map['tasks']! as List).length, 3);
      expect((map['sessions']! as List).length, 2);
      expect((map['notes']! as List).length, 2);
    });

    test('exportToFile names the file by the day and holds the backup',
        () async {
      await _seed(store);
      final now = DateTime.now();
      final day = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      final file = await service.exportToFile();

      expect(file.path.endsWith('rmind-backup-$day.json'), isTrue);
      final summary = await service.inspect(await file.readAsString());
      expect(summary.tasks, 3);
      expect(summary.sessions, 2);
      expect(summary.notes, 2);
    });

    test('an empty database exports and restores cleanly', () async {
      final json = await service.exportJson();

      final summary = await service.inspect(json);
      expect(summary.tasks, 0);
      expect(summary.sessions, 0);
      expect(summary.notes, 0);

      final phone = await emptyPhone();
      final restored =
          await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      expect(restored.tasks, 0);
      expect(await phone.tasks.all(), isEmpty);
      expect(await phone.workouts.all(), isEmpty);
      expect(await phone.notes.all(), isEmpty);
    });
  });

  group('inspect', () {
    test('counts the file without touching the database', () async {
      await _seed(store);
      final json = await service.exportJson();
      await store.tasks.add(
        Task(
          title: 'Added after the backup',
          dueAt: DateTime(2026, 7, 1, 8),
          createdAt: made,
        ),
      );
      final before = await store.snapshot();

      final summary = await service.inspect(json);

      expect(summary.tasks, 3);
      expect(summary.sessions, 2);
      expect(summary.notes, 2);
      expect(summary.appVersion, '1.1.0+2');
      expect(await store.snapshot(), before);
    });

    test('reads the date the backup was made', () async {
      final json = jsonEncode(_payload(createdAt: '2026-05-01T16:30:00.000Z'));

      final summary = await service.inspect(json);

      expect(summary.createdAt, DateTime.utc(2026, 5, 1, 16, 30).toLocal());
    });
  });

  group('restore modes', () {
    test('replace wipes what is on the phone first', () async {
      await _seed(store);
      final json = await service.exportJson();

      final phone = await emptyPhone();
      await phone.tasks.add(
        Task(
          title: 'Already here',
          dueAt: DateTime(2026, 8, 1, 8),
          createdAt: made,
        ),
      );
      await phone.notes.add('already here', at: made);
      final existing = await phone.workouts.start(
        'Already here',
        at: DateTime(2026, 4, 1, 17),
      );
      await phone.workouts.end(existing.id!, DateTime(2026, 4, 1, 18));

      await _serviceFor(phone, cache).restore(json, replaceExisting: true);

      final tasks = await phone.tasks.all();
      expect(tasks.length, 3);
      expect(tasks.where((t) => t.title == 'Already here'), isEmpty);
      expect((await phone.workouts.all()).length, 2);
      expect((await phone.notes.all()).length, 2);
      expect(await phone.notes.search('already here'), isEmpty);
    });

    test('merge keeps the existing rows and adds the new ones', () async {
      await _seed(store);
      final json = await service.exportJson();

      final phone = await emptyPhone();
      await phone.tasks.add(
        Task(
          title: 'Already here',
          dueAt: DateTime(2026, 8, 1, 8),
          createdAt: made,
        ),
      );
      await phone.notes.add('already here', at: made);
      final existing = await phone.workouts.start(
        'Already here',
        at: DateTime(2026, 4, 1, 17),
      );
      await phone.workouts.end(existing.id!, DateTime(2026, 4, 1, 18));

      await _serviceFor(phone, cache).restore(json, replaceExisting: false);

      final tasks = await phone.tasks.all();
      expect(tasks.length, 4);
      expect(tasks.where((t) => t.title == 'Already here').length, 1);
      expect((await phone.workouts.all()).length, 3);
      expect((await phone.notes.all()).length, 3);
      expect((await phone.notes.search('already here')).length, 1);
    });

    test('merge does not close a running session that is already here',
        () async {
      final finished = await store.workouts.start(
        'Chest',
        at: DateTime(2026, 5, 18, 17),
      );
      await store.workouts.end(finished.id!, DateTime(2026, 5, 18, 18));
      final json = await service.exportJson();

      final phone = await emptyPhone();
      await phone.workouts.start('At the gym now', at: DateTime(2026, 5, 25, 9));

      await _serviceFor(phone, cache).restore(json, replaceExisting: false);

      // The backup holds only a finished session, so the live one is still the
      // running one afterwards.
      final running = await phone.workouts.running();
      expect(running, isNotNull);
      expect(running!.type, 'At the gym now');
    });
  });

  group('ids', () {
    test('ids from the file are never reused', () async {
      final json = jsonEncode(
        _payload(
          tasks: [_taskRow(id: 900, title: 'From the file')],
          sessions: [_sessionRow(id: 901)],
          notes: [_noteRow(id: 902, text: 'from the file')],
        ),
      );

      // A live row already holds id 1, so a reused id would either collide or
      // overwrite it. A task id is also its OS notification id.
      await store.tasks.add(
        Task(
          title: 'Already here',
          dueAt: DateTime(2026, 8, 1, 8),
          createdAt: made,
        ),
      );

      await service.restore(json, replaceExisting: false);

      final tasks = await store.tasks.all();
      expect(tasks.length, 2);
      expect(tasks.map((t) => t.id), isNot(contains(900)));
      expect(tasks.singleWhere((t) => t.title == 'Already here').id, 1);
      expect((await store.workouts.all()).single.id, isNot(901));
      expect((await store.notes.all()).single.id, isNot(902));
    });

    test('a replace does not reuse the ids either', () async {
      final json = jsonEncode(
        _payload(tasks: [_taskRow(id: 900, title: 'From the file')]),
      );

      await service.restore(json, replaceExisting: true);

      expect((await store.tasks.all()).single.id, isNot(900));
    });
  });

  group('refuses a backup it cannot read', () {
    test('malformed JSON', () async {
      await expectLater(
        service.inspect('{"format": 1, "tasks": ['),
        throwsBackupException(contains('not valid JSON')),
      );
    });

    test('JSON that is not a single object', () async {
      await expectLater(
        service.inspect('[1, 2, 3]'),
        throwsBackupException(contains('single JSON object')),
      );
    });

    test('a missing "tasks" section', () async {
      final map = _payload()..remove('tasks');

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(contains('no "tasks" section')),
      );
    });

    test('a missing "sessions" section', () async {
      final map = _payload()..remove('sessions');

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(contains('no "sessions" section')),
      );
    });

    test('a missing "notes" section', () async {
      final map = _payload()..remove('notes');

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(contains('no "notes" section')),
      );
    });

    test('a section that is not a list', () async {
      final map = _payload()..['notes'] = 'two notes';

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(
          allOf(contains('"notes"'), contains('list'), contains('text')),
        ),
      );
    });

    test('a row that is not a row of fields', () async {
      final map = _payload(tasks: [_taskRow()])..['tasks'] = ['Dentist'];

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(contains('Reminder 1')),
      );
    });

    test('a format version from a newer RMIND', () async {
      final map = _payload()..['format'] = BackupService.formatVersion + 1;

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(contains('newer version of RMIND')),
      );
    });

    test('a missing format field', () async {
      final map = _payload()..remove('format');

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(contains('no "format" field')),
      );
    });

    test('a createdAt that is not a date', () async {
      final map = _payload(createdAt: 'last tuesday');

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(contains('not a date')),
      );
    });

    test('a reminder missing a field, naming the field', () async {
      final row = _taskRow()..remove('due_at');
      final map = _payload(tasks: [row]);

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(
          allOf(contains('Reminder 1'), contains('"due_at"')),
        ),
      );
    });

    test('a session whose ended_at is not a time', () async {
      final row = _sessionRow()..['ended_at'] = 'this afternoon';
      final map = _payload(sessions: [row]);

      await expectLater(
        service.inspect(jsonEncode(map)),
        throwsBackupException(
          allOf(contains('Workout session 1'), contains('"ended_at"')),
        ),
      );
    });

    test('a note with no text, which the repository would reject mid restore',
        () async {
      final map = _payload(notes: [_noteRow(text: '   ')]);

      await expectLater(
        service.restore(jsonEncode(map), replaceExisting: false),
        throwsBackupException(contains('Note 1')),
      );
      expect(await store.notes.count(), 0);
    });
  });

  group('a failed restore leaves the database exactly as it was', () {
    /// The whole reason this class validates before it writes: a half restore
    /// is worse than no restore, because the user cannot tell what they have.
    Future<String> attempt({required bool replaceExisting}) async {
      await _seed(store);
      final good = jsonDecode(await service.exportJson())
          as Map<String, Object?>;

      // The second reminder is corrupt, so anything written before reaching it
      // would be a half restore.
      final tasks = (good['tasks']! as List).toList();
      expect(tasks.length, greaterThan(2));
      (tasks[1] as Map<String, Object?>)['due_at'] = 'tomorrow morning';
      good['tasks'] = tasks;

      final before = await store.snapshot();

      await expectLater(
        service.restore(jsonEncode(good), replaceExisting: replaceExisting),
        throwsBackupException(
          allOf(contains('Reminder 2'), contains('Nothing was restored')),
        ),
      );

      final after = await store.snapshot();
      expect(after, before);
      return after;
    }

    test('when replacing', () async {
      final after = await attempt(replaceExisting: true);
      expect(after, contains('Dentist'));
    });

    test('when merging', () async {
      final after = await attempt(replaceExisting: false);
      expect(after, contains('Dentist'));
    });

    test('a corrupt session row writes no reminders either', () async {
      await _seed(store);
      final good =
          jsonDecode(await service.exportJson()) as Map<String, Object?>;
      (good['sessions']! as List)[1] = 'not a session';
      final before = await store.snapshot();

      await expectLater(
        service.restore(jsonEncode(good), replaceExisting: true),
        throwsBackupException(contains('Workout session 2')),
      );

      // Reminders are written before sessions, so this is the case where an
      // unvalidated restore would already have emptied and half filled a table.
      expect(await store.snapshot(), before);
    });
  });
}

Matcher throwsBackupException(Matcher message) => throwsA(
      isA<BackupException>().having((e) => e.message, 'message', message),
    );

BackupService _serviceFor(_Store store, Directory cache) => BackupService(
      tasks: store.tasks,
      workouts: store.workouts,
      notes: store.notes,
      appVersion: () async => '1.1.0+2',
      cacheDirectory: () async => cache,
    );

/// Three reminders, two sessions (one running) and two notes.
Future<void> _seed(_Store store) async {
  await store.tasks.add(
    Task(
      title: 'Dentist',
      dueAt: DateTime(2026, 6, 2, 9, 15),
      reminderMinutesBefore: 45,
      useAlarm: true,
      recurrence: Recurrence.weekly,
      createdAt: DateTime(2026, 5, 30, 21, 4),
    ),
  );
  await store.tasks.add(
    Task(
      title: 'Call the landlord',
      dueAt: DateTime(2026, 6, 3, 11),
      createdAt: DateTime(2026, 5, 31, 8),
    ),
  );
  await store.tasks.add(
    Task(
      title: 'Bins out',
      dueAt: DateTime(2026, 6, 4, 7),
      isDone: true,
      recurrence: Recurrence.daily,
      createdAt: DateTime(2026, 5, 31, 9),
    ),
  );

  final chest = await store.workouts.start(
    'Chest and triceps',
    at: DateTime(2026, 5, 18, 17),
  );
  await store.workouts.end(chest.id!, DateTime(2026, 5, 18, 18, 20));
  await store.workouts.start('Legs', at: DateTime(2026, 5, 19, 17));

  await store.notes.add('the wifi password is hunter2', at: DateTime(2026, 5, 1));
  await store.notes.add('parked on level 3', at: DateTime(2026, 5, 2));
}

Map<String, Object?> _payload({
  List<Map<String, Object?>>? tasks,
  List<Map<String, Object?>>? sessions,
  List<Map<String, Object?>>? notes,
  Object? createdAt,
}) {
  return <String, Object?>{
    'format': BackupService.formatVersion,
    'app': '1.1.0+2',
    'createdAt': createdAt ?? '2026-05-01T16:30:00.000Z',
    'tasks': tasks ?? <Map<String, Object?>>[],
    'sessions': sessions ?? <Map<String, Object?>>[],
    'notes': notes ?? <Map<String, Object?>>[],
  };
}

Map<String, Object?> _taskRow({int id = 1, String title = 'Dentist'}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'due_at': DateTime.utc(2026, 6, 2, 9, 15).millisecondsSinceEpoch,
      'reminder_minutes_before': 30,
      'use_alarm': 0,
      'is_done': 0,
      'recurrence': 'none',
      'created_at': DateTime.utc(2026, 5, 30).millisecondsSinceEpoch,
    };

Map<String, Object?> _sessionRow({int id = 1, String type = 'Legs'}) =>
    <String, Object?>{
      'id': id,
      'type': type,
      'started_at': DateTime.utc(2026, 5, 19, 17).millisecondsSinceEpoch,
      'ended_at': DateTime.utc(2026, 5, 19, 18).millisecondsSinceEpoch,
    };

Map<String, Object?> _noteRow({int id = 1, String text = 'hunter2'}) =>
    <String, Object?>{
      'id': id,
      'text': text,
      'created_at': DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
    };

/// One phone: the three repositories, in three throwaway database files.
///
/// Files rather than [inMemoryDatabasePath], which the single repository tests
/// use, because sqflite ffi hands every ':memory:' open the same underlying
/// database. Opening all three repositories that way runs the first one's
/// onCreate and then skips the other two, since the shared database already
/// reports the right version, and the app's real setup is three files anyway.
class _Store {
  _Store(this.tasks, this.workouts, this.notes);

  static Future<_Store> open(Directory root, String name) async {
    final tasks = TaskRepository(
      factory: databaseFactoryFfi,
      path: join(root.path, '$name-tasks.db'),
    );
    final workouts = WorkoutRepository(
      factory: databaseFactoryFfi,
      path: join(root.path, '$name-workouts.db'),
    );
    final notes = NoteRepository(
      factory: databaseFactoryFfi,
      path: join(root.path, '$name-notes.db'),
    );
    await tasks.init();
    await workouts.init();
    await notes.init();
    return _Store(tasks, workouts, notes);
  }

  final TaskRepository tasks;
  final WorkoutRepository workouts;
  final NoteRepository notes;

  /// Every row of all three tables, as a string that changes if anything at
  /// all changes. Used to prove a failed restore wrote nothing.
  Future<String> snapshot() async {
    final rows = <Object?>[
      (await tasks.all()).map((t) => t.toMap()).toList(),
      (await workouts.all()).map((s) => s.toMap()).toList(),
      (await notes.all()).map((n) => n.toMap()).toList(),
    ];
    return jsonEncode(rows);
  }

  Future<void> close() async {
    await tasks.close();
    await workouts.close();
    await notes.close();
  }
}
