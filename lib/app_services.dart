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

/// The app's long lived collaborators, built once at startup and handed down
/// the widget tree.
///
/// Deliberately a plain object rather than a state management package. There
/// is exactly one screen that needs these and they never change identity.
class AppServices {
  AppServices({
    required this.repository,
    required this.workouts,
    required this.notes,
    required this.food,
    required this.settings,
    required this.scheduler,
    required this.speech,
    required this.permissions,
    required this.gemini,
    required this.apiKeys,
    required this.backups,
    required this.widget,
    this.geminiError,
  });

  final TaskRepository repository;
  final WorkoutRepository workouts;
  final NoteRepository notes;
  final FoodRepository food;
  final SettingsStore settings;
  final ReminderScheduler scheduler;
  final SpeechService speech;
  final PermissionsService permissions;

  /// Where the Gemini key is kept, so the settings screen can change it.
  final ApiKeyStore apiKeys;

  /// Export and restore, the only defence against losing the phone.
  final BackupService backups;

  /// Feeds the home screen widget. Every call is safe to fail.
  final WidgetService widget;

  /// Null when there is no API key. The app still runs in that state so tasks
  /// can be added by hand, which is why this is nullable rather than a hard
  /// failure.
  ///
  /// Not final: the key can be added or replaced from the settings screen at
  /// any time, and a client built once at startup would leave the app claiming
  /// voice parsing is off until the next launch.
  GeminiClient? gemini;

  /// Why [gemini] is null, shown to the user verbatim.
  String? geminiError;

  bool get voiceParsingAvailable => gemini != null;

  /// Rebuilds the Gemini client from whatever key is stored now.
  ///
  /// Called after the key screen closes. The old client is disposed, since it
  /// owns an http client of its own.
  Future<void> refreshGemini() async {
    final key = await apiKeys.read();
    gemini?.close();
    if (key == null) {
      gemini = null;
      geminiError = 'No Gemini key saved yet. Add one in Setup.';
    } else {
      gemini = GeminiClient(apiKey: key);
      geminiError = null;
    }
  }
}
