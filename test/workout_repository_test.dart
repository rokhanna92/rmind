import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/data/workout_repository.dart';
import 'package:rmind/models/workout_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late WorkoutRepository repo;
  final now = DateTime(2026, 5, 1, 18);

  /// Stores a finished session of [length] starting [ago] before [now].
  Future<WorkoutSession> completed(Duration ago, Duration length) async {
    final started = now.subtract(ago);
    final session = await repo.start('legs', at: started);
    return repo.end(session.id!, started.add(length));
  }

  setUp(() async {
    repo = WorkoutRepository(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await repo.init();
  });

  tearDown(() async {
    await repo.close();
  });

  test('start returns an id and a running session', () async {
    final session = await repo.start('bicep and shoulder', at: now);

    expect(session.id, isNotNull);
    expect(session.type, 'bicep and shoulder');
    expect(session.startedAt, now);
    expect(session.endedAt, isNull);
    expect(session.isRunning, isTrue);
  });

  test(
    'running finds the open session and is null when there is none',
    () async {
      expect(await repo.running(), isNull);

      final started = await repo.start('chest', at: now);
      final open = await repo.running();

      expect(open, isNotNull);
      expect(open!.id, started.id);
      expect(open.type, 'chest');

      await repo.end(started.id!, now.add(const Duration(minutes: 45)));
      expect(await repo.running(), isNull);
    },
  );

  test(
    'starting a second session auto ends the first at the new start',
    () async {
      final first = await repo.start('back', at: now);
      final secondStart = now.add(const Duration(hours: 2));
      final second = await repo.start('legs', at: secondStart);

      final open = await repo.running();
      expect(open!.id, second.id);
      expect(open.type, 'legs');

      final closed = await repo.byId(first.id!);
      expect(closed!.endedAt, secondStart);
      expect(closed.duration, const Duration(hours: 2));

      final sessions = await repo.all();
      expect(sessions.where((s) => s.isRunning).length, 1);
    },
  );

  test('end sets the duration', () async {
    final started = await repo.start('cardio', at: now);

    final ended = await repo.end(
      started.id!,
      now.add(const Duration(minutes: 72)),
    );

    expect(ended.id, started.id);
    expect(ended.duration, const Duration(minutes: 72));
    expect(
      (await repo.byId(started.id!))!.duration,
      const Duration(minutes: 72),
    );
  });

  test('end on a missing id throws', () async {
    await expectLater(repo.end(9999, now), throwsStateError);
  });

  test('end on an already ended session throws', () async {
    final started = await repo.start('cardio', at: now);
    await repo.end(started.id!, now.add(const Duration(minutes: 30)));

    await expectLater(
      repo.end(started.id!, now.add(const Duration(minutes: 40))),
      throwsStateError,
    );
  });

  test('end before startedAt throws', () async {
    final started = await repo.start('cardio', at: now);

    await expectLater(
      repo.end(started.id!, now.subtract(const Duration(minutes: 1))),
      throwsStateError,
    );
    expect((await repo.byId(started.id!))!.isRunning, isTrue);
  });

  test('round trip preserves every field, including a null endedAt', () async {
    final started = await repo.start('bicep and shoulder', at: now);

    final open = await repo.byId(started.id!);
    expect(open!.id, started.id);
    expect(open.type, 'bicep and shoulder');
    expect(open.startedAt, now);
    expect(open.endedAt, isNull);

    final endedAt = now.add(const Duration(minutes: 55));
    await repo.end(started.id!, endedAt);

    final read = await repo.byId(started.id!);
    expect(read!.type, 'bicep and shoulder');
    expect(read.startedAt, now);
    expect(read.endedAt, endedAt);
  });

  test(
    'update writes an edited session back, including reopening it',
    () async {
      final started = await repo.start('chest', at: now);
      await repo.end(started.id!, now.add(const Duration(minutes: 20)));

      await repo.update((await repo.byId(started.id!))!.copyWith(type: 'push'));
      expect((await repo.byId(started.id!))!.type, 'push');

      await repo.update((await repo.byId(started.id!))!.reopened());
      expect((await repo.byId(started.id!))!.endedAt, isNull);
    },
  );

  test('update rejects a session with no id', () async {
    await expectLater(
      repo.update(WorkoutSession(type: 'chest', startedAt: now)),
      throwsArgumentError,
    );
  });

  test('delete removes the row', () async {
    final started = await repo.start('chest', at: now);

    await repo.delete(started.id!);

    expect(await repo.byId(started.id!), isNull);
    expect(await repo.all(), isEmpty);
  });

  test('all returns every session newest first', () async {
    await completed(const Duration(days: 2), const Duration(hours: 1));
    await completed(const Duration(days: 5), const Duration(hours: 1));
    await repo.start('today', at: now);

    final sessions = await repo.all();

    expect(sessions.map((s) => s.startedAt), [
      now,
      now.subtract(const Duration(days: 2)),
      now.subtract(const Duration(days: 5)),
    ]);
  });

  test('since filters by start time and stays newest first', () async {
    await completed(const Duration(days: 10), const Duration(hours: 1));
    await completed(const Duration(days: 3), const Duration(hours: 1));
    await completed(const Duration(days: 1), const Duration(hours: 1));

    final recent = await repo.since(now.subtract(const Duration(days: 7)));

    expect(recent.map((s) => s.startedAt), [
      now.subtract(const Duration(days: 1)),
      now.subtract(const Duration(days: 3)),
    ]);
  });

  test('since includes a session started exactly at the cutoff', () async {
    await completed(const Duration(days: 7), const Duration(hours: 1));

    final from = now.subtract(const Duration(days: 7));
    expect((await repo.since(from)).length, 1);
  });

  test('medianDuration is null with no completed sessions', () async {
    expect(await repo.medianDuration(), isNull);

    await repo.start('chest', at: now);
    expect(await repo.medianDuration(), isNull);
  });

  test('medianDuration of one session is that session', () async {
    await completed(const Duration(days: 1), const Duration(minutes: 50));

    expect(await repo.medianDuration(), const Duration(minutes: 50));
  });

  test('medianDuration of two averages the middle pair', () async {
    await completed(const Duration(days: 1), const Duration(minutes: 40));
    await completed(const Duration(days: 2), const Duration(minutes: 60));

    expect(await repo.medianDuration(), const Duration(minutes: 50));
  });

  test('medianDuration of three takes the middle', () async {
    await completed(const Duration(days: 1), const Duration(minutes: 30));
    await completed(const Duration(days: 2), const Duration(minutes: 90));
    await completed(const Duration(days: 3), const Duration(minutes: 45));

    expect(await repo.medianDuration(), const Duration(minutes: 45));
  });

  test('medianDuration of four averages the middle pair', () async {
    await completed(const Duration(days: 1), const Duration(minutes: 20));
    await completed(const Duration(days: 2), const Duration(minutes: 40));
    await completed(const Duration(days: 3), const Duration(minutes: 60));
    await completed(const Duration(days: 4), const Duration(minutes: 100));

    expect(await repo.medianDuration(), const Duration(minutes: 50));
  });

  test(
    'medianDuration ignores a session edited to end before it starts',
    () async {
      await completed(const Duration(days: 1), const Duration(minutes: 30));
      final broken = await completed(
        const Duration(days: 2),
        const Duration(minutes: 60),
      );

      await repo.update(
        broken.copyWith(
          startedAt: broken.endedAt!.add(const Duration(hours: 1)),
        ),
      );

      expect(await repo.medianDuration(), const Duration(minutes: 30));
    },
  );

  test('medianDuration ignores a running session', () async {
    await completed(const Duration(days: 1), const Duration(minutes: 30));
    await completed(const Duration(days: 2), const Duration(minutes: 60));
    await completed(const Duration(days: 3), const Duration(minutes: 90));
    await repo.start('still at the gym', at: now);

    expect(await repo.medianDuration(), const Duration(minutes: 60));
  });

  test('two starts racing still leave exactly one session running', () async {
    await Future.wait([
      repo.start('back', at: now),
      repo.start('legs', at: now.add(const Duration(minutes: 1))),
    ]);

    final sessions = await repo.all();
    expect(sessions.length, 2);
    expect(sessions.where((s) => s.isRunning).length, 1);
  });

  test('init after close reopens instead of staying shut', () async {
    await repo.start('chest', at: now);
    await repo.close();

    await repo.init();

    expect(await repo.all(), isEmpty);
  });

  test(
    'use before init throws instead of opening a database silently',
    () async {
      final fresh = WorkoutRepository(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      await expectLater(fresh.all(), throwsStateError);
    },
  );
}
