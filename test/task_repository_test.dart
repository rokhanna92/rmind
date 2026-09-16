import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/data/task_repository.dart';
import 'package:rmind/models/task.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late TaskRepository repo;
  final now = DateTime(2026, 5, 1, 12);

  Task taskDueIn(Duration offset, {int lead = 30, bool done = false}) {
    return Task(
      title: 'due in ${offset.inMinutes}m',
      dueAt: now.add(offset),
      reminderMinutesBefore: lead,
      isDone: done,
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
