import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/task.dart';

/// Registers reminders with the Android alarm manager through
/// flutter_local_notifications.
///
/// The OS, not this app, owns a scheduled reminder once it is handed over, so
/// every call here is a write to state that outlives the process. That shapes
/// the design: the task id doubles as the notification id, and [resync] is the
/// only way to guarantee the OS agrees with the database.
///
/// Android gotchas that are easy to get wrong and impossible to unit test:
///
/// * Exact alarms need `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` and the
///   plugin's three receivers in the manifest. Without them the plugin accepts
///   the schedule and the notification simply never arrives.
/// * Channel settings (sound, vibration, importance, DnD bypass) are frozen
///   when the channel is first created. Editing the values below does nothing
///   on a device that already ran the app, so changing them means a new
///   channel id or a reinstall.
/// * `bypassDnd` is silently dropped unless notification policy access was
///   granted, so it is set from [AndroidFlutterLocalNotificationsPlugin
///   .hasNotificationPolicyAccess]. Asking for that access is the permission
///   service's job, not this one's.
/// * Doze defers ordinary alarms. Reminders use `exactAllowWhileIdle`, which
///   fires in Doze but is rate limited to roughly one alarm per app every nine
///   minutes. Alarms use `alarmClock`, which the system treats like a clock
///   app alarm and never defers or rate limits.
/// * `fullScreenIntent` additionally needs `USE_FULL_SCREEN_INTENT` in the
///   manifest. It is not declared there today, so alarms currently degrade to
///   a heads-up notification rather than taking over the screen.
/// * The device time zone has to come from the OS. A hardcoded zone makes
///   every reminder wrong for travelling users and after a DST change.
class ReminderScheduler {
  /// Ordinary reminders. Audible, but does not interrupt.
  static const String reminderChannelId = 'rmind_reminders';

  /// Escalated reminders, intended to be hard to sleep through.
  static const String alarmChannelId = 'rmind_alarms';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Prepares the time zone database and the notification channels.
  ///
  /// Must complete before any other method, and is safe to call twice because
  /// startup paths tend to grow retries.
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    tzdata.initializeTimeZones();
    await _applyDeviceTimeZone();

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _createChannels();
    _initialized = true;
  }

  /// Hands [task] to the OS, keyed by its id so [cancel] can revoke exactly
  /// this reminder.
  ///
  /// Returns quietly for tasks that are done or whose reminder time has
  /// passed. Those are normal states during a [resync], not errors, and the
  /// plugin itself throws on a date in the past.
  Future<void> schedule(Task task) async {
    final int? id = task.id;
    if (id == null) {
      throw ArgumentError.notNull('task.id');
    }
    if (task.isDone) {
      return;
    }

    final tz.TZDateTime fireAt = tz.TZDateTime.from(task.remindAt, tz.local);
    if (!fireAt.isAfter(tz.TZDateTime.now(tz.local))) {
      return;
    }

    await _plugin.zonedSchedule(
      id: id,
      title: task.title,
      body: 'Due at ${_clockTime(task.dueAt)}',
      scheduledDate: fireAt,
      notificationDetails: NotificationDetails(android: _detailsFor(task)),
      androidScheduleMode: task.useAlarm
          ? AndroidScheduleMode.alarmClock
          : AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  /// Revokes the reminder for [taskId], whether it is pending or already on
  /// screen. A no-op when nothing is registered under that id.
  Future<void> cancel(int taskId) => _plugin.cancel(id: taskId);

  /// Revokes every reminder this app registered.
  Future<void> cancelAll() => _plugin.cancelAll();

  /// Rebuilds the OS side from scratch so it matches [pending].
  ///
  /// Cheaper to reason about than diffing, and the only reliable repair after
  /// a reboot, an app update, or a time zone change, all of which can leave
  /// stale alarms behind.
  Future<void> resync(List<Task> pending) async {
    await cancelAll();
    for (final Task task in pending) {
      await schedule(task);
    }
  }

  /// The notification ids the OS currently holds, for reconciling against the
  /// database when a reminder is suspected missing.
  Future<List<int>> scheduledIds() async {
    final List<PendingNotificationRequest> requests = await _plugin
        .pendingNotificationRequests();
    return requests
        .map((PendingNotificationRequest request) => request.id)
        .toList(growable: false);
  }

  /// Falls back to UTC when the device reports a zone the tz database does not
  /// know, which some OEM ROMs do. The fire time stays correct because the
  /// plugin sends a full ISO 8601 offset to the platform, what is lost is the
  /// recalculation across a DST boundary.
  Future<void> _applyDeviceTimeZone() async {
    String? name;
    try {
      name = (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {
      name = null;
    }
    if (name == null) {
      tz.setLocalLocation(tz.UTC);
      return;
    }
    try {
      tz.setLocalLocation(tz.getLocation(name));
    } on tz.LocationNotFoundException {
      tz.setLocalLocation(tz.UTC);
    }
  }

  Future<void> _createChannels() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      return;
    }

    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        reminderChannelId,
        'Reminders',
        description: 'Scheduled reminders for your tasks.',
        importance: Importance.high,
      ),
    );

    // Requesting policy access would throw the user into a settings screen at
    // startup, so the channel is created with whatever access already exists.
    final bool canBypassDnd =
        await android.hasNotificationPolicyAccess() ?? false;

    await android.createNotificationChannel(
      AndroidNotificationChannel(
        alarmChannelId,
        'Alarms',
        description: 'Loud reminders that should wake you.',
        importance: Importance.max,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        bypassDnd: canBypassDnd,
      ),
    );
  }

  /// Mirrors the channel configuration, which matters only when the channel is
  /// missing. On Android 8.0 and newer the channel wins over these values.
  AndroidNotificationDetails _detailsFor(Task task) {
    if (task.useAlarm) {
      return const AndroidNotificationDetails(
        alarmChannelId,
        'Alarms',
        channelDescription: 'Loud reminders that should wake you.',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        fullScreenIntent: true,
        visibility: NotificationVisibility.public,
      );
    }
    return const AndroidNotificationDetails(
      reminderChannelId,
      'Reminders',
      channelDescription: 'Scheduled reminders for your tasks.',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    );
  }

  /// 24 hour clock, hand rolled to keep intl out of the dependency list.
  String _clockTime(DateTime time) {
    final String hour = time.hour.toString().padLeft(2, '0');
    final String minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
