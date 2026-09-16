import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/task.dart';
import '../models/workout_session.dart';

/// What the model pulled out of one spoken sentence.
///
/// This is deliberately not a [Task]: nothing here has been persisted yet, and
/// [needsClarification] is a hint for the UI that dies before the row is saved.
class ParsedTask {
  const ParsedTask({
    required this.title,
    required this.dueAt,
    required this.reminderMinutesBefore,
    required this.useAlarm,
    required this.needsClarification,
  });

  final String title;

  /// Local time, already rolled forward if the model handed back the past.
  final DateTime dueAt;

  final int reminderMinutesBefore;
  final bool useAlarm;

  /// True when the time was guessed rather than heard, so the UI should ask.
  final bool needsClarification;

  @override
  String toString() =>
      'ParsedTask(title: $title, dueAt: $dueAt, '
      'reminder: ${reminderMinutesBefore}m, alarm: $useAlarm, '
      'needsClarification: $needsClarification)';
}

/// What one spoken sentence turned out to mean.
///
/// The app has a single microphone, so the model classifies before it extracts
/// and the caller switches on the result instead of guessing from the words.
sealed class ParsedIntent {
  const ParsedIntent();
}

/// The default reading: the user asked to be reminded of something.
class ReminderIntent extends ParsedIntent {
  const ReminderIntent(this.task);

  final ParsedTask task;

  @override
  String toString() => 'ReminderIntent($task)';
}

/// The user said they had arrived at the gym or were starting a workout.
class WorkoutStartIntent extends ParsedIntent {
  const WorkoutStartIntent(this.type);

  /// What they are training, already falling back to [WorkoutSession.unnamed]
  /// when they did not say, so the caller never has to handle an empty string.
  final String type;

  @override
  String toString() => 'WorkoutStartIntent($type)';
}

/// The user recorded something to remember, with no time and no alarm.
///
/// Separate from [ReminderIntent] because forcing a fact into a reminder means
/// inventing a time for it, which schedules an interruption nobody asked for.
class NoteIntent extends ParsedIntent {
  const NoteIntent(this.text);

  /// The sentence to keep, already trimmed and never empty: it falls back to
  /// the raw transcript rather than losing what the user said.
  final String text;

  @override
  String toString() => 'NoteIntent($text)';
}

/// The user said they were done, finished, or leaving the gym.
class WorkoutEndIntent extends ParsedIntent {
  const WorkoutEndIntent();

  @override
  String toString() => 'WorkoutEndIntent()';
}

/// Anything that stopped a transcript from becoming a [ParsedTask].
///
/// [message] is written to be shown to the user as is, so it says what to do
/// next rather than naming an HTTP status.
class GeminiException implements Exception {
  const GeminiException(this.message, {this.isRetryable = false});

  final String message;

  /// True when trying the exact same request later could plausibly work,
  /// which is what lets the UI offer a retry button instead of an apology.
  final bool isRetryable;

  @override
  String toString() => 'GeminiException: $message';
}

