import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// The Gemini API key, kept in the Android Keystore instead of the binary.
///
/// The key used to arrive through `String.fromEnvironment`, which baked it into
/// every APK and turned the build output itself into a secret that could not be
/// hosted or handed to anyone. Nothing in this file reads the environment, on
/// purpose: the build time path is gone, not merely unused.
///
/// Every method swallows a failing platform channel and reports "no key". The
/// store is touched during startup, and a device whose keystore is unavailable
/// must land on the settings screen asking for a key rather than on a crash it
/// cannot get past. The cost is that a failed [write] is silent, so [read] is
/// the only source of truth about what is actually stored.
class ApiKeyStore {
  ApiKeyStore({FlutterSecureStorage? storage})
      : _storage =
            storage ?? const FlutterSecureStorage(aOptions: _androidOptions);

  /// flutter_secure_storage 11 dropped the `encryptedSharedPreferences` flag.
  /// What it replaced that flag with is this, the only Android mode left:
  /// AES-GCM over the value, with the data key wrapped by an RSA key the
  /// Android Keystore holds. There is no weaker path to opt out of any more.
  static const AndroidOptions _androidOptions = AndroidOptions();

  static const String _slot = 'gemini_api_key';

  final FlutterSecureStorage _storage;

  /// The stored key, or null when there is none worth using.
  ///
  /// A blank stored value counts as missing. A half written or cleared slot
  /// would otherwise sail through as a key and fail later as an opaque 400.
  Future<String?> read() async {
    final String? stored;
    try {
      stored = await _storage.read(key: _slot);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }

    final key = stored?.trim();
    if (key == null || key.isEmpty) return null;
    return key;
  }

  /// Stores [key], trimmed. Rejects a blank key rather than writing one, since
  /// [read] would report it as missing and the caller would never learn why.
  Future<void> write(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(key, 'key', 'An API key cannot be blank');
    }
    await _guard(() => _storage.write(key: _slot, value: trimmed));
  }

  Future<void> clear() => _guard(() => _storage.delete(key: _slot));

  Future<bool> hasKey() async => await read() != null;

  Future<void> _guard(Future<void> Function() operation) async {
    try {
      await operation();
    } on PlatformException {
      // No keystore, so nothing was stored. read() will say so.
    } on MissingPluginException {
      // Same, on a host with no plugin registered.
    }
  }
}

/// The verdict on a key, written to be shown to the user as is.
class ApiKeyCheck {
  const ApiKeyCheck({required this.ok, required this.message});

  final bool ok;

  /// Never contains the key. This text reaches the screen and the clipboard.
  final String message;

  @override
  String toString() => 'ApiKeyCheck(ok: $ok, message: $message)';
}

/// Where the cheapest authenticated call lives: listing models costs no tokens
/// and still fails on a bad key.
const String _modelsEndpoint =
    'https://generativelanguage.googleapis.com/v1beta/models';

const Duration _verifyTimeout = Duration(seconds: 15);

/// A network problem is never a verdict on the key, so all three phrasings of
/// it say the same thing and none of them imply the key is wrong.
const String _unreachable =
    'Could not reach Gemini, check your connection. This says nothing about '
    'the key, try again once you are online.';

const String _rejected =
    'Gemini rejected this key. Check it was copied whole from Google AI '
    'Studio, with no spaces at either end.';

/// Confirms a key actually works before it is stored, by making the cheapest
/// possible real call.
///
/// Storing an unverified key means the failure surfaces mid sentence, at the
/// one moment the user is holding the phone to their mouth expecting it to
/// work. Pay for the round trip here instead.
Future<ApiKeyCheck> verifyApiKey(String key, {http.Client? client}) async {
  final trimmed = key.trim();
  if (trimmed.isEmpty) {
    return const ApiKeyCheck(ok: false, message: 'Enter a key first.');
  }

  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(Uri.parse(_modelsEndpoint), headers: {'x-goog-api-key': trimmed})
        .timeout(_verifyTimeout);

    final status = response.statusCode;
    if (status == 200) {
      return const ApiKeyCheck(ok: true, message: 'This key works.');
    }
    if (status == 400 || status == 401 || status == 403) {
      return const ApiKeyCheck(ok: false, message: _rejected);
    }
    // 429 and the 5xx family are Google having a bad minute. Saying the key is
    // bad here would send the user off to mint a replacement for nothing.
    return ApiKeyCheck(
      ok: false,
      message: 'Gemini answered with an error ($status), so the key could not '
          'be checked. Try again in a moment.',
    );
  } on TimeoutException {
    return const ApiKeyCheck(ok: false, message: _unreachable);
  } on http.ClientException {
    return const ApiKeyCheck(ok: false, message: _unreachable);
  } on Exception {
    // Socket and TLS failures arrive in several shapes depending on the
    // platform. Every one of them is a reachability problem, and the message
    // deliberately carries no detail from the error, which could quote the URL
    // and with it a key some other caller put in a query string.
    return const ApiKeyCheck(ok: false, message: _unreachable);
  } finally {
    if (client == null) httpClient.close();
  }
}
