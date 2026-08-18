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
  }) =>
      {
        'id': id,
        'event_date': '2025-08-16',
        'recorded_at': DateTime.now().toUtc().subtract(const Duration(days: 2)).toIso8601String(),
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
  }) async {
    final client = MockClient((req) async {
      if (req.url.path == '/recordings') return http.Response(jsonEncode(recs), 200);
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
