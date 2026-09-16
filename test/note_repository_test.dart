import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/data/note_repository.dart';
import 'package:rmind/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late NoteRepository repo;
  final now = DateTime(2026, 5, 1, 18);

  setUp(() async {
    repo = NoteRepository(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await repo.init();
  });

  tearDown(() async {
    await repo.close();
  });

  test('add returns an id and keeps the text', () async {
    final note = await repo.add('the wifi password is hunter2', at: now);

    expect(note.id, isNotNull);
    expect(note.text, 'the wifi password is hunter2');
    expect(note.createdAt, now);
  });

  test('add trims the text before storing', () async {
    final note = await repo.add('   parked on level 3  \n', at: now);

    expect(note.text, 'parked on level 3');
    expect((await repo.byId(note.id!))!.text, 'parked on level 3');
  });

  test('add rejects empty text', () async {
    await expectLater(repo.add(''), throwsArgumentError);
    expect(await repo.count(), 0);
  });

  test('add rejects whitespace-only text', () async {
    await expectLater(repo.add('   \n\t  '), throwsArgumentError);
    expect(await repo.count(), 0);
  });

  test('round trip preserves the text and the time', () async {
    final added = await repo.add('bin day is thursday', at: now);

    final read = await repo.byId(added.id!);

    expect(read!.id, added.id);
    expect(read.text, 'bin day is thursday');
    expect(read.createdAt, now);
  });

  test('byId is null for a row that does not exist', () async {
    expect(await repo.byId(9999), isNull);
  });

  test('update writes the edited text back', () async {
    final added = await repo.add('call the landlord', at: now);

    await repo.update(added.copyWith(text: 'call the landlord on monday'));

    expect((await repo.byId(added.id!))!.text, 'call the landlord on monday');
  });

  test('update rejects a note with no id', () async {
    await expectLater(
      repo.update(Note(text: 'no id', createdAt: now)),
      throwsArgumentError,
    );
  });

  test('delete removes the row', () async {
    final added = await repo.add('temporary thought', at: now);

    await repo.delete(added.id!);

    expect(await repo.byId(added.id!), isNull);
    expect(await repo.all(), isEmpty);
  });

  test('all returns every note newest first', () async {
    await repo.add('oldest', at: now.subtract(const Duration(days: 5)));
    await repo.add('newest', at: now);
    await repo.add('middle', at: now.subtract(const Duration(days: 2)));

    final notes = await repo.all();

    expect(notes.map((n) => n.text), ['newest', 'middle', 'oldest']);
  });

  test('search is case insensitive', () async {
    await repo.add('The Wifi Password Is Hunter2', at: now);

    expect((await repo.search('wifi password')).length, 1);
    expect((await repo.search('WIFI PASSWORD')).length, 1);
    expect((await repo.search('WiFi PaSsWoRd')).length, 1);
  });

  test('search matches a substring anywhere in the text', () async {
    await repo.add('parked on level 3 of the blue garage', at: now);

    expect((await repo.search('level 3')).length, 1);
    expect((await repo.search('garage')).length, 1);
    expect((await repo.search('bicycle')), isEmpty);
  });

  test('search returns matches newest first', () async {
    await repo.add('gym code 1234', at: now.subtract(const Duration(days: 3)));
    await repo.add('shopping list', at: now.subtract(const Duration(days: 2)));
    await repo.add('gym bag in the car', at: now);

    final found = await repo.search('gym');

    expect(found.map((n) => n.text), ['gym bag in the car', 'gym code 1234']);
  });

  test('search treats a percent sign literally, not as a wildcard', () async {
    await repo.add('battery at 50% when I left', at: now);
    await repo.add('we are 50 minutes late', at: now);

    // Unescaped, '%50%%' matches both rows, and a bare '%' matches the lot.
    final found = await repo.search('50%');
    expect(found.length, 1);
    expect(found.single.text, 'battery at 50% when I left');

    expect((await repo.search('%')).single.text, 'battery at 50% when I left');
  });

  test('search treats an underscore literally, not as any character', () async {
    await repo.add('the file is called tax_2026', at: now);
    await repo.add('the file is called taxX2026', at: now);

    final found = await repo.search('tax_2026');

    expect(found.length, 1);
    expect(found.single.text, 'the file is called tax_2026');
  });

  test('search treats a backslash literally', () async {
    await repo.add(r'share is at \\nas\backups', at: now);
    await repo.add('share is at nas backups', at: now);

    final found = await repo.search(r'\\nas');

    expect(found.length, 1);
    expect(found.single.text, r'share is at \\nas\backups');
  });

  test('search with an empty query returns everything', () async {
    await repo.add('one', at: now);
    await repo.add('two', at: now.subtract(const Duration(minutes: 1)));

    expect((await repo.search('')).length, 2);
    expect((await repo.search('   ')).length, 2);
  });

  test('count reflects adds and deletes', () async {
    expect(await repo.count(), 0);

    final first = await repo.add('one', at: now);
    await repo.add('two', at: now);
    expect(await repo.count(), 2);

    await repo.delete(first.id!);
    expect(await repo.count(), 1);
  });

  test('init after close reopens instead of staying shut', () async {
    await repo.add('gone with the in-memory database', at: now);
    await repo.close();

    await repo.init();

    expect(await repo.all(), isEmpty);
  });

  test(
    'use before init throws instead of opening a database silently',
    () async {
      final fresh = NoteRepository(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      await expectLater(fresh.all(), throwsStateError);
    },
  );

  group('fixes for defects found in review', () {
    test('search finds text whose case folding is not ASCII', () async {
      // SQLite's LOWER is ASCII only while Dart's toLowerCase is not, so
      // folding one side in each language made these rows unfindable by the
      // very word they contain. Croatian and German are the obvious cases.
      await repo.add('Caj u CASI je gotov'.replaceAll('C', '\u010c'));
      await repo.add('UBER alles'.replaceAll('U', '\u00dc'));

      expect(await repo.search('\u010dasi'), hasLength(1));
      expect(await repo.search('\u010cASI'), hasLength(1));
      expect(await repo.search('\u00fcber'), hasLength(1));
      expect(await repo.search('\u00dcBER'), hasLength(1));
    });

    test('search still treats wildcards literally', () async {
      await repo.add('battery at 50%');
      await repo.add('we are 50 minutes late');

      // An unescaped LIKE pattern would have matched both of these.
      expect(await repo.search('50%'), hasLength(1));
      expect((await repo.search('50%')).single.text, 'battery at 50%');
      expect(await repo.search('%'), hasLength(1));
    });

    test('update refuses to blank a note, as add does', () async {
      final note = await repo.add('real note');

      await expectLater(
        repo.update(note.copyWith(text: '   ')),
        throwsArgumentError,
      );
      expect((await repo.byId(note.id!))!.text, 'real note');
    });

    test('update trims, so the same text cannot round trip two ways', () async {
      final note = await repo.add('first');
      final saved = await repo.update(note.copyWith(text: '  second  '));

      expect(saved.text, 'second');
      expect((await repo.byId(note.id!))!.text, 'second');
    });

    test('update throws when the row is gone instead of reporting success', () async {
      // Losing an edit behind a success is worse than an error the UI can show.
      final note = await repo.add('doomed');
      await repo.delete(note.id!);

      await expectLater(
        repo.update(note.copyWith(text: 'edited')),
        throwsStateError,
      );
    });
  });
}
