import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:rmind/data/task_repository.dart';
import 'package:rmind/models/task.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late TaskRepository repo;
  final now = DateTime(2026, 5, 1, 12);

  Task taskDueIn(
    Duration offset, {
    int lead = 30,
    bool done = false,
    Recurrence recurrence = Recurrence.none,
  }) {
    return Task(
      title: 'due in ${offset.inMinutes}m',
      dueAt: now.add(offset),
      reminderMinutesBefore: lead,
      isDone: done,
      recurrence: recurrence,
      createdAt: now,
    );
  }

  setUp(() async {
    repo = TaskRepository(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await repo.init();
  });

  tearDown(() async {
    await repo.close();
  });

  test('add returns a copy carrying the assigned id', () async {
    final stored = await repo.add(taskDueIn(const Duration(hours: 1)));

    expect(stored.id, isNotNull);
    expect(stored.title, 'due in 60m');

    final second = await repo.add(taskDueIn(const Duration(hours: 2)));
    expect(second.id, isNot(stored.id));
  });

  test('round trip preserves every field', () async {
    final original = Task(
      title: 'call the vet',
      dueAt: DateTime(2026, 6, 2, 9, 45),
      reminderMinutesBefore: 15,
      useAlarm: true,
      isDone: true,
      createdAt: DateTime(2026, 5, 30, 8, 1),
    );

    final stored = await repo.add(original);
    final read = await repo.byId(stored.id!);

    expect(read, isNotNull);
    expect(read!.id, stored.id);
    expect(read.title, 'call the vet');
    expect(read.dueAt, original.dueAt);
    expect(read.createdAt, original.createdAt);
    expect(read.reminderMinutesBefore, 15);
    expect(read.useAlarm, isTrue);
    expect(read.isDone, isTrue);
  });

  test('byId returns null for an unknown id', () async {
    expect(await repo.byId(9999), isNull);
  });

  test('update mutates the stored row', () async {
    final stored = await repo.add(taskDueIn(const Duration(hours: 1)));

    await repo.update(
      stored.copyWith(title: 'renamed', isDone: true, useAlarm: true),
    );

    final read = await repo.byId(stored.id!);
    expect(read!.title, 'renamed');
    expect(read.isDone, isTrue);
    expect(read.useAlarm, isTrue);
  });

  test('update rejects a task with no id', () async {
    await expectLater(
      repo.update(taskDueIn(const Duration(hours: 1))),
      throwsArgumentError,
    );
  });

  test('delete removes the row', () async {
    final stored = await repo.add(taskDueIn(const Duration(hours: 1)));

    await repo.delete(stored.id!);

    expect(await repo.byId(stored.id!), isNull);
    expect(await repo.all(), isEmpty);
  });

  test('all returns every task ascending by dueAt', () async {
    await repo.add(taskDueIn(const Duration(hours: 3)));
    await repo.add(taskDueIn(const Duration(hours: -2)));
    await repo.add(taskDueIn(const Duration(hours: 1), done: true));

    final tasks = await repo.all();

    expect(tasks.map((t) => t.dueAt), [
      now.subtract(const Duration(hours: 2)),
      now.add(const Duration(hours: 1)),
      now.add(const Duration(hours: 3)),
    ]);
  });

  test('upcoming excludes past and done tasks, ascending', () async {
    await repo.add(taskDueIn(const Duration(hours: 3)));
    await repo.add(taskDueIn(const Duration(hours: -1)));
    await repo.add(taskDueIn(const Duration(hours: 2), done: true));
    await repo.add(taskDueIn(const Duration(hours: 1)));

    final tasks = await repo.upcoming(now);

    expect(tasks.map((t) => t.dueAt), [
      now.add(const Duration(hours: 1)),
      now.add(const Duration(hours: 3)),
    ]);
  });

  test('pendingReminders respects the per task lead time', () async {
    final soon = await repo.add(
      taskDueIn(const Duration(minutes: 20), lead: 30),
    );
    final later = await repo.add(
      taskDueIn(const Duration(minutes: 60), lead: 30),
    );

    final pending = await repo.pendingReminders(now);

    expect(pending.map((t) => t.id), [later.id]);
    expect(pending.map((t) => t.id), isNot(contains(soon.id)));
  });

  test('pendingReminders skips done tasks and sorts ascending', () async {
    await repo.add(taskDueIn(const Duration(hours: 4), lead: 10));
    await repo.add(taskDueIn(const Duration(hours: 2), lead: 10));
    await repo.add(taskDueIn(const Duration(hours: 3), lead: 10, done: true));

    final pending = await repo.pendingReminders(now);

    expect(pending.map((t) => t.dueAt), [
      now.add(const Duration(hours: 2)),
      now.add(const Duration(hours: 4)),
    ]);
  });

  test('pendingReminders agrees with Task.isPending', () async {
    final tasks = [
      taskDueIn(const Duration(minutes: 20), lead: 30),
      taskDueIn(const Duration(minutes: 60), lead: 30),
      taskDueIn(const Duration(minutes: 90), lead: 30, done: true),
      taskDueIn(const Duration(hours: -1), lead: 5),
    ];
    for (final task in tasks) {
      await repo.add(task);
    }

    final pending = await repo.pendingReminders(now);
    final expected = tasks.where((t) => t.isPending(now)).map((t) => t.title);

    expect(pending.map((t) => t.title), expected);
  });

  test('round trip preserves the recurrence', () async {
    final stored = await repo.add(
      taskDueIn(const Duration(hours: 1), recurrence: Recurrence.weekly),
    );

    final read = await repo.byId(stored.id!);

    expect(read!.recurrence, Recurrence.weekly);
  });

  test(
    'pendingReminders keeps a repeating task whose first fire has passed',
    () async {
      final weekly = await repo.add(
        taskDueIn(const Duration(days: -30), recurrence: Recurrence.weekly),
      );
      final daily = await repo.add(
        taskDueIn(const Duration(hours: -2), recurrence: Recurrence.daily),
      );
      final monthly = await repo.add(
        taskDueIn(const Duration(days: -200), recurrence: Recurrence.monthly),
      );
      // The same moment without a repeat is genuinely gone.
      final once = await repo.add(taskDueIn(const Duration(hours: -2)));

      final pending = await repo.pendingReminders(now);
      final ids = pending.map((t) => t.id);

      expect(ids, containsAll([weekly.id, daily.id, monthly.id]));
      expect(ids, isNot(contains(once.id)));
    },
  );

  test('pendingReminders still drops a done repeating task', () async {
    await repo.add(
      taskDueIn(
        const Duration(days: -7),
        recurrence: Recurrence.weekly,
        done: true,
      ),
    );

    expect(await repo.pendingReminders(now), isEmpty);
  });

  test('pendingReminders agrees with Task.isPending for repeats', () async {
    final tasks = [
      taskDueIn(const Duration(days: -30), recurrence: Recurrence.weekly),
      taskDueIn(const Duration(hours: -2)),
      taskDueIn(const Duration(minutes: 20), lead: 30),
      taskDueIn(const Duration(minutes: 45), recurrence: Recurrence.daily),
      taskDueIn(const Duration(hours: 6), recurrence: Recurrence.monthly),
      taskDueIn(const Duration(hours: 9), done: true),
    ];
    for (final task in tasks) {
      await repo.add(task);
    }

    final pending = await repo.pendingReminders(now);
    final expected = tasks.where((t) => t.isPending(now)).map((t) => t.dueAt);

    expect(pending.map((t) => t.dueAt), expected);
  });

  test(
    'migrating a version 1 database keeps its rows and defaults recurrence',
    () async {
      final dir = await Directory.systemTemp.createTemp('rmind_task_v1');
      final path = join(dir.path, 'rmind.db');

      try {
        // The exact schema shipped as version 1: no recurrence column at all.
        final legacy = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, version) async {
              await db.execute('''
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  due_at INTEGER NOT NULL,
  reminder_minutes_before INTEGER NOT NULL,
  use_alarm INTEGER NOT NULL,
  is_done INTEGER NOT NULL,
  created_at INTEGER NOT NULL
)''');
              await db.execute(
                'CREATE INDEX idx_tasks_due_at ON tasks (due_at)',
              );
            },
          ),
        );
        await legacy.insert('tasks', {
          'title': 'call the vet',
          'due_at': DateTime(2026, 6, 2, 9, 45).toUtc().millisecondsSinceEpoch,
          'reminder_minutes_before': 15,
          'use_alarm': 1,
          'is_done': 0,
          'created_at': DateTime(2026, 5, 30, 8, 1)
              .toUtc()
              .millisecondsSinceEpoch,
        });
        await legacy.insert('tasks', {
          'title': 'bins out',
          'due_at': DateTime(2026, 6, 1, 21).toUtc().millisecondsSinceEpoch,
          'reminder_minutes_before': 30,
          'use_alarm': 0,
          'is_done': 1,
          'created_at': DateTime(2026, 5, 30, 8, 2)
              .toUtc()
              .millisecondsSinceEpoch,
        });
        await legacy.close();

        final migrated = TaskRepository(
          factory: databaseFactoryFfi,
          path: path,
        );
        await migrated.init();

        final tasks = await migrated.all();
        expect(tasks.map((t) => t.title), ['bins out', 'call the vet']);
        expect(tasks.map((t) => t.recurrence), [
          Recurrence.none,
          Recurrence.none,
        ]);

        // Nothing else about the old rows may have moved in the process.
        final vet = tasks.last;
        expect(vet.dueAt, DateTime(2026, 6, 2, 9, 45));
        expect(vet.createdAt, DateTime(2026, 5, 30, 8, 1));
        expect(vet.reminderMinutesBefore, 15);
        expect(vet.useAlarm, isTrue);
        expect(vet.isDone, isFalse);
        expect(tasks.first.isDone, isTrue);

        // The migrated table must accept what the new model writes.
        final added = await migrated.add(
          Task(
            title: 'standup',
            dueAt: DateTime(2026, 6, 3, 9),
            recurrence: Recurrence.weekly,
            createdAt: DateTime(2026, 6, 1),
          ),
        );
        expect((await migrated.byId(added.id!))!.recurrence, Recurrence.weekly);

        await migrated.close();

        // Reopening must be an ordinary open, not a second upgrade.
        final reopened = TaskRepository(
          factory: databaseFactoryFfi,
          path: path,
        );
        await reopened.init();
        expect(await reopened.all(), hasLength(3));
        await reopened.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'use before init throws instead of opening a database silently',
    () async {
      final fresh = TaskRepository(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      await expectLater(fresh.all(), throwsStateError);
    },
  );
}
