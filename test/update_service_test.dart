import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rmind/services/update_service.dart';

/// The installed build number and version name are injected through the
/// optional [UpdateService.new] parameter `installed`, chosen over an
/// overridable method so a test never needs a subclass and package_info_plus
/// is never reached. Both halves are needed: the build number drives the
/// normal comparison, the version name the dotted fallback.
const InstalledVersion installed10 =
    InstalledVersion(buildNumber: 3, version: '1.0.0');

const List<Map<String, Object?>> oneApk = [
  {
    'name': 'rmind-release.apk',
    'browser_download_url': 'https://example.test/rmind-release.apk',
    'size': 12345,
  },
];

/// One /releases/latest payload, shaped the way GitHub sends it.
http.Response releaseReply({
  required String tag,
  String notes = '',
  List<Map<String, Object?>> assets = oneApk,
}) {
  return http.Response(
    jsonEncode({'tag_name': tag, 'body': notes, 'assets': assets}),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

UpdateService serviceFor(
  http.Response reply, {
  InstalledVersion installed = installed10,
}) {
  return UpdateService(
    client: MockClient((_) async => reply),
    installed: installed,
  );
}

ReleaseInfo releaseOf(UpdateStatus status) {
  expect(status, isA<UpdateAvailable>(), reason: 'got $status');
  return (status as UpdateAvailable).release;
}

String failureOf(UpdateStatus status) {
  expect(status, isA<UpdateCheckFailed>(), reason: 'got $status');
  return (status as UpdateCheckFailed).message;
}

void main() {
  group('check', () {
    test('asks GitHub for the latest release of the configured repo', () async {
      late http.Request seen;
      final service = UpdateService(
        client: MockClient((request) async {
          seen = request;
          return releaseReply(tag: 'v1.0.0+3');
        }),
        installed: installed10,
      );

      await service.check();

      expect(seen.method, 'GET');
      expect(
        seen.url.toString(),
        'https://api.github.com/repos/'
        '${UpdateService.owner}/${UpdateService.repo}/releases/latest',
      );
      expect(seen.headers['Accept'], 'application/vnd.github+json');
    });

    test('offers the update when the release build number is newer', () async {
      final status = await serviceFor(
        releaseReply(tag: 'v1.1.0+5', notes: '  Fixes the alarm sound.  '),
      ).check();

      final release = releaseOf(status);
      expect(release.version, '1.1.0');
      expect(release.buildNumber, 5);
      expect(release.notes, 'Fixes the alarm sound.');
      expect(release.apkUrl, 'https://example.test/rmind-release.apk');
      expect(release.apkBytes, 12345);
    });

    test('is up to date when the build numbers are equal', () async {
      final status = await serviceFor(releaseReply(tag: 'v1.0.0+3')).check();
      expect(status, isA<UpToDate>());
    });

    test('is up to date when the release build number is older', () async {
      final status = await serviceFor(releaseReply(tag: 'v0.9.0+2')).check();
      expect(status, isA<UpToDate>());
    });

    test('reads a tag shaped "v1.2.0+5"', () async {
      final release = releaseOf(
        await serviceFor(releaseReply(tag: 'v1.2.0+5')).check(),
      );
      expect(release.version, '1.2.0');
      expect(release.buildNumber, 5);
    });

    test('reads a tag shaped "1.2.0+5", with no leading v', () async {
      final release = releaseOf(
        await serviceFor(releaseReply(tag: '1.2.0+5')).check(),
      );
      expect(release.version, '1.2.0');
      expect(release.buildNumber, 5);
    });

    test('compares the build number, not the version name', () async {
      // The tag names an older version but a newer build, which is what a
      // rebuilt release looks like. The build number is what Android enforces.
      final status = await serviceFor(
        releaseReply(tag: 'v0.9.0+9'),
        installed: const InstalledVersion(buildNumber: 3, version: '1.0.0'),
      ).check();

      expect(releaseOf(status).buildNumber, 9);
    });

    group('dotted fallback, for a tag with no build number', () {
      test('treats 1.10.0 as newer than 1.9.0', () async {
        // Pinned deliberately: as strings "1.10.0" sorts before "1.9.0", so a
        // string comparison would answer up to date and never update again.
        final status = await serviceFor(
          releaseReply(tag: 'v1.10.0'),
          installed: const InstalledVersion(buildNumber: 3, version: '1.9.0'),
        ).check();

        final release = releaseOf(status);
        expect(release.version, '1.10.0');
        expect(release.buildNumber, 0);
      });

      test('treats 1.9.0 as older than 1.10.0', () async {
        final status = await serviceFor(
          releaseReply(tag: 'v1.9.0'),
          installed: const InstalledVersion(buildNumber: 3, version: '1.10.0'),
        ).check();

        expect(status, isA<UpToDate>());
      });

      test('is up to date on an identical dotted version', () async {
        final status = await serviceFor(
          releaseReply(tag: 'v1.0.0'),
          installed: installed10,
        ).check();

        expect(status, isA<UpToDate>());
      });

      test('runs when the installed build number cannot be read', () async {
        final status = await serviceFor(
          releaseReply(tag: 'v2.0.0+7'),
          installed: const InstalledVersion(buildNumber: null, version: '1.0.0'),
        ).check();

        expect(releaseOf(status).version, '2.0.0');
      });
    });

    test('fails rather than guessing when the tag carries no version',
        () async {
      final message =
          failureOf(await serviceFor(releaseReply(tag: 'nightly')).check());

      expect(message, contains('nightly'));
      expect(message.toLowerCase(), contains('nothing was downloaded'));
    });

    test('fails when neither the tag nor the install can be compared',
        () async {
      final status = await serviceFor(
        releaseReply(tag: 'v1.5.0'),
        installed: const InstalledVersion(buildNumber: null, version: ''),
      ).check();

      expect(status, isA<UpdateCheckFailed>());
    });

    test('says a 404 means no releases are published yet', () async {
      final service = UpdateService(
        client: MockClient((_) async => http.Response('Not Found', 404)),
        installed: installed10,
      );

      final message = failureOf(await service.check());
      expect(message.toLowerCase(), contains('no releases published yet'));
      expect(message, isNot(contains('404')));
    });

    test('names GitHub rate limiting on a 403 that carries the header',
        () async {
      final service = UpdateService(
        client: MockClient(
          (_) async => http.Response(
            'rate limit exceeded',
            403,
            headers: {'x-ratelimit-remaining': '0'},
          ),
        ),
        installed: installed10,
      );

      expect(
        failureOf(await service.check()).toLowerCase(),
        contains('rate limiting'),
      );
    });

    test('fails cleanly when the release has no APK attached', () async {
      final status = await serviceFor(
        releaseReply(
          tag: 'v1.1.0+5',
          assets: const [
            {
              'name': 'source.zip',
              'browser_download_url': 'https://example.test/source.zip',
              'size': 40,
            },
          ],
        ),
      ).check();

      expect(failureOf(status), contains('no APK'));
    });

    test('fails cleanly when the release has no assets at all', () async {
      final status = await serviceFor(
        releaseReply(tag: 'v1.1.0+5', assets: const []),
      ).check();

      expect(failureOf(status), contains('no APK'));
    });

    test('prefers the arm64 APK when several are attached', () async {
      final status = await serviceFor(
        releaseReply(
          tag: 'v1.1.0+5',
          assets: const [
            {
              'name': 'rmind-armeabi-v7a-release.apk',
              'browser_download_url': 'https://example.test/v7a.apk',
              'size': 10,
            },
            {
              'name': 'rmind-arm64-v8a-release.apk',
              'browser_download_url': 'https://example.test/arm64.apk',
              'size': 20,
            },
            {
              'name': 'rmind-x86_64-release.apk',
              'browser_download_url': 'https://example.test/x86.apk',
              'size': 30,
            },
          ],
        ),
      ).check();

      final release = releaseOf(status);
      expect(release.apkUrl, 'https://example.test/arm64.apk');
      expect(release.apkBytes, 20);
    });

    test('takes the only APK when none names an architecture', () async {
      final release =
          releaseOf(await serviceFor(releaseReply(tag: 'v1.1.0+5')).check());
      expect(release.apkUrl, 'https://example.test/rmind-release.apk');
    });

    test('survives a release with an empty body', () async {
      final release = releaseOf(
        await serviceFor(releaseReply(tag: 'v1.1.0+5')).check(),
      );
      expect(release.notes, isEmpty);
    });

    test('reads release notes as UTF-8 even without a charset', () async {
      final body = jsonEncode({
        'tag_name': 'v1.1.0+5',
        'body': 'Fixes déjà vu',
        'assets': oneApk,
      });
      final service = UpdateService(
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode(body), 200),
        ),
        installed: installed10,
      );

      expect(releaseOf(await service.check()).notes, 'Fixes déjà vu');
    });

    test('reports an unreadable body instead of throwing', () async {
      final service = UpdateService(
        client: MockClient((_) async => http.Response('<html>nope</html>', 200)),
        installed: installed10,
      );

      expect(failureOf(await service.check()), contains('could not read'));
    });

    test('reports a server error with its status', () async {
      final service = UpdateService(
        client: MockClient((_) async => http.Response('boom', 500)),
        installed: installed10,
      );

      expect(failureOf(await service.check()), contains('500'));
    });

    test('reports a network failure instead of throwing', () async {
      final service = UpdateService(
        client: MockClient((_) async => throw http.ClientException('offline')),
        installed: installed10,
      );

      expect(failureOf(await service.check()), contains('offline'));
    });
  });

  group('currentVersionLabel', () {
    test('shows the version name and build number', () async {
      final service = UpdateService(
        client: MockClient((_) async => http.Response('', 404)),
        installed: installed10,
      );

      expect(await service.currentVersionLabel(), '1.0.0 (3)');
    });

    test('drops the build number when it could not be read', () async {
      final service = UpdateService(
        client: MockClient((_) async => http.Response('', 404)),
        installed: const InstalledVersion(buildNumber: null, version: '1.0.0'),
      );

      expect(await service.currentVersionLabel(), '1.0.0');
    });
  });
}