/// Turns a voice transcript into a structured reminder via the Gemini REST API.
///
/// Plain REST rather than a Google SDK: the whole contract is one POST, and the
/// SDK would drag in transitive dependencies for nothing.
class GeminiClient {
  GeminiClient({required this._apiKey, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;


  /// Benchmarked against the live API: fast and it does not 503 under load.
  /// Newer models measured slower and flakier, so this is not a version to bump
  /// without re-running that comparison.
  static const String primaryModel = 'gemini-2.5-flash';

  /// Slower but independent capacity, used only once the primary is failing.
  static const String fallbackModel = 'gemini-3.6-flash';

  static const String _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// Per request ceiling. The overall budget below is what actually bounds the
  /// user's wait, since a hung first attempt must still leave room to retry.
  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _totalBudget = Duration(seconds: 25);
  static const Duration _retryDelay = Duration(milliseconds: 500);

  /// Statuses worth trying again: overload and transient server faults.
  static const Set<int> _retryableStatuses = {429, 500, 503};

  /// finishReason values that mean the model refused rather than answered.
  static const Set<String> _blockedReasons = {
    'SAFETY',
    'RECITATION',
    'PROHIBITED_CONTENT',
    'BLOCKLIST',
    'SPII',
  };

  static const List<String> _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  /// The validated response contract. Types are uppercase, which is the form
  /// the v1beta endpoint accepts.
  static const Map<String, Object> _responseSchema = {
    'type': 'OBJECT',
    'properties': {
      'title': {'type': 'STRING'},
      'date': {'type': 'STRING'},
      'time': {'type': 'STRING'},
      'reminderMinutesBefore': {'type': 'INTEGER'},
      'useAlarm': {'type': 'BOOLEAN'},
      'needsClarification': {'type': 'BOOLEAN'},
    },
    'required': [
      'title',
      'date',
      'time',
      'reminderMinutesBefore',
      'useAlarm',
      'needsClarification',
    ],
  };

  /// The reminder contract plus the routing field. "intent" is an enum in the
  /// schema rather than a prompt rule, so the model cannot answer with a
  /// category the switch in [interpret] would have to guess at. The reminder
  /// fields stay required: they are ignored for the workout and note intents,
  /// and loosening them weakens the reminder path, which is the common one.
  static const Map<String, Object> _intentSchema = {
    'type': 'OBJECT',
    'properties': {
      'intent': {
        'type': 'STRING',
        'enum': ['reminder', 'note', 'workout_start', 'workout_end'],
      },
      'title': {'type': 'STRING'},
      'date': {'type': 'STRING'},
      'time': {'type': 'STRING'},
      'reminderMinutesBefore': {'type': 'INTEGER'},
      'useAlarm': {'type': 'BOOLEAN'},
      'needsClarification': {'type': 'BOOLEAN'},
      'workoutType': {'type': 'STRING'},
      'noteText': {'type': 'STRING'},
    },
    'required': [
      'intent',
      'title',
      'date',
      'time',
      'reminderMinutesBefore',
      'useAlarm',
      'needsClarification',
    ],
  };

  final String _apiKey;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// Extracts one reminder from [transcript].
  ///
  /// [now] is injectable so relative dates ("Friday evening") can be tested and
  /// so the caller can pin a single reference instant across a parse.
  Future<ParsedTask> extract(String transcript, {DateTime? now}) async {
    final text = transcript.trim();
    if (text.isEmpty) {
      throw const GeminiException(
        'There was nothing to read back. Try saying the reminder again.',
      );
    }

    final reference = (now ?? DateTime.now()).toLocal();
    final fields = await _exchange(
      _systemPrompt(reference),
      text,
      _responseSchema,
    );
    return _toParsedTask(fields, reference);
  }

  /// Decides what [transcript] was: a reminder, a note worth keeping, arriving
  /// at the gym, or leaving it. The app has one microphone, so this routing is
  /// the model's job.
  ///
  /// [now] is injectable for the same reason as in [extract].
  Future<ParsedIntent> interpret(String transcript, {DateTime? now}) async {
    final text = transcript.trim();
    if (text.isEmpty) {
      throw const GeminiException(
        'There was nothing to read back. Try saying that again.',
      );
    }

    final reference = (now ?? DateTime.now()).toLocal();
    final fields = await _exchange(
      _intentPrompt(reference),
      text,
      _intentSchema,
    );

    final intent = fields['intent'];
    switch (intent) {
      case 'workout_start':
        final raw = fields['workoutType'];
        final type = _sentenceCase(raw is String ? raw.trim() : '');
        return WorkoutStartIntent(
          type.isEmpty ? WorkoutSession.unnamed : type,
        );
      case 'workout_end':
        // Every reminder field is noise here, by design.
        return const WorkoutEndIntent();
      case 'note':
        final raw = fields['noteText'];
        final noteText = raw is String ? raw.trim() : '';
        // Keeping the sentence unpolished beats dropping it: the user said it
        // out loud precisely so it would not be lost.
        return NoteIntent(noteText.isEmpty ? text : noteText);
      case 'reminder':
        return ReminderIntent(_toParsedTask(fields, reference));
      default:
        // The schema forbids this, so reaching it means the contract moved.
        // Saying what came back beats a cast that throws somewhere else.
        final label = intent is String && intent.trim().isNotEmpty
            ? '"${_snippet(intent)}"'
            : 'nothing';
        throw GeminiException(
          'Gemini answered with an intent this app does not understand '
          '($label). Try saying that again.',
        );
    }
  }

  /// Releases the HTTP client, but only if it was not handed in: a caller that
  /// shares one client across services still owns it.
  void close() {
    if (_ownsClient) _httpClient.close();
  }

  /// Runs the retry plan and returns the fields of the first good answer.
  Future<Map<String, dynamic>> _exchange(
    String systemPrompt,
    String transcript,
    Map<String, Object> schema,
  ) async {
    final deadline = DateTime.now().add(_totalBudget);

    // Primary twice, because most 503s clear within a second, then fallback.
    const plan = [primaryModel, primaryModel, fallbackModel];
    GeminiException? lastFailure;

    for (var attempt = 0; attempt < plan.length; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryDelay);
      }
      try {
        return await _request(
          plan[attempt],
          systemPrompt,
          transcript,
          schema,
          deadline,
        );
      } on GeminiException catch (error) {
        if (!error.isRetryable) rethrow;
        lastFailure = error;
      }
    }

    throw lastFailure!;
  }

