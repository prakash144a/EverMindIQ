import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/home/home_screen.dart';
import 'package:voiceiq/src/features/memory/memory_detail_screen.dart';

/// The lists only have room for a title, so this screen is the only place a
/// memory can actually be read back — for typed memories it is the *only* way
/// to see the text again at all.
void main() {
  Map<String, dynamic> rec({
    String id = 'a',
    String status = 'indexed',
    String source = 'voice',
    String title = 'Fishing trip with Dad',
    String transcript = 'I drove up to the lake before dawn and we fished all morning.',
    String summary = 'I went fishing with my father at the lake.',
    double durationSec = 92,
    List<String> people = const ['Dad'],
    List<String> places = const ['The lake'],
    List<String> tags = const ['fishing'],
    String mood = 'content',
    int daysAgo = 2,
  }) =>
      {
        'id': id,
        'event_date': '2025-08-16',
        'recorded_at': DateTime.now().toUtc().subtract(Duration(days: daysAgo)).toIso8601String(),
        'status': status,
        'source': source,
        'title': title,
        'transcript': transcript,
        'summary': summary,
        'duration_sec': durationSec,
        'people': people,
        'places': places,
        'tags': tags,
        'mood': mood,
      };

  Future<void> pumpDetail(
    WidgetTester tester,
    List<Map<String, dynamic>> recs, {
    String openId = 'a',
    Future<http.Response> Function(http.Request req)? onPatch,
    Future<http.Response> Function(http.Request req)? onNewTitle,
  }) async {
    final client = MockClient((req) async {
      if (req.url.path == '/recordings') return http.Response(jsonEncode(recs), 200);
      if (req.method == 'PATCH' && onPatch != null) return onPatch(req);
      if (req.method == 'POST' && onNewTitle != null) return onNewTitle(req);
      return http.Response(jsonEncode({}), 200);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider
              .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MemoryDetailScreen(recordingId: openId),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a voice memory shows its AI transcript, labelled as such', (tester) async {
    await pumpDetail(tester, [rec()]);

    expect(find.text('Fishing trip with Dad'), findsOneWidget);
    expect(find.text('Transcript'), findsOneWidget);
    expect(
      find.text('I drove up to the lake before dawn and we fished all morning.'),
      findsOneWidget,
      reason: 'the whole transcript must be readable, not a two-line preview',
    );
    // The transcript is a machine's best guess, and saying so is the honest thing.
    expect(find.textContaining('Transcribed by AI'), findsOneWidget);
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('I went fishing with my father at the lake.'), findsOneWidget);
    // Audio exists, so playback is offered.
    expect(find.text('Play the original recording'), findsOneWidget);
  });

  testWidgets('a typed memory shows the full text and offers no playback', (tester) async {
    final long = 'We drove up the coast. ' * 30;
    await pumpDetail(tester, [
      rec(source: 'text', title: 'A quiet Sunday', transcript: long, durationSec: 0),
    ]);

    expect(find.text('A quiet Sunday'), findsOneWidget);
    expect(find.text('What you wrote'), findsOneWidget);
    expect(find.text(long), findsOneWidget);
    // Nothing was transcribed, so nothing should claim to have been.
    expect(find.text('Transcript'), findsNothing);
    expect(find.textContaining('Transcribed by AI'), findsNothing);
    expect(find.text('Play the original recording'), findsNothing);
  });

  testWidgets('entities are listed', (tester) async {
    await pumpDetail(tester, [rec()]);

    expect(find.text('In this memory'), findsOneWidget);
    expect(find.text('Dad'), findsOneWidget);
    expect(find.text('The lake'), findsOneWidget);
    expect(find.text('fishing'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('a memory still processing says so instead of showing an empty page',
      (tester) async {
    await pumpDetail(tester, [
      rec(status: 'uploaded', title: '', transcript: '', summary: ''),
    ]);

    expect(find.text('Untitled recording'), findsOneWidget);
    expect(find.text('AI is transcribing…'), findsOneWidget);
    expect(find.text('Not ready yet.'), findsOneWidget);
    expect(find.text('Summary'), findsNothing);
  });

  testWidgets('a typed memory in flight is not described as transcribing', (tester) async {
    await pumpDetail(tester, [
      rec(status: 'uploaded', source: 'text', title: '', summary: '', durationSec: 0),
    ]);

    expect(find.text('Untitled written memory'), findsOneWidget);
    expect(find.text('Saving your memory…'), findsOneWidget);
    expect(find.text('AI is transcribing…'), findsNothing);
  });

  testWidgets('a deleted memory reports itself instead of rendering blank', (tester) async {
    await pumpDetail(tester, [rec(id: 'other')], openId: 'gone');

    expect(find.text('Memory not found'), findsOneWidget);
  });

  testWidgets('the title can be renamed, and the summary is left alone', (tester) async {
    Map<String, dynamic>? sent;
    await pumpDetail(
      tester,
      [rec()],
      onPatch: (req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(rec(title: sent!['title'] as String)), 200);
      },
    );

    await tester.tap(find.byTooltip('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Dawn at the lake  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // A rename sends the title and nothing else — no words, so no AI run.
    expect(sent, {'title': 'Dawn at the lake'});
    expect(find.text('Dawn at the lake'), findsOneWidget);
    expect(find.text('Fishing trip with Dad'), findsNothing);
    expect(find.text('I went fishing with my father at the lake.'), findsOneWidget);
  });

  testWidgets('editing the words sends them and shows the rewritten summary', (tester) async {
    Map<String, dynamic>? sent;
    await pumpDetail(
      tester,
      [rec(source: 'text', durationSec: 0)],
      onPatch: (req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(rec(
            source: 'text',
            durationSec: 0,
            transcript: sent!['transcript'] as String,
            summary: 'I stayed home and baked bread.',
          )),
          200,
        );
      },
    );

    // The words are the only thing on the page with an Edit: the summary has
    // none, because it is not the user's to write.
    expect(find.text('Edit'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit memory'), findsOneWidget);
    expect(find.textContaining('The title stays as it is'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'I stayed home and baked bread all day.');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(sent, {'transcript': 'I stayed home and baked bread all day.'});
    expect(find.text('Edit memory'), findsNothing, reason: 'the editor closes on success');
    expect(find.text('I stayed home and baked bread all day.'), findsOneWidget);
    expect(find.text('I stayed home and baked bread.'), findsOneWidget);
    // The title was not part of the edit and has not moved.
    expect(find.text('Fishing trip with Dad'), findsOneWidget);
  });

  testWidgets('a corrected transcript stops claiming to be purely the AI\'s', (tester) async {
    await pumpDetail(tester, [
      {...rec(), 'transcript_edited': true},
    ]);

    expect(find.textContaining('then edited by you'), findsOneWidget);
    expect(find.textContaining('may not be word-perfect'), findsNothing);
  });

  testWidgets('a memory still processing offers no rename and no edit', (tester) async {
    await pumpDetail(tester, [
      rec(status: 'transcribing', title: '', transcript: '', summary: ''),
    ]);

    expect(find.byTooltip('Rename'), findsNothing);
    expect(find.text('Edit'), findsNothing);
  });

  testWidgets('an edit the server refuses is explained and nothing changes', (tester) async {
    await pumpDetail(
      tester,
      [rec()],
      onPatch: (req) async => http.Response(
        jsonEncode({
          'detail': {'error': 'memory_processing', 'status': 'transcribing'},
        }),
        409,
      ),
    );

    await tester.tap(find.byTooltip('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Dawn at the lake');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('still being processed'), findsOneWidget);
    expect(find.text('Fishing trip with Dad'), findsOneWidget);
  });

  testWidgets('the AI can be asked for a new title', (tester) async {
    String? path;
    await pumpDetail(
      tester,
      [rec(title: 'asdf')],
      onNewTitle: (req) async {
        path = req.url.path;
        return http.Response(jsonEncode(rec(title: 'Dawn fishing with Dad')), 200);
      },
    );

    await tester.tap(find.byTooltip('Generate a new title'));
    await tester.pumpAndSettle();

    expect(path, '/recordings/a/title');
    expect(find.text('Dawn fishing with Dad'), findsOneWidget);
    expect(find.text('asdf'), findsNothing);
    // Only the title was asked for; the summary is the one it already had.
    expect(find.text('I went fishing with my father at the lake.'), findsOneWidget);
  });

  testWidgets('after seven days the title and the words can no longer be changed',
      (tester) async {
    var calls = 0;
    Future<http.Response> counted(http.Request req) async {
      calls++;
      return http.Response(jsonEncode(rec(daysAgo: 8)), 200);
    }

    await pumpDetail(tester, [rec(daysAgo: 8)], onPatch: counted, onNewTitle: counted);

    // Still on the page, so the reason beside them makes sense — but inert.
    expect(find.textContaining('Editing closed 7 days after'), findsOneWidget);
    await tester.tap(find.byTooltip('Rename'), warnIfMissed: false);
    await tester.tap(find.byTooltip('Generate a new title'), warnIfMissed: false);
    await tester.tap(find.text('Edit'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Rename memory'), findsNothing);
    expect(find.text('Edit transcript'), findsNothing);
    expect(calls, 0);
    // The memory itself is all still readable.
    expect(find.text('Fishing trip with Dad'), findsOneWidget);
    expect(find.text('I went fishing with my father at the lake.'), findsOneWidget);
  });

  testWidgets('on the seventh day a memory is still editable', (tester) async {
    await pumpDetail(tester, [rec(daysAgo: 6)]);

    expect(find.textContaining('Editing closed'), findsNothing);
    await tester.tap(find.byTooltip('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename memory'), findsOneWidget);
  });

  testWidgets('the edit window is the one the server publishes', (tester) async {
    final client = MockClient((req) async {
      if (req.url.path == '/recordings') return http.Response(jsonEncode([rec()]), 200);
      if (req.url.path == '/profile') {
        return http.Response(jsonEncode({'edit_window_days': 1}), 200);
      }
      return http.Response(jsonEncode({}), 200);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider
              .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const MemoryDetailScreen(recordingId: 'a'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Two days old: inside the default window, outside this one.
    expect(find.textContaining('Editing closed 1 day after'), findsOneWidget);
  });

  testWidgets('tapping a row in the recent list opens it', (tester) async {
    final recs = [rec(title: 'Fishing trip with Dad')];
    final client = MockClient((req) async {
      if (req.url.path == '/recordings') return http.Response(jsonEncode(recs), 200);
      if (req.url.path == '/memories/on-this-day') {
        return http.Response(jsonEncode({'items': []}), 200);
      }
      return http.Response(jsonEncode({}), 200);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider
              .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: HomeScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(MemoryDetailScreen), findsNothing);
    await tester.tap(find.text('Fishing trip with Dad'));
    await tester.pumpAndSettle();

    expect(find.byType(MemoryDetailScreen), findsOneWidget);
    expect(find.text('Transcript'), findsOneWidget);
  });
}
