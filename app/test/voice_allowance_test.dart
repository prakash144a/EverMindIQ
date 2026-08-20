import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/models.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/record/record_screen.dart';

/// The monthly voice allowance, as the capture screen presents it.
///
/// The point of showing it at all is that the refusal has to arrive *before* the
/// microphone opens: the server's 429 comes back after the audio is uploaded, by
/// which time the user has already spoken for nothing. So these tests care about
/// two things — that the number is always on screen, and that the mic is
/// genuinely inert once it reaches zero.
void main() {
  Future<void> pumpRecord(
    WidgetTester tester, {
    int perMonth = 10,
    int used = 0,
    int recordingMaxSec = 60,
  }) async {
    final client = MockClient((req) async {
      if (req.url.path == '/profile') {
        return http.Response(
          jsonEncode({
            'tier': 'free',
            'text_max_chars': 1000,
            'recordings_per_month': perMonth,
            'recordings_used_this_month': used,
            'recordings_month_resets_on': '2026-09-01',
            'recording_max_sec': recordingMaxSec,
            'voice_session_max_sec': 600,
          }),
          200,
        );
      }
      return http.Response(jsonEncode({}), 200);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider
              .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const RecordScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Speaking is one tap away from the default Write mode.
    await tester.tap(find.text('Speak'));
    await tester.pump();
  }

  testWidgets('the allowance is on screen before anything is recorded', (tester) async {
    await pumpRecord(tester, used: 3);

    expect(find.text('7 of 10 voice memories left this month'), findsOneWidget);
  });

  testWidgets('the length limit is stated rather than sprung', (tester) async {
    await pumpRecord(tester);

    expect(find.textContaining('up to 1:00'), findsOneWidget);
  });

  testWidgets('premium lengths are read from the profile', (tester) async {
    await pumpRecord(tester, recordingMaxSec: 600);

    expect(find.textContaining('up to 10:00'), findsOneWidget);
  });

  testWidgets('an exhausted allowance makes the mic inert', (tester) async {
    await pumpRecord(tester, perMonth: 10, used: 10);

    expect(find.text('No voice memories left this month'), findsOneWidget);
    expect(find.text('Out of voice memories this month'), findsOneWidget);
    // The hint must stop promising a tap that does nothing.
    expect(find.text('Tap the mic to start recording'), findsNothing);
    expect(find.text('Switch to Write, or wait for next month'), findsOneWidget);
    // And it says when it comes back, plus the way through in the meantime.
    expect(find.textContaining('resets on'), findsOneWidget);
    expect(find.textContaining('Writing one is always free'), findsOneWidget);
  });

  testWidgets('a lapsed premium account is over the ceiling, not below zero', (tester) async {
    await pumpRecord(tester, perMonth: 10, used: 40);

    expect(find.text('No voice memories left this month'), findsOneWidget);
  });

  testWidgets('writing is still offered when voice is spent', (tester) async {
    await pumpRecord(tester, perMonth: 10, used: 10);

    await tester.tap(find.text('Write'));
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  group('UserProfile', () {
    test('counts what is left, never below zero', () {
      const under = UserProfile(recordingsPerMonth: 10, recordingsUsedThisMonth: 4);
      expect(under.recordingsLeftThisMonth, 6);
      expect(under.canRecord, isTrue);

      // A premium account that lapsed can hold more than the free ceiling.
      const over = UserProfile(recordingsPerMonth: 10, recordingsUsedThisMonth: 40);
      expect(over.recordingsLeftThisMonth, 0);
      expect(over.canRecord, isFalse);
    });

    test('falls back to the free tier when the server sends nothing', () {
      final blank = UserProfile.fromJson(const {});
      expect(blank.recordingsPerMonth, 10);
      expect(blank.recordingMaxSec, 60);
      expect(blank.voiceSessionMaxSec, 600);
      expect(blank.recordingsUsedThisMonth, 0);
      expect(blank.recordingsMonthResetsOn, isNull);
    });
  });
}