  /// Sends one request and returns the decoded inner JSON object.
  Future<Map<String, dynamic>> _request(
    String model,
    String systemPrompt,
    String transcript,
    Map<String, Object> schema,
    DateTime deadline,
  ) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw const GeminiException(
        'Gemini took too long to answer. Check your connection and try again.',
        isRetryable: true,
      );
    }
    final timeout = remaining < _requestTimeout ? remaining : _requestTimeout;

    final uri = Uri.parse('$_endpoint/$model:generateContent');
    final payload = jsonEncode({
      'system_instruction': {
        'parts': [
          {'text': systemPrompt},
        ],
      },
      'contents': [
        {
          'parts': [
            {'text': transcript},
          ],
        },
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': schema,
        'temperature': 0,
      },
    });

    final http.Response response;
    try {
      response = await _httpClient
          .post(
            uri,
            headers: {
              'x-goog-api-key': _apiKey,
              'Content-Type': 'application/json',
            },
            body: payload,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const GeminiException(
        'Gemini took too long to answer. Check your connection and try again.',
        isRetryable: true,
      );
    } on http.ClientException catch (error) {
      throw GeminiException(
        'Could not reach Gemini: ${error.message}',
        isRetryable: true,
      );
    } on Exception catch (error) {
      throw GeminiException(
        'Could not reach Gemini: $error',
        isRetryable: true,
      );
    }

    if (response.statusCode != 200) {
      throw GeminiException(
        _statusMessage(response.statusCode),
        isRetryable: _retryableStatuses.contains(response.statusCode),
      );
    }

    return _readFields(response.body);
  }

  /// Digs the model's JSON object out of the response envelope.
  Map<String, dynamic> _readFields(String body) {
    final Object? envelope;
    try {
      envelope = jsonDecode(body);
    } catch (_) {
      throw const GeminiException(
        'Gemini sent something that was not valid JSON. Try again.',
      );
    }
    if (envelope is! Map) {
      throw const GeminiException(
        'Gemini sent something that was not valid JSON. Try again.',
      );
    }

    final feedback = envelope['promptFeedback'];
    if (feedback is Map && feedback['blockReason'] != null) {
      throw GeminiException(
        'Gemini refused to read that request (${feedback['blockReason']}). '
        'Try wording the reminder differently.',
      );
    }

    final candidates = envelope['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw const GeminiException(
        'Gemini answered with no result at all. Try again.',
      );
    }

    final candidate = candidates.first;
    if (candidate is! Map) {
      throw const GeminiException(
        'Gemini answered in a shape this app does not understand.',
      );
    }

    final finishReason = candidate['finishReason'];
    if (finishReason is String && _blockedReasons.contains(finishReason)) {
      throw GeminiException(
        'Gemini blocked its own answer ($finishReason). '
        'Try wording the reminder differently.',
      );
    }

    final content = candidate['content'];
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List || parts.isEmpty) {
      throw const GeminiException(
        'Gemini answered with an empty result. Try again.',
      );
    }

    final first = parts.first;
    final text = first is Map ? first['text'] : null;
    if (text is! String || text.trim().isEmpty) {
      throw const GeminiException(
        'Gemini answered with an empty result. Try again.',
      );
    }

    final Object? fields;
    try {
      fields = jsonDecode(text);
    } catch (_) {
      throw GeminiException(
        'Gemini did not return a reminder, it returned: ${_snippet(text)}',
      );
    }
    if (fields is! Map<String, dynamic>) {
      throw GeminiException(
        'Gemini did not return a reminder, it returned: ${_snippet(text)}',
      );
    }
    return fields;
  }

  ParsedTask _toParsedTask(Map<String, dynamic> fields, DateTime now) {
    final title = _requireString(fields, 'title');
    final date = _requireString(fields, 'date');
    final time = _requireString(fields, 'time');

    final parsed = _localDateTime(date, time);
    if (parsed == null) {
      throw GeminiException(
        'Gemini gave a date this app could not read ("$date $time"). '
        'Try saying the reminder again.',
      );
    }

    var dueAt = parsed;
    var needsClarification = fields['needsClarification'] == true;

    // The prompt forbids past times, but the model still slips occasionally.
    // Silently accepting one would schedule a notification that never fires.
    if (!dueAt.isAfter(now)) {
      dueAt = _rollForward(dueAt, now);
      needsClarification = true;
    }

    return ParsedTask(
      title: title,
      dueAt: dueAt,
      reminderMinutesBefore: _minutes(fields['reminderMinutesBefore']),
      useAlarm: fields['useAlarm'] == true,
      needsClarification: needsClarification,
    );
  }

  /// Keeps the time of day the user asked for and moves it to the soonest day
  /// it still lies ahead, which is the reading a person expects from "at nine".
  DateTime _rollForward(DateTime dueAt, DateTime now) {
    final today = DateTime(
      now.year,
      now.month,
      now.day,
      dueAt.hour,
      dueAt.minute,
    );
    if (today.isAfter(now)) return today;
    return DateTime(now.year, now.month, now.day + 1, dueAt.hour, dueAt.minute);
  }

  DateTime? _localDateTime(String date, String time) {
    final day = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(date);
    final clock = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(time);
    if (day == null || clock == null) return null;

    final month = int.parse(day.group(2)!);
    final dayOfMonth = int.parse(day.group(3)!);
    final hour = int.parse(clock.group(1)!);
    final minute = int.parse(clock.group(2)!);

    // DateTime happily normalises month 13 into next January and 31 February
    // into early March, which would turn a bad answer into a plausible looking
    // wrong date. Range checks alone miss the day case, since 31 is in range
    // for every month, so the result is compared back against the input.
    if (month < 1 || month > 12) return null;
    if (dayOfMonth < 1 || dayOfMonth > 31) return null;
    if (hour > 23 || minute > 59) return null;

    final result =
        DateTime(int.parse(day.group(1)!), month, dayOfMonth, hour, minute);
    if (result.month != month || result.day != dayOfMonth) return null;
    return result;
  }

  String _requireString(Map<String, dynamic> fields, String key) {
    final value = fields[key];
    if (value is! String || value.trim().isEmpty) {
      throw GeminiException(
        'Gemini left "$key" out of the reminder. Try saying it again.',
      );
    }
    return value.trim();
  }

  /// Forces a workout name into sentence case.
  ///
  /// The prompt asks for it, but a prompt is a request, not a guarantee: the
  /// live model returned both "Bicep And Shoulder" and "LEGS" for the same
  /// instruction. This string is shown verbatim on the workouts screen, so it
  /// is normalised here rather than trusted.
  ///
  /// Lowercasing everything and capitalising the first letter is deliberate
  /// over anything cleverer. An acronym such as "HIIT" is indistinguishable
  /// from shouting without a dictionary, and "Hiit day" is a far smaller
  /// blemish than "LEGS" sitting in the history list.
  static String _sentenceCase(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    final lower = trimmed.toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }

  /// A week, comfortably past any sane lead time. An unbounded value would
  /// push the reminder moment so far back that it is already in the past, and
  /// a reminder in the past is one that never fires.
  static const int _maxLeadMinutes = 7 * 24 * 60;

  int _minutes(Object? raw) {
    final value = raw is num ? raw.toInt() : null;
    if (value == null || value < 0) return Task.defaultReminderMinutes;
    if (value > _maxLeadMinutes) return _maxLeadMinutes;
    return value;
  }

  String _statusMessage(int status) {
    switch (status) {
      case 400:
        return 'Gemini rejected the request (400). This is a bug in the app.';
      case 401:
      case 403:
        return 'Gemini rejected the API key ($status). '
            'Check GEMINI_API_KEY in env.json.';
      case 404:
        return 'Gemini has no model by that name (404). '
            'The configured model may have been retired.';
      case 429:
        return 'Too many requests to Gemini right now. Try again in a moment.';
      default:
        return 'Gemini is having trouble ($status). Try again in a moment.';
    }
  }

  String _snippet(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 120 ? flat : '${flat.substring(0, 120)}...';
  }

  String _systemPrompt(DateTime now) {
    return '''
You convert one spoken sentence into one reminder. Answer with JSON only.

${_anchor(now)}

$_reminderRules''';
  }

  /// The router prompt. Classification comes first and the reminder rules are
  /// the same text [extract] sends, so a sentence that is not about the gym is
  /// read exactly as it was before this method existed.
  String _intentPrompt(DateTime now) {
    return '''
You read one spoken sentence and decide what the user meant. Answer with JSON
only.

${_anchor(now)}

Classify the sentence first and put the result in intent:
- "workout_start" when the user says they have arrived at or are at the gym, or
  that they are starting a workout.
- "workout_end" when the user says they are done, finished, or leaving the gym.
- "note" when the user is recording a fact, a thought or something to remember
  that has NO time attached and asks for NO alarm. For example "the wifi
  password is hunter2", "Marko's new number is 091 555 1234", "remember I
  parked on level three".
- "reminder" for everything else. This is the default.

Being at the gym is NOT a reminder. "I'm at the gym" must never become a task.

The deciding test between "reminder" and "note" is whether the user wants to be
interrupted later. A reminder wants to interrupt. A note does not.

When the sentence is genuinely ambiguous, choose "reminder". A reminder that
should have been a note is a small annoyance, while a note that should have been
a reminder is a missed appointment, so lean that way every time.

noteText belongs to "note" only: the cleaned up sentence to keep. Use the user's
own wording and fix only obvious transcription noise. Leave it empty for every
other intent.

workoutType belongs to "workout_start" only: what the user is training, as a
short phrase in sentence case, meaning only the first letter is capitalised.
Write "Bicep and shoulder", "Leg day", "Back". Never title case such as
"Bicep And Shoulder", and never upper case such as "LEGS".
Leave it empty when they did not say what they are training.

The reminder fields below are read only when intent is "reminder". For the note
and workout intents they are ignored, so fill them with any valid values.

$_reminderRules''';
  }

  String _anchor(DateTime now) {
    final weekday = _weekdays[now.weekday - 1];
    return '''
The user's current local date and time is ${now.toIso8601String()}, a $weekday.
Resolve every relative expression ("tomorrow", "tonight", "next Tuesday", "in
two hours") against that exact moment. The answer must always be in the future.''';
  }

  /// The daypart table is not decoration: without it the model answered
  /// "Friday evening" with 09:00, so every vague word gets an exact hour.
  static const String _reminderRules = '''
Fields:
- title: a short imperative phrase with no date or time words in it. Write
  "Call the dentist", not "Call the dentist on Friday morning".
- date: YYYY-MM-DD.
- time: HH:MM in 24 hour form.
- reminderMinutesBefore: how many minutes before the event to warn. Default
  ${Task.defaultReminderMinutes} unless the user asks for something else.
- useAlarm: true only when the user implies an alarm or being woken up, for
  example "wake me", "set an alarm", "make sure I am up". Otherwise false.
- needsClarification: true when you had to guess the time rather than hear it.

Map vague parts of the day to exactly these times, with no exceptions:
  morning 09:00, noon 12:00, afternoon 15:00, evening 18:00, night 21:00,
  "end of day" 17:00.
So "Friday evening" is Friday at 18:00, never 09:00.

If no time can be inferred at all, use 09:00 and set needsClarification true.''';
}
