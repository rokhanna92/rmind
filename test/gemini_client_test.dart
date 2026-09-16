import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rmind/models/task.dart';
import 'package:rmind/models/workout_session.dart';
import 'package:rmind/services/gemini_client.dart';

/// Wraps [fields] the way the real endpoint does: the model's JSON arrives as a
/// string inside candidates[0].content.parts[0].text.
http.Response modelReply(Map<String, Object?> fields) {
  return http.Response(
    jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': jsonEncode(fields)},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Map<String, Object?> requestBody(http.Request request) =>
    jsonDecode(request.body) as Map<String, Object?>;

String systemPromptOf(http.Request request) {
  final instruction = requestBody(request)['system_instruction'] as Map;
  final parts = instruction['parts'] as List;
  return (parts.first as Map)['text'] as String;
}

void main() {
  group('extract', () {
    test('parses all six fields from a well formed answer', () async {
      late http.Request seen;
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          seen = request;
          return modelReply({
            'title': 'Call the dentist',
            'date': '2026-09-18',
            'time': '18:00',
            'reminderMinutesBefore': 45,
            'useAlarm': true,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.extract(
        'remind me to call the dentist friday evening',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result.title, 'Call the dentist');
      expect(result.dueAt, DateTime(2026, 9, 18, 18, 0));
      expect(result.reminderMinutesBefore, 45);
      expect(result.useAlarm, isTrue);
      expect(result.needsClarification, isFalse);

      expect(seen.method, 'POST');
      expect(
        seen.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '${GeminiClient.primaryModel}:generateContent',
      );
      expect(seen.headers['x-goog-api-key'], 'test-key');

      final body = requestBody(seen);
      final config = body['generationConfig'] as Map;
      expect(config['responseMimeType'], 'application/json');
      expect(config['temperature'], 0);
      expect((config['responseSchema'] as Map)['type'], 'OBJECT');

      final contents = body['contents'] as List;
      expect(((contents.first as Map)['parts'] as List).first, {
        'text': 'remind me to call the dentist friday evening',
      });
    });

    test('anchors relative dates on the supplied now', () async {
      late String prompt;
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          prompt = systemPromptOf(request);
          // "tomorrow" relative to the fixed now below.
          return modelReply({
            'title': 'Take out the bins',
            'date': '2026-09-17',
            'time': '21:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.extract(
        'bins tomorrow night',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result.dueAt, DateTime(2026, 9, 17, 21, 0));
      expect(prompt, contains('2026-09-16T10:30:00.000'));
      expect(prompt, contains('Wednesday'));
      expect(prompt, contains('evening 18:00'));
      expect(prompt, contains('09:00'));
    });

    test(
      'retries the primary on 503 then falls back to the second model',
      () async {
        final urls = <String>[];
        final client = GeminiClient(
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            urls.add(request.url.toString());
            if (urls.length < 3) {
              return http.Response('{"error":{"message":"overloaded"}}', 503);
            }
            return modelReply({
              'title': 'Pay rent',
              'date': '2026-10-01',
              'time': '09:00',
              'reminderMinutesBefore': 30,
              'useAlarm': false,
              'needsClarification': false,
            });
          }),
        );

        final result = await client.extract(
          'pay rent on the first',
          now: DateTime(2026, 9, 16, 10, 30),
        );

        expect(result.title, 'Pay rent');
        expect(urls, hasLength(3));
        expect(
          urls[0],
          contains('${GeminiClient.primaryModel}:generateContent'),
        );
        expect(
          urls[1],
          contains('${GeminiClient.primaryModel}:generateContent'),
        );
        expect(
          urls[2],
          contains('${GeminiClient.fallbackModel}:generateContent'),
        );
      },
    );

    test(
      'surfaces a retryable GeminiException when every attempt times out',
      () async {
        var calls = 0;
        final client = GeminiClient(
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            calls++;
            throw TimeoutException('no response');
          }),
        );

        await expectLater(
          client.extract('buy milk', now: DateTime(2026, 9, 16, 10, 30)),
          throwsA(
            isA<GeminiException>()
                .having((e) => e.isRetryable, 'isRetryable', isTrue)
                .having((e) => e.message, 'message', contains('too long')),
          ),
        );
        expect(calls, 3);
      },
    );

    test('reports malformed model JSON readably', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Sure! Here is your reminder.'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      await expectLater(
        client.extract('buy milk', now: DateTime(2026, 9, 16, 10, 30)),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.isRetryable, 'isRetryable', isFalse)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('did not return a reminder'),
                  contains('Sure! Here is your reminder.'),
                ),
              ),
        ),
      );
    });

    test('rejects an empty transcript before touching the network', () async {
      var calls = 0;
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          calls++;
          return modelReply(const {});
        }),
      );

      await expectLater(
        client.extract('   \n\t '),
        throwsA(isA<GeminiException>()),
      );
      expect(calls, 0);
    });

    test(
      'rolls a past answer forward and flags it for clarification',
      () async {
        final client = GeminiClient(
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            // Yesterday, despite the prompt demanding a future moment.
            return modelReply({
              'title': 'Water the plants',
              'date': '2026-09-15',
              'time': '08:00',
              'reminderMinutesBefore': 30,
              'useAlarm': false,
              'needsClarification': false,
            });
          }),
        );

        final result = await client.extract(
          'water the plants',
          now: DateTime(2026, 9, 16, 10, 30),
        );

        // 08:00 has already gone today, so the next occurrence is tomorrow.
        expect(result.dueAt, DateTime(2026, 9, 17, 8, 0));
        expect(result.dueAt.isAfter(DateTime(2026, 9, 16, 10, 30)), isTrue);
        expect(result.needsClarification, isTrue);
      },
    );

    test('keeps a past answer on today when the hour is still ahead', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'title': 'Stretch',
            'date': '2020-01-01',
            'time': '17:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.extract(
        'stretch at the end of the day',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result.dueAt, DateTime(2026, 9, 16, 17, 0));
      expect(result.needsClarification, isTrue);
    });

    test('does not retry a rejected API key', () async {
      var calls = 0;
      final client = GeminiClient(
        apiKey: 'bad-key',
        httpClient: MockClient((request) async {
          calls++;
          return http.Response('{"error":{"message":"invalid key"}}', 403);
        }),
      );

      await expectLater(
        client.extract('buy milk', now: DateTime(2026, 9, 16, 10, 30)),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.isRetryable, 'isRetryable', isFalse)
              .having((e) => e.message, 'message', contains('GEMINI_API_KEY')),
        ),
      );
      expect(calls, 1);
    });

    test('reports a safety block distinctly from a parse failure', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'candidates': [
                {'finishReason': 'SAFETY'},
              ],
            }),
            200,
          );
        }),
      );

      await expectLater(
        client.extract('buy milk', now: DateTime(2026, 9, 16, 10, 30)),
        throwsA(
          isA<GeminiException>().having(
            (e) => e.message,
            'message',
            contains('SAFETY'),
          ),
        ),
      );
    });
  });

  group('interpret', () {
    // The live model returned both of these shapes for the same prompt
    // instruction, and the value goes straight onto the workouts screen.
    for (final (given, expected) in [
      ('LEGS', 'Legs'),
      ('Bicep And Shoulder', 'Bicep and shoulder'),
      ('CHEST AND TRICEPS', 'Chest and triceps'),
      ('Leg day', 'Leg day'),
      ('  back  ', 'Back'),
    ]) {
      test('normalises a workout type of "$given" to "$expected"', () async {
        final client = GeminiClient(
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            return modelReply({
              'intent': 'workout_start',
              'workoutType': given,
              'title': 'Gym',
              'date': '2026-09-16',
              'time': '18:00',
              'reminderMinutesBefore': 30,
              'useAlarm': false,
              'needsClarification': false,
            });
          }),
        );

        final result = await client.interpret(
          'at the gym',
          now: DateTime(2026, 9, 16, 10, 30),
        );

        expect((result as WorkoutStartIntent).type, expected);
      });
    }

    test('reads an arrival with what is being trained', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'workout_start',
            'workoutType': 'Bicep and shoulder',
            // Filled because the schema requires them, ignored by the router.
            'title': 'Gym',
            'date': '2026-09-16',
            'time': '18:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.interpret(
        'I just arrived at the gym, today is bicep and shoulder day',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<WorkoutStartIntent>());
      expect((result as WorkoutStartIntent).type, 'Bicep and shoulder');
    });

    test('names an untyped arrival after the model default', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'workout_start',
            'workoutType': '   ',
            'title': 'Gym',
            'date': '2026-09-16',
            'time': '18:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.interpret(
        "I'm at the gym",
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<WorkoutStartIntent>());
      expect((result as WorkoutStartIntent).type, WorkoutSession.unnamed);
    });

    test('falls back when workoutType is missing entirely', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'workout_start',
            'title': 'Gym',
            'date': '2026-09-16',
            'time': '18:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.interpret(
        'starting my workout',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect((result as WorkoutStartIntent).type, WorkoutSession.unnamed);
    });

    test('reads a departure and ignores every reminder field', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'workout_end',
            'workoutType': 'Bicep and shoulder',
            // Nonsense on purpose: none of it may reach the caller.
            'title': 'Workout',
            'date': '1999-01-01',
            'time': '99:99',
            'reminderMinutesBefore': -5,
            'useAlarm': true,
            'needsClarification': true,
          });
        }),
      );

      final result = await client.interpret(
        'Ok done with the workout',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<WorkoutEndIntent>());
    });

    test('builds the same reminder extract would', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'reminder',
            'workoutType': '',
            'title': 'Call the dentist',
            'date': '2026-09-17',
            'time': '15:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.interpret(
        'call the dentist tomorrow at 3pm',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<ReminderIntent>());
      final task = (result as ReminderIntent).task;
      expect(task.title, 'Call the dentist');
      expect(task.dueAt, DateTime(2026, 9, 17, 15, 0));
      expect(task.reminderMinutesBefore, 30);
      expect(task.useAlarm, isFalse);
      expect(task.needsClarification, isFalse);
    });

    test('keeps a fact as a note instead of inventing a time for it', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'note',
            'noteText': 'The wifi password is hunter2',
            // Filled because the schema requires them, ignored by the router.
            'title': 'Wifi password',
            'date': '2026-09-17',
            'time': '09:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': true,
          });
        }),
      );

      final result = await client.interpret(
        'the wifi password is hunter2',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<NoteIntent>());
      expect((result as NoteIntent).text, 'The wifi password is hunter2');
    });

    test('keeps a phone number as a note', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'note',
            'noteText': "Marko's new number is 091 555 1234  ",
            'title': 'Marko number',
            'date': '2026-09-17',
            'time': '09:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': true,
          });
        }),
      );

      final result = await client.interpret(
        "Marko's new number is 091 555 1234",
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<NoteIntent>());
      expect((result as NoteIntent).text, "Marko's new number is 091 555 1234");
    });

    test('falls back to the transcript when noteText comes back empty',
        () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'note',
            'noteText': '   ',
            'title': 'Parking',
            'date': '2026-09-17',
            'time': '09:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': true,
          });
        }),
      );

      final result = await client.interpret(
        '  remember I parked on level three  ',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      // Better an unpolished sentence than a note with nothing in it.
      expect((result as NoteIntent).text, 'remember I parked on level three');
    });

    test('still reads a timed errand as a reminder, not a note', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'reminder',
            // A stray note field must not hijack the reminder path.
            'noteText': 'Call the dentist tomorrow at 3pm',
            'workoutType': '',
            'title': 'Call the dentist',
            'date': '2026-09-17',
            'time': '15:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.interpret(
        'call the dentist tomorrow at 3pm',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<ReminderIntent>());
      final task = (result as ReminderIntent).task;
      expect(task.title, 'Call the dentist');
      expect(task.dueAt, DateTime(2026, 9, 17, 15, 0));
    });

    test('still reads an arrival as a workout, not a note', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'workout_start',
            'workoutType': 'Leg day',
            'noteText': "I'm at the gym",
            'title': 'Gym',
            'date': '2026-09-16',
            'time': '18:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.interpret(
        "I'm at the gym",
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result, isA<WorkoutStartIntent>());
      expect((result as WorkoutStartIntent).type, 'Leg day');
    });

    test('constrains intent to the four known values in the schema', () async {
      late http.Request seen;
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          seen = request;
          return modelReply({
            'intent': 'workout_end',
            'title': 'Gym',
            'date': '2026-09-16',
            'time': '18:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      await client.interpret(
        'leaving the gym',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      final config = requestBody(seen)['generationConfig'] as Map;
      final schema = config['responseSchema'] as Map;
      final properties = schema['properties'] as Map;

      expect(schema['required'], contains('intent'));
      expect((properties['intent'] as Map)['type'], 'STRING');
      expect((properties['intent'] as Map)['enum'], [
        'reminder',
        'note',
        'workout_start',
        'workout_end',
      ]);
      expect((properties['workoutType'] as Map)['type'], 'STRING');
      expect((properties['noteText'] as Map)['type'], 'STRING');
      // noteText is optional: the reminder contract must not get looser.
      expect(schema['required'], isNot(contains('noteText')));
      // The reminder contract rides along untouched.
      expect(properties.keys, containsAll(['title', 'date', 'time']));

      final prompt = systemPromptOf(seen);
      expect(prompt, contains('must never become a task'));
      expect(prompt, contains('evening 18:00'));
      // The tie breaker, without which notes eat borderline appointments.
      expect(
        prompt,
        contains('A reminder wants to interrupt. A note does not.'),
      );
      expect(prompt, contains('choose "reminder"'));
    });

    test('reports an intent it does not know readably', () async {
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'grocery_list',
            'title': 'Buy milk',
            'date': '2026-09-17',
            'time': '09:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      await expectLater(
        client.interpret('buy milk', now: DateTime(2026, 9, 16, 10, 30)),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.isRetryable, 'isRetryable', isFalse)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('does not understand'),
                  contains('grocery_list'),
                ),
              ),
        ),
      );
    });

    test('retries the primary on 503 then falls back, as extract does',
        () async {
      final urls = <String>[];
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          urls.add(request.url.toString());
          if (urls.length < 3) {
            return http.Response('{"error":{"message":"overloaded"}}', 503);
          }
          return modelReply({
            'intent': 'workout_start',
            'workoutType': 'Leg day',
            'title': 'Gym',
            'date': '2026-09-16',
            'time': '18:00',
            'reminderMinutesBefore': 30,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.interpret(
        'at the gym for leg day',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect((result as WorkoutStartIntent).type, 'Leg day');
      expect(urls, hasLength(3));
      expect(urls[0], contains('${GeminiClient.primaryModel}:generateContent'));
      expect(urls[1], contains('${GeminiClient.primaryModel}:generateContent'));
      expect(
        urls[2],
        contains('${GeminiClient.fallbackModel}:generateContent'),
      );
    });

    test('rejects an empty transcript before touching the network', () async {
      var calls = 0;
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          calls++;
          return modelReply(const {});
        }),
      );

      await expectLater(
        client.interpret('   \n\t '),
        throwsA(isA<GeminiException>()),
      );
      expect(calls, 0);
    });
  });

  group('recurrence', () {
    /// Answers [recurrence] alongside a plain future reminder.
    GeminiClient clientAnswering(Object? recurrence) {
      return GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'reminder',
            'title': 'Standup',
            'date': '2026-09-21',
            'time': '09:00',
            'reminderMinutesBefore': 10,
            'useAlarm': false,
            'needsClarification': false,
            'recurrence': ?recurrence,
          });
        }),
      );
    }

    for (final (phrase, answer, expected) in [
      ('remind me to stretch every day at nine', 'daily', Recurrence.daily),
      ('standup every Monday at nine', 'weekly', Recurrence.weekly),
      ('pay the rent on the first of every month', 'monthly',
          Recurrence.monthly),
      ('call the dentist on Monday at nine', 'none', Recurrence.none),
    ]) {
      test('reads "$answer" from "$phrase"', () async {
        final result = await clientAnswering(answer).interpret(
          phrase,
          now: DateTime(2026, 9, 16, 10, 30),
        );

        expect((result as ReminderIntent).task.recurrence, expected);
      });
    }

    test('falls back to none for a value outside the enum', () async {
      final result = await clientAnswering('fortnightly').interpret(
        'remind me every other Monday',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      // A surprise repeating alarm costs the user far more than a missed
      // repeat, so anything unrecognised has to land on none.
      expect((result as ReminderIntent).task.recurrence, Recurrence.none);
    });

    test('falls back to none when the field is missing entirely', () async {
      final result = await clientAnswering(null).interpret(
        'call the dentist on Monday',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect((result as ReminderIntent).task.recurrence, Recurrence.none);
    });

    test('falls back to none when the field is not a string', () async {
      final result = await clientAnswering(7).interpret(
        'call the dentist on Monday',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect((result as ReminderIntent).task.recurrence, Recurrence.none);
    });

    test('constrains recurrence to the four values in the schema', () async {
      late http.Request seen;
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          seen = request;
          return modelReply({
            'intent': 'reminder',
            'title': 'Standup',
            'date': '2026-09-21',
            'time': '09:00',
            'reminderMinutesBefore': 10,
            'useAlarm': false,
            'needsClarification': false,
            'recurrence': 'weekly',
          });
        }),
      );

      await client.interpret(
        'standup every Monday at nine',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      final config = requestBody(seen)['generationConfig'] as Map;
      final schema = config['responseSchema'] as Map;
      final properties = schema['properties'] as Map;
      final recurrence = properties['recurrence'] as Map;

      expect(recurrence['type'], 'STRING');
      expect(recurrence['enum'], ['none', 'daily', 'weekly', 'monthly']);
      expect(schema['required'], contains('recurrence'));

      final prompt = systemPromptOf(seen);
      expect(prompt, contains('every Monday'));
      expect(prompt, contains('bias\ntowards "none"'));
    });

    test('extract reports none and never asks for the field', () async {
      late http.Request seen;
      final client = GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          seen = request;
          return modelReply({
            'title': 'Standup',
            'date': '2026-09-21',
            'time': '09:00',
            'reminderMinutesBefore': 10,
            'useAlarm': false,
            'needsClarification': false,
          });
        }),
      );

      final result = await client.extract(
        'standup every Monday at nine',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect(result.recurrence, Recurrence.none);

      final config = requestBody(seen)['generationConfig'] as Map;
      final schema = config['responseSchema'] as Map;
      expect((schema['properties'] as Map).containsKey('recurrence'), isFalse);
    });

    /// Answers a first occurrence that has already been and gone.
    GeminiClient clientAnsweringPast(String date, String recurrence) {
      return GeminiClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          return modelReply({
            'intent': 'reminder',
            'title': 'Standup',
            'date': date,
            'time': '09:00',
            'reminderMinutesBefore': 10,
            'useAlarm': false,
            'needsClarification': false,
            'recurrence': recurrence,
          });
        }),
      );
    }

    test('rolling a past weekly first date forward keeps the weekday', () async {
      // 2026-09-14 is a Monday, 2026-09-16 a Wednesday. Rolling by a day would
      // turn "every Monday" into a reminder that repeats on Thursdays.
      final result = await clientAnsweringPast('2026-09-14', 'weekly').interpret(
        'standup every Monday at nine',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      final task = (result as ReminderIntent).task;
      expect(task.dueAt, DateTime(2026, 9, 21, 9));
      expect(task.dueAt.weekday, DateTime.monday);
      expect(task.needsClarification, isTrue);
    });

    test('rolling a past monthly first date forward keeps the day', () async {
      final result = await clientAnsweringPast('2026-08-15', 'monthly')
          .interpret(
        'pay the rent on the 15th of every month',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      final task = (result as ReminderIntent).task;
      expect(task.dueAt, DateTime(2026, 10, 15, 9));
    });

    test('a past one off still rolls to the next day at the same time', () async {
      final result = await clientAnsweringPast('2026-09-14', 'none').interpret(
        'call the dentist at nine',
        now: DateTime(2026, 9, 16, 10, 30),
      );

      expect((result as ReminderIntent).task.dueAt, DateTime(2026, 9, 17, 9));
    });
  });
}
