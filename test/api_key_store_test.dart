import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rmind/services/api_key_store.dart';

/// Distinctive enough that a leak into any message is unmissable.
const String secretKey = 'AIzaSy-TEST-ONLY-NOT-A-REAL-KEY-0123456789';

void main() {
  group('verifyApiKey', () {
    test('200 means the key works', () async {
      final client = MockClient(
        (_) async => http.Response('{"models":[]}', 200),
      );

      final check = await verifyApiKey(secretKey, client: client);

      expect(check.ok, isTrue);
      expect(check.message, isNotEmpty);
    });

    test('sends the key in the x-goog-api-key header', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('{"models":[]}', 200);
      });

      await verifyApiKey('  $secretKey  ', client: client);

      expect(seen.method, 'GET');
      expect(
        seen.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
      // Trimmed, so a key pasted with trailing whitespace is not sent as a
      // different key than the one that gets stored.
      expect(seen.headers['x-goog-api-key'], secretKey);
      // The key belongs in the header only, never in the query string where it
      // would end up in someone's proxy log.
      expect(seen.url.query, isEmpty);
    });

    test('400 is a rejected key, said plainly', () async {
      final client = MockClient(
        (_) async => http.Response('{"error":{"code":400}}', 400),
      );

      final check = await verifyApiKey(secretKey, client: client);

      expect(check.ok, isFalse);
      expect(check.message.toLowerCase(), contains('rejected'));
      expect(check.message, contains('Google AI Studio'));
    });

    test('403 is a rejected key too', () async {
      final client = MockClient(
        (_) async => http.Response('{"error":{"code":403}}', 403),
      );

      final check = await verifyApiKey(secretKey, client: client);

      expect(check.ok, isFalse);
      expect(check.message.toLowerCase(), contains('rejected'));
    });

    test('401 is a rejected key too', () async {
      final client = MockClient((_) async => http.Response('', 401));

      final check = await verifyApiKey(secretKey, client: client);

      expect(check.ok, isFalse);
      expect(check.message.toLowerCase(), contains('rejected'));
    });

    test('a timeout blames the connection, not the key', () async {
      final client = MockClient(
        (_) async => throw TimeoutException('too slow'),
      );

      final check = await verifyApiKey(secretKey, client: client);

      expect(check.ok, isFalse);
      expect(check.message.toLowerCase(), contains('connection'));
      expect(check.message.toLowerCase(), isNot(contains('rejected')));
    });

    test('a socket failure blames the connection, not the key', () async {
      final client = MockClient(
        (_) async => throw http.ClientException('Connection refused'),
      );

      final check = await verifyApiKey(secretKey, client: client);

      expect(check.ok, isFalse);
      expect(check.message.toLowerCase(), contains('connection'));
      expect(check.message.toLowerCase(), isNot(contains('rejected')));
    });

    test('a server fault is not a verdict on the key either', () async {
      final client = MockClient((_) async => http.Response('', 503));

      final check = await verifyApiKey(secretKey, client: client);

      expect(check.ok, isFalse);
      expect(check.message.toLowerCase(), isNot(contains('rejected')));
    });

    test('a blank key never reaches the network', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{"models":[]}', 200);
      });

      final check = await verifyApiKey('   ', client: client);

      expect(check.ok, isFalse);
      expect(called, isFalse);
    });

    test('no outcome ever puts the key in the message', () async {
      final outcomes = <ApiKeyCheck>[
        await verifyApiKey(
          secretKey,
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        await verifyApiKey(
          secretKey,
          client: MockClient((_) async => http.Response('{}', 400)),
        ),
        await verifyApiKey(
          secretKey,
          client: MockClient((_) async => http.Response('{}', 401)),
        ),
        await verifyApiKey(
          secretKey,
          client: MockClient((_) async => http.Response('{}', 403)),
        ),
        await verifyApiKey(
          secretKey,
          client: MockClient((_) async => http.Response('{}', 500)),
        ),
        await verifyApiKey(
          secretKey,
          client: MockClient((_) async => throw TimeoutException('slow')),
        ),
        await verifyApiKey(
          secretKey,
          client: MockClient(
            (_) async => throw http.ClientException('no route to host'),
          ),
        ),
      ];

      for (final outcome in outcomes) {
        expect(outcome.message, isNot(contains(secretKey)));
        expect(outcome.message, isNot(contains('AIzaSy')));
      }
    });
  });

  group('ApiKeyStore.write', () {
    test('rejects a blank key before it touches the keystore', () async {
      // No storage is passed, so a call that got as far as the platform channel
      // would fail loudly here instead of throwing ArgumentError.
      final store = ApiKeyStore();

      expect(() => store.write('   '), throwsArgumentError);
      expect(() => store.write(''), throwsArgumentError);
    });
  });
}
