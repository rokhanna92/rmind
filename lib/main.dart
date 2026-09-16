import 'package:flutter/material.dart';

import 'app_services.dart';
import 'data/food_repository.dart';
import 'data/note_repository.dart';
import 'data/task_repository.dart';
import 'data/workout_repository.dart';
import 'services/api_key_store.dart';
import 'services/backup_service.dart';
import 'services/gemini_client.dart';
import 'services/permissions_service.dart';
import 'services/settings_store.dart';
import 'services/reminder_scheduler.dart';
import 'services/speech_service.dart';
import 'services/widget_service.dart';
import 'ui/design.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final repository = TaskRepository();
  await repository.init();

  final workouts = WorkoutRepository();
  await workouts.init();

  final notes = NoteRepository();
  await notes.init();

  final food = FoodRepository();
  await food.init();

  final scheduler = ReminderScheduler();
  await scheduler.init();

  // Scheduled alarms live in the OS, not in our database, and are lost on a
  // reboot, an app update or a force stop. Re-registering everything still
  // pending on every launch is cheap and makes those cases self healing.
  await scheduler.resync(await repository.pendingReminders(DateTime.now()));

  // The key lives in the Android Keystore now, not in the binary. That is what
  // lets the APK be published for the updater to fetch without shipping a
  // secret to whoever downloads it.
  final apiKeys = ApiKeyStore();
  final apiKey = await apiKeys.read();

  GeminiClient? gemini;
  String? geminiError;
  if (apiKey == null) {
    geminiError = 'No Gemini key saved yet. Add one in Setup.';
  } else {
    gemini = GeminiClient(apiKey: apiKey);
  }

  // Deliberately NOT initialised here. The recogniser raises the microphone
  // permission dialog as part of initialize(), and doing that before runApp()
  // means the very first thing the user ever sees is a bare system prompt with
  // no app behind it. It is initialised on the first voice capture instead.
  final speech = SpeechService();

  runApp(
    RmindApp(
      services: AppServices(
        repository: repository,
        workouts: workouts,
        notes: notes,
        food: food,
        settings: SettingsStore(),
        scheduler: scheduler,
        speech: speech,
        permissions: PermissionsService(),
        gemini: gemini,
        geminiError: geminiError,
        apiKeys: apiKeys,
        backups: BackupService(
          tasks: repository,
          workouts: workouts,
          notes: notes,
        ),
        widget: WidgetService(),
      ),
    ),
  );
}

class RmindApp extends StatelessWidget {
  const RmindApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    // The design is a single dark scheme. themeMode is pinned rather than left
    // on system, so a phone set to light does not get handed a palette that
    // was never designed.
    return MaterialApp(
      title: 'RMIND',
      debugShowCheckedModeBanner: false,
      theme: RM.theme(),
      darkTheme: RM.theme(),
      themeMode: ThemeMode.dark,
      home: HomePage(services: services),
    );
  }
}
