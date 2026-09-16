import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A snapshot of everything RMIND asks the OS for.
class PermissionReport {
  const PermissionReport({
    required this.microphone,
    required this.notifications,
    required this.exactAlarms,
    required this.batteryOptimisationDisabled,
  });

  final bool microphone;
  final bool notifications;
  final bool exactAlarms;
  final bool batteryOptimisationDisabled;

  /// Battery optimisation is deliberately left out. Without the exemption
  /// reminders are late rather than absent, so onboarding must not block on a
  /// dialog the user is allowed to refuse.
  bool get allCritical => microphone && notifications && exactAlarms;
}

/// Checks and requests the Android permissions the reminder pipeline needs.
///
/// There is no general purpose permission dependency here on purpose. Three of
/// the four permissions are already exposed by plugins the app must ship
/// anyway, and the fourth goes through a small method channel in MainActivity.
/// Adding a library to duplicate APIs we already have was not worth the
/// compileSdk conflict it brought with it.
///
/// Every check resolves to granted when the underlying API is missing. Several
/// of these permissions only exist above a given API level, and answering
/// "denied" for one that cannot exist would strand the user on a setup screen
/// showing a button that can never turn green.
class PermissionsService {
  PermissionsService({
    SpeechToText? speech,
    FlutterLocalNotificationsPlugin? notifications,
    MethodChannel? batteryChannel,
  })  : _speech = speech ?? SpeechToText(),
        _notifications = notifications ?? FlutterLocalNotificationsPlugin(),
        _battery = batteryChannel ?? const MethodChannel(_batteryChannelName);

  static const String _batteryChannelName = 'com.rmind.app/battery';

  final SpeechToText _speech;
  final FlutterLocalNotificationsPlugin _notifications;
  final MethodChannel _battery;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> microphoneGranted() =>
      _guard(() => _speech.hasPermission, onError: false);

  /// The recogniser has no standalone request call. Running initialize() is
  /// what raises the system prompt, and it is safe to run more than once.
  Future<bool> requestMicrophone() => _guard(() async {
        if (await _speech.hasPermission) return true;
        await _speech.initialize();
        return _speech.hasPermission;
      }, onError: false);

  Future<bool> notificationsGranted() =>
      _guard(() async => await _android?.areNotificationsEnabled() ?? true);

  Future<bool> requestNotifications() => _guard(
      () async => await _android?.requestNotificationsPermission() ?? true);

  Future<bool> exactAlarmsGranted() => _guard(
      () async => await _android?.canScheduleExactNotifications() ?? true);

  /// Sends the user to a full system settings screen rather than a dialog, so
  /// the answer here says only that the screen opened. The onboarding page
  /// re-checks once the user comes back.
  Future<bool> requestExactAlarms() =>
      _guard(() async => await _android?.requestExactAlarmsPermission() ?? true);

  Future<bool> batteryOptimisationDisabled() => _guard(() async =>
      await _battery.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
      true);

  Future<bool> requestDisableBatteryOptimisation() => _guard(() async =>
      await _battery.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
      true);

  Future<PermissionReport> checkAll() async {
    return PermissionReport(
      microphone: await microphoneGranted(),
      notifications: await notificationsGranted(),
      exactAlarms: await exactAlarmsGranted(),
      batteryOptimisationDisabled: await batteryOptimisationDisabled(),
    );
  }

  /// Microphone is the one permission that must report denied when it cannot
  /// be determined, since it genuinely exists on every supported version and a
  /// false positive would send the user into a recogniser that cannot hear.
  Future<bool> _guard(Future<bool> Function() read, {bool onError = true}) async {
    try {
      return await read();
    } on PlatformException {
      return onError;
    } on MissingPluginException {
      return onError;
    }
  }
}
