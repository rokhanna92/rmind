import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One published GitHub release, reduced to what an install needs.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.buildNumber,
    required this.notes,
    required this.apkUrl,
    required this.apkBytes,
  });

  /// The dotted version name from the tag, e.g. "1.2.0".
  final String version;

  /// The Android versionCode, the +N half of the tag. Zero when the tag did
  /// not carry one: the comparison then ran on the dotted parts instead, and
  /// this value only names the downloaded file after that.
  final int buildNumber;

  /// The release body. Often empty, so the UI must survive that.
  final String notes;

  final String apkUrl;

  /// The asset size GitHub reported, used to verify the finished download.
  final int apkBytes;

  @override
  String toString() =>
      'ReleaseInfo($version+$buildNumber, $apkBytes bytes, $apkUrl)';
}

/// What is installed on this device right now.
///
/// Both halves travel together because the comparison needs whichever one the
/// release tag can be read against: the versionCode when the tag carries one,
/// the dotted name when it does not.
class InstalledVersion {
  const InstalledVersion({required this.buildNumber, required this.version});

  /// Null when package_info handed back something that is not an integer.
  final int? buildNumber;

  /// The version name, e.g. "1.0.0". Empty when it could not be read.
  final String version;

  @override
  String toString() => 'InstalledVersion($version+$buildNumber)';
}

sealed class UpdateStatus {
  const UpdateStatus();
}

class UpToDate extends UpdateStatus {
  const UpToDate();
}

class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.release);

  final ReleaseInfo release;
}

/// [message] is written to be shown to the user as is, so it says what
/// happened rather than naming an HTTP status.
class UpdateCheckFailed extends UpdateStatus {
  const UpdateCheckFailed(this.message);

  final String message;
}

/// Anything that stopped a download from becoming an installable file.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => 'UpdateException: $message';
}

