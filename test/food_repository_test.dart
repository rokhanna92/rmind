import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:rmind/data/food_repository.dart';
import 'package:rmind/models/food_entry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late FoodRepository repo;

  setUp(() async {
    // A real temporary file per test, not inMemoryDatabasePath: sqflite ffi
    // hands every ':memory:' open the same underlying database, so tests leak
    // rows into each other and pass or fail depending on their order.
    dir = await Directory.systemTemp.createTemp('rmind_food_test');
    repo = FoodRepository(
      factory: databaseFactoryFfi,
      path: join(dir.path, 'food.db'),
    );
    await repo.init();
  });

  tearDown(() async {
    await repo.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<FoodEntry> add(
    String description,
    int grams,
    DateTime at, {
    bool estimated = true,
  }) {
    return repo.add(
      FoodEntry(
        description: description,
        proteinGrams: grams,
        eatenAt: at,
        estimated: estimated,
      ),
    );
  }

  group('add', () {
    test('round trips the description, grams, time and estimated flag',
        () async {
      final at = DateTime(2026, 5, 1, 8, 30);
      final added = await add('4 eggs', 24, at, estimated: false);

      expect(added.id, isNotNull);

      final read = await repo.forDay(at);
      expect(read, hasLength(1));
      expect(read.single.id, added.id);
      expect(read.single.description, '4 eggs');
      expect(read.single.proteinGrams, 24);
      expect(read.single.eatenAt, at);
      expect(read.single.estimated, isFalse);
    });

    test('keeps an estimated entry marked as estimated', () async {
      final at = DateTime(2026, 5, 1, 13);
      await add('chicken and rice', 40, at);

      expect((await repo.forDay(at)).single.estimated, isTrue);
    });

    test('trims the description', () async {
      final at = DateTime(2026, 5, 1, 9);
      final added = await add('  protein shake \n', 30, at);

      expect(added.description, 'protein shake');
      expect((await repo.forDay(at)).single.description, 'protein shake');
    });

    test('clamps a negative figure to zero', () async {
      final at = DateTime(2026, 5, 1, 10);
      final added = await add('black coffee', -12, at);

      expect(added.proteinGrams, 0);
      expect((await repo.forDay(at)).single.proteinGrams, 0);
    });

    test('clamps an absurd figure to the per entry maximum', () async {
      final at = DateTime(2026, 5, 1, 11);
      final added = await add('steak', 9000, at);

      expect(added.proteinGrams, FoodEntry.maxGramsPerEntry);
      expect(
        (await repo.forDay(at)).single.proteinGrams,
        FoodEntry.maxGramsPerEntry,
      );
    });

    test('rejects an empty description', () async {
      final at = DateTime(2026, 5, 1, 12);

      await expectLater(add('', 20, at), throwsArgumentError);
      await expectLater(add('   \n\t ', 20, at), throwsArgumentError);
      expect(await repo.forDay(at), isEmpty);
    });
  });

  group('update', () {
    test('writes the change back', () async {
      final at = DateTime(2026, 5, 1, 19);
      final added = await add('shake', 30, at);

      final saved = await repo.update(
        added.copyWith(description: 'double shake', proteinGrams: 60),
      );

      expect(saved.id, added.id);
      final read = await repo.forDay(at);
      expect(read, hasLength(1));
      expect(read.single.description, 'double shake');
      expect(read.single.proteinGrams, 60);
    });

    test('clamps and rejects exactly as add does', () async {
      final at = DateTime(2026, 5, 1, 19);
      final added = await add('shake', 30, at);

      final saved = await repo.update(added.copyWith(proteinGrams: 9000));
      expect(saved.proteinGrams, FoodEntry.maxGramsPerEntry);

      await expectLater(
        repo.update(added.copyWith(description: '  ')),
        throwsArgumentError,
      );
    });

    test('throws on an entry with no id', () async {
      await expectLater(
        repo.update(
          FoodEntry(
            description: 'shake',
            proteinGrams: 30,
            eatenAt: DateTime(2026, 5, 1, 19),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('throws when the row is gone', () async {
      final at = DateTime(2026, 5, 1, 19);
      final added = await add('shake', 30, at);
      await repo.delete(added.id!);

      await expectLater(
        repo.update(added.copyWith(proteinGrams: 40)),
        throwsStateError,
      );
    });
  });

  group('delete', () {
    test('removes the row', () async {
      final at = DateTime(2026, 5, 1, 19);
      final added = await add('shake', 30, at);

      await repo.delete(added.id!);

      expect(await repo.forDay(at), isEmpty);
    });
  });

  group('forDay', () {
    test('returns only that day, newest first', () async {
      final day = DateTime(2026, 5, 2);
      await add('yesterday', 10, DateTime(2026, 5, 1, 20));
      final morning = await add('breakfast', 20, DateTime(2026, 5, 2, 7));
      final evening = await add('dinner', 40, DateTime(2026, 5, 2, 19));
      await add('tomorrow', 10, DateTime(2026, 5, 3, 7));

      final entries = await repo.forDay(day);

      expect(entries.map((e) => e.id), [evening.id, morning.id]);
    });

    test('takes the whole day from 00:01 to 23:59', () async {
      final justAfterMidnight = DateTime(2026, 5, 2, 0, 1);
      final justBeforeMidnight = DateTime(2026, 5, 2, 23, 59);
      await add('midnight snack', 15, justAfterMidnight);
      await add('late supper', 25, justBeforeMidnight);

      final entries = await repo.forDay(DateTime(2026, 5, 2, 12));

      expect(entries.map((e) => e.description), ['late supper',
        'midnight snack']);
      expect(await repo.proteinOn(justAfterMidnight), 40);
      expect(await repo.proteinOn(justBeforeMidnight), 40);
    });

    test('an entry just before local midnight does not leak into the next day',
        () async {
      final lastMinute = DateTime(2026, 5, 2, 23, 59, 59);
      await add('late supper', 25, lastMinute);

      expect(await repo.forDay(DateTime(2026, 5, 3)), isEmpty);
      expect(await repo.forDay(DateTime(2026, 5, 2)), hasLength(1));
    });

    test('an entry at exactly local midnight belongs to the day it starts',
        () async {
      await add('midnight shake', 30, DateTime(2026, 5, 3));

      expect(await repo.forDay(DateTime(2026, 5, 2, 12)), isEmpty);
      expect(await repo.forDay(DateTime(2026, 5, 3, 12)), hasLength(1));
    });

    test('is empty when nothing was eaten', () async {
      expect(await repo.forDay(DateTime(2026, 5, 2)), isEmpty);
    });
  });

  group('proteinOn', () {
    test('sums the day', () async {
      await add('eggs', 24, DateTime(2026, 5, 2, 8));
      await add('shake', 30, DateTime(2026, 5, 2, 11));
      await add('chicken', 45, DateTime(2026, 5, 2, 19));
      await add('other day', 100, DateTime(2026, 5, 3, 8));

      expect(await repo.proteinOn(DateTime(2026, 5, 2, 15)), 99);
    });

    test('is zero for a day with nothing on it', () async {
      await add('eggs', 24, DateTime(2026, 5, 2, 8));

      expect(await repo.proteinOn(DateTime(2026, 5, 4)), 0);
    });
  });

  group('since', () {
    test('returns entries at or after the cutoff, newest first', () async {
      await add('too old', 10, DateTime(2026, 5, 1, 12));
      final cutoff = await add('on the cutoff', 20, DateTime(2026, 5, 2, 12));
      final later = await add('after', 30, DateTime(2026, 5, 3, 12));

      final entries = await repo.since(DateTime(2026, 5, 2, 12));

      expect(entries.map((e) => e.id), [later.id, cutoff.id]);
    });
  });

  group('dailyTotals', () {
    test('spans several days and omits the empty ones', () async {
      await add('eggs', 24, DateTime(2026, 5, 1, 8));
      await add('shake', 30, DateTime(2026, 5, 1, 17));
      // 2 May: nothing.
      await add('chicken', 45, DateTime(2026, 5, 3, 19));

      final totals = await repo.dailyTotals(
        DateTime(2026, 5, 1, 21),
        DateTime(2026, 5, 3, 6),
      );

      expect(totals, {
        DateTime(2026, 5, 1): 54,
        DateTime(2026, 5, 3): 45,
      });
      expect(totals.containsKey(DateTime(2026, 5, 2)), isFalse);
    });

    test('keys are local midnight and run oldest first', () async {
      await add('a', 10, DateTime(2026, 5, 3, 22));
      await add('b', 10, DateTime(2026, 5, 1, 6));

      final totals = await repo.dailyTotals(
        DateTime(2026, 5, 1),
        DateTime(2026, 5, 3),
      );

      expect(totals.keys.toList(), [
        DateTime(2026, 5, 1),
        DateTime(2026, 5, 3),
      ]);
    });

    test('includes both end days whole', () async {
      await add('first minute', 10, DateTime(2026, 5, 1, 0, 0, 1));
      await add('last minute', 10, DateTime(2026, 5, 3, 23, 59, 59));
      await add('outside', 10, DateTime(2026, 5, 4, 0, 0, 1));

      final totals = await repo.dailyTotals(
        DateTime(2026, 5, 1, 12),
        DateTime(2026, 5, 3, 12),
      );

      expect(totals, {
        DateTime(2026, 5, 1): 10,
        DateTime(2026, 5, 3): 10,
      });
    });

    test('is empty when the range holds nothing', () async {
      await add('eggs', 24, DateTime(2026, 5, 1, 8));

      final totals = await repo.dailyTotals(
        DateTime(2026, 6, 1),
        DateTime(2026, 6, 7),
      );

      expect(totals, isEmpty);
    });

    test('is empty when the range runs backwards', () async {
      await add('eggs', 24, DateTime(2026, 5, 1, 8));

      final totals = await repo.dailyTotals(
        DateTime(2026, 5, 3),
        DateTime(2026, 5, 1),
      );

      expect(totals, isEmpty);
    });
  });

  group('day boundaries', () {
    test('cross a month end without special casing', () async {
      await add('last of the month', 20, DateTime(2026, 5, 31, 23, 30));
      await add('first of the next', 30, DateTime(2026, 6, 1, 0, 30));

      expect(await repo.proteinOn(DateTime(2026, 5, 31)), 20);
      expect(await repo.proteinOn(DateTime(2026, 6, 1)), 30);
    });

    test('cross a year end without special casing', () async {
      await add('new year eve', 20, DateTime(2026, 12, 31, 23, 30));
      await add('new year day', 30, DateTime(2027, 1, 1, 0, 30));

      expect(await repo.proteinOn(DateTime(2026, 12, 31)), 20);
      expect(await repo.proteinOn(DateTime(2027, 1, 1)), 30);
    });

    test('hold on the days the clocks move', () async {
      // A 23 or a 25 hour day is where subtracting a Duration would put the
      // boundary an hour out and file a late meal under the wrong day. These
      // are the European transition dates, and the assertions stay true in any
      // timezone the test happens to run in.
      for (final day in [
        DateTime(2026, 3, 29),
        DateTime(2026, 10, 25),
      ]) {
        await add('early', 10, day.add(const Duration(minutes: 30)));
        await add('late', 20, DateTime(day.year, day.month, day.day, 23, 30));

        expect(await repo.proteinOn(day), 30);
        expect(
          await repo.proteinOn(FoodRepository.startOfNextDay(day)),
          0,
        );
      }
    });
  });

  group('init', () {
    test('is safe to call twice and concurrently', () async {
      await Future.wait([repo.init(), repo.init()]);
      await repo.init();

      final at = DateTime(2026, 5, 1, 8);
      await add('eggs', 24, at);
      expect(await repo.forDay(at), hasLength(1));
    });

    test('reopening the same file keeps the rows', () async {
      final path = join(dir.path, 'reopen.db');
      final first = FoodRepository(factory: databaseFactoryFfi, path: path);
      await first.init();
      await first.add(
        FoodEntry(
          description: 'eggs',
          proteinGrams: 24,
          eatenAt: DateTime(2026, 5, 1, 8),
        ),
      );
      await first.close();

      final second = FoodRepository(factory: databaseFactoryFfi, path: path);
      await second.init();
      expect(await second.forDay(DateTime(2026, 5, 1)), hasLength(1));
      await second.close();
    });
  });

  test('using the repository before init throws', () async {
    final unopened = FoodRepository(
      factory: databaseFactoryFfi,
      path: join(dir.path, 'unopened.db'),
    );

    await expectLater(
      unopened.forDay(DateTime(2026, 5, 1)),
      throwsStateError,
    );
  });
}