/// Finds the newest GitHub release, downloads its APK and hands it to the
/// system installer.
///
/// Android always asks the user to confirm the install and there is no way to
/// skip that, so nothing here pretends the install is done once [install]
/// returns. It returns whether the installer opened, nothing more.
class UpdateService {
  UpdateService({
    http.Client? client,
    MethodChannel? channel,
    InstalledVersion? installed,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _channel = channel ?? const MethodChannel(_channelName),
        _installedOverride = installed;

  /// Kept public so the repository can move without hunting through the file.
  static const String owner = 'rokhanna92';
  static const String repo = 'rmind';

  /// The same channel MainActivity already answers for battery optimisation.
  static const String _channelName = 'com.rmind.app/battery';

  static const Duration _checkTimeout = Duration(seconds: 20);

  /// Time to the first byte. The body itself is not bounded: a slow connection
  /// downloading a 60 MB APK is working, not hung.
  static const Duration _connectTimeout = Duration(seconds: 30);

  /// "v1.2.0+5" and "1.2.0+5" both land here. Anything else is refused rather
  /// than guessed at.
  static final RegExp _tagPattern =
      RegExp(r'^v?(\d+(?:\.\d+)*)(?:\+(\d+))?$', caseSensitive: false);

  final http.Client _client;
  final bool _ownsClient;
  final MethodChannel _channel;
  final InstalledVersion? _installedOverride;

  /// The newest release, compared against what is installed.
  Future<UpdateStatus> check() async {
    final installed = await _installed();

    final http.Response response;
    try {
      response = await _client.get(
        Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(_checkTimeout);
    } on TimeoutException {
      return const UpdateCheckFailed(
        'GitHub took too long to answer. Check your connection and try again.',
      );
    } on http.ClientException catch (error) {
      return UpdateCheckFailed('Could not reach GitHub: ${error.message}');
    } on Exception catch (error) {
      return UpdateCheckFailed('Could not reach GitHub: $error');
    }

    if (response.statusCode == 404) {
      return const UpdateCheckFailed(
        'There are no releases published yet, so there is nothing to '
        'update to.',
      );
    }
    if (response.statusCode == 403 && _isRateLimited(response)) {
      return const UpdateCheckFailed(
        'GitHub is rate limiting update checks right now. Try again in a '
        'little while.',
      );
    }
    if (response.statusCode != 200) {
      return UpdateCheckFailed(
        'GitHub could not be asked for the latest release '
        '(${response.statusCode}). Try again in a moment.',
      );
    }

    final Object? payload;
    try {
      // Decoded from the bytes rather than response.body: without a charset in
      // the content type that getter falls back to latin1 and mangles any
      // accent or emoji in the release notes.
      payload = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      return const UpdateCheckFailed(
        'GitHub sent something this app could not read. Try again.',
      );
    }
    if (payload is! Map<String, dynamic>) {
      return const UpdateCheckFailed(
        'GitHub sent something this app could not read. Try again.',
      );
    }

    final rawTag = payload['tag_name'];
    final tag = rawTag is String ? rawTag.trim() : '';
    final parsed = _parseTag(tag);
    if (parsed == null) {
      return UpdateCheckFailed(
        'The latest release is tagged "$tag", which carries no version number '
        'this app can compare. Nothing was downloaded.',
      );
    }

    final newer = _isNewer(parsed, installed);
    if (newer == null) {
      return UpdateCheckFailed(
        'Could not tell whether "$tag" is newer than the installed version '
        '${installed.version.isEmpty ? '(unknown)' : installed.version}. '
        'Nothing was downloaded.',
      );
    }
    if (!newer) return const UpToDate();

    final asset = _pickApk(payload['assets']);
    if (asset == null) {
      return UpdateCheckFailed(
        'Release ${parsed.version} has no APK attached, so there is nothing '
        'to install.',
      );
    }

    final notes = payload['body'];
    return UpdateAvailable(
      ReleaseInfo(
        version: parsed.version,
        buildNumber: parsed.build ?? 0,
        notes: notes is String ? notes.trim() : '',
        apkUrl: asset.url,
        apkBytes: asset.bytes,
      ),
    );
  }

  /// Streams the APK into the cache directory the FileProvider is scoped to.
  ///
  /// The file must land in `<cacheDir>/updates/` or the system installer
  /// cannot read it back through the provider.
  Future<File> download(
    ReleaseInfo release, {
    void Function(double)? onProgress,
  }) async {
    final cache = await getTemporaryDirectory();
    final folder = Directory(p.join(cache.path, 'updates'));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final file = File(p.join(folder.path, 'rmind-${release.buildNumber}.apk'));
    // A half written file from a failed attempt must never be installable, so
    // the old one dies before the new one starts rather than after.
    await _deleteQuietly(file);

    final http.StreamedResponse response;
    try {
      response = await _client
          .send(http.Request('GET', Uri.parse(release.apkUrl)))
          .timeout(_connectTimeout);
    } on TimeoutException {
      throw const UpdateException(
        'The download did not start. Check your connection and try again.',
      );
    } on http.ClientException catch (error) {
      throw UpdateException('The download failed: ${error.message}');
    }

    if (response.statusCode != 200) {
      // The socket stays checked out of the pool until the body is read, so
      // the error body is drained rather than abandoned.
      try {
        await response.stream.drain<void>();
      } catch (_) {
        // The status is the answer; a broken error body changes nothing.
      }
      throw UpdateException(
        'GitHub refused the download (${response.statusCode}). Try again.',
      );
    }

    // The asset size stands in when the response has no content-length, which
    // is what a redirected download sometimes looks like.
    final total = response.contentLength ?? release.apkBytes;
    onProgress?.call(0);

    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final fraction = received / total;
          onProgress?.call(fraction > 1 ? 1 : fraction);
        }
      }
      await sink.flush();
      await sink.close();
    } catch (error) {
      // The handle has to be released before the partial file can be removed,
      // and closing an already closed sink is a no-op.
      try {
        await sink.close();
      } catch (_) {
        // Already broken; the delete below is what matters.
      }
      await _deleteQuietly(file);
      if (error is UpdateException) rethrow;
      throw UpdateException('The download failed: $error');
    }

    // A truncated APK reaches the installer as a parse error nobody can act
    // on, so it is caught here where the cause is still known. The asset size
    // is the better witness, but content-length still catches a stream that
    // died early when GitHub sent no size with the asset.
    final expected = release.apkBytes > 0 ? release.apkBytes : total;
    if (expected > 0 && received != expected) {
      await _deleteQuietly(file);
      throw UpdateException(
        'The download was incomplete: $received of $expected bytes arrived. '
        'Try again.',
      );
    }

    onProgress?.call(1);
    return file;
  }

  /// Whether Android currently lets RMIND install packages.
  Future<bool> canInstall() => _ask('canInstallPackages');

  /// Opens the system settings screen. The answer says only that the screen
  /// opened, so the caller has to re-check afterwards.
  Future<bool> requestInstallPermission() => _ask('requestInstallPermission');

  /// Hands the APK to the system installer, which then asks the user to
  /// confirm. True means the installer opened, not that anything was installed.
  Future<bool> install(File apk) => _ask('installApk', {'path': apk.path});

  /// "1.0.0 (1)", for showing the user what they are already running.
  Future<String> currentVersionLabel() async {
    final installed = await _installed();
    final name = installed.version.isEmpty ? 'unknown' : installed.version;
    final build = installed.buildNumber;
    return build == null ? name : '$name ($build)';
  }

  /// Releases the HTTP client, but only if it was not handed in.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<InstalledVersion> _installed() async {
    final injected = _installedOverride;
    if (injected != null) return injected;
    try {
      final info = await PackageInfo.fromPlatform();
      return InstalledVersion(
        buildNumber: int.tryParse(info.buildNumber.trim()),
        version: info.version.trim(),
      );
    } on MissingPluginException {
      return const InstalledVersion(buildNumber: null, version: '');
    } on PlatformException {
      return const InstalledVersion(buildNumber: null, version: '');
    }
  }

  /// Null when neither comparison can be made. Guessing here is the worst of
  /// the three answers: it either nags forever or silently never updates.
  bool? _isNewer(_Tag release, InstalledVersion installed) {
    final installedBuild = installed.buildNumber;
    if (release.build != null && installedBuild != null) {
      return release.build! > installedBuild;
    }

    final mine = _dottedParts(installed.version);
    if (mine == null || release.parts.isEmpty) return null;
    return _compareParts(release.parts, mine) > 0;
  }

  /// Compares dotted versions field by field as numbers, so 1.10.0 is newer
  /// than 1.9.0. Comparing them as strings gets that backwards.
  int _compareParts(List<int> a, List<int> b) {
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left.compareTo(right);
    }
    return 0;
  }

  List<int>? _dottedParts(String version) {
    final trimmed = version.trim();
    if (trimmed.isEmpty) return null;
    final parts = <int>[];
    for (final piece in trimmed.split('.')) {
      final value = int.tryParse(piece);
      if (value == null) return null;
      parts.add(value);
    }
    return parts.isEmpty ? null : parts;
  }

  _Tag? _parseTag(String tag) {
    final match = _tagPattern.firstMatch(tag.trim());
    if (match == null) return null;
    final version = match.group(1)!;
    final parts = _dottedParts(version);
    if (parts == null) return null;
    final build = match.group(2);
    return _Tag(version, parts, build == null ? null : int.parse(build));
  }

  /// The one APK worth downloading. Several architectures may be attached, and
  /// arm64 is what every phone this app targets actually runs.
  _Asset? _pickApk(Object? raw) {
    if (raw is! List) return null;

    _Asset? first;
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final url = entry['browser_download_url'];
      if (name is! String || url is! String) continue;
      if (!name.toLowerCase().endsWith('.apk')) continue;

      final size = entry['size'];
      final asset = _Asset(url, size is num ? size.toInt() : 0);
      if (name.toLowerCase().contains('arm64')) return asset;
      first ??= asset;
    }
    return first;
  }

  bool _isRateLimited(http.Response response) {
    final remaining = response.headers['x-ratelimit-remaining'];
    if (remaining != null && (int.tryParse(remaining) ?? 1) <= 0) return true;
    return response.headers.containsKey('retry-after');
  }

  /// Every native answer degrades to false rather than throwing. A missing
  /// method means an older install of the app whose MainActivity does not
  /// answer yet, which is a reason to show the user a plain message, not a
  /// reason to take down the sheet.
  Future<bool> _ask(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing useful to do: the write below fails loudly if this mattered.
    }
  }
}

/// A release tag split into its dotted version and its optional build number.
class _Tag {
  const _Tag(this.version, this.parts, this.build);

  final String version;
  final List<int> parts;
  final int? build;
}

class _Asset {
  const _Asset(this.url, this.bytes);

  final String url;
  final int bytes;
}
