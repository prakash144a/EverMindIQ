import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/record/record_screen.dart';

/// Writing a memory instead of speaking it: the screen must reach the text
/// endpoint directly, never the upload path, and must respect the tier's cap.
void main() {
  late List<http.BaseRequest> sent;

  setUp(() => sent = []);

  Future<void> pumpRecord(
    WidgetTester tester, {
    int textMaxChars = 1000,
    String tier = 'free',
    bool saveFails = false,
  }) async {
    final client = MockClient((req) async {
      sent.add(req);
      if (req.url.path == '/profile') {
        return http.Response(
          jsonEncode({'tier': tier, 'text_max_chars': textMaxChars}),
          200,
        );
      }
      if (req.url.path == '/recordings/text') {
        if (saveFails) {
          return http.Response(
            jsonEncode({
              'detail': {'error': 'text_too_long', 'limit': 1000, 'tier': 'free'}
            }),
            413,
          );
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'new',
            'event_date': '2026-08-17',
            'status': 'uploaded',
            'source': 'text',
            'transcript': body['text'],
          }),
          201,
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
  }

  Future<void> switchToWrite(WidgetTester tester) async {
    await tester.tap(find.text('Write'));
    await tester.pump();
    // The cap comes from the profile fetch, which only starts once the compose
    // body first builds; give it a frame to land.
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('opens in Speak mode with the mic off', (tester) async {
    await pumpRecord(tester);

    expect(find.text('Tap the mic to start recording'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    // Opening the screen must not start any capture or hit the server.
    expect(sent.any((r) => r.url.path.startsWith('/recordings')), isFalse);
  });

  testWidgets('writing a memory posts the text and never uploads audio', (tester) async {
    await pumpRecord(tester);
    await switchToWrite(tester);

    await tester.enterText(find.byType(TextField), 'We drove to the coast at sunrise.');
    await tester.pump();
    await tester.tap(find.text('Save memory'));
    await tester.pumpAndSettle();

    final posts = sent.where((r) => r.url.path == '/recordings/text').toList();
    expect(posts, hasLength(1));
    expect(
      jsonDecode((posts.single as http.Request).body),
      {'text': 'We drove to the coast at sunrise.'},
      reason: 'today needs no event_date; the server defaults it',
    );

    expect(sent.any((r) => r.url.path == '/uploads'), isFalse);
    expect(sent.any((r) => r.method == 'PUT'), isFalse,
        reason: 'a typed memory has no bytes to upload');
  });

  testWidgets('the text is trimmed before it is sent', (tester) async {
    await pumpRecord(tester);
    await switchToWrite(tester);

    await tester.enterText(find.byType(TextField), '   A quiet afternoon.   ');
    await tester.pump();
    await tester.tap(find.text('Save memory'));
    await tester.pumpAndSettle();

    final post = sent.firstWhere((r) => r.url.path == '/recordings/text');
    expect(jsonDecode((post as http.Request).body)['text'], 'A quiet afternoon.');
  });

  testWidgets('an empty memory cannot be saved', (tester) async {
    await pumpRecord(tester);
    await switchToWrite(tester);

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);

    // Whitespace alone is still empty.
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('the free cap stops input at 1,000 characters', (tester) async {
    await pumpRecord(tester);
    await switchToWrite(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLength, 1000);

    await tester.enterText(find.byType(TextField), 'a' * 1500);
    await tester.pump();

    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(controller.text.length, 1000);
    // The counter is the whole story — no upsell copy.
    expect(find.text('1000/1000'), findsOneWidget);
    expect(find.textContaining('Premium'), findsNothing);
  });

  testWidgets('premium raises the cap to 10,000', (tester) async {
    await pumpRecord(tester, tier: 'premium', textMaxChars: 10000);
    await switchToWrite(tester);

    expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 10000);
  });

  testWidgets('a rejected save keeps the text on screen', (tester) async {
    await pumpRecord(tester, saveFails: true);
    await switchToWrite(tester);

    await tester.enterText(find.byType(TextField), 'Something worth keeping.');
    await tester.pump();
    await tester.tap(find.text('Save memory'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save'), findsOneWidget);
    // Losing what someone just wrote would be the worst possible failure here.
    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(controller.text, 'Something worth keeping.');
  });

  testWidgets('switching back to Speak keeps the mic off', (tester) async {
    await pumpRecord(tester);
    await switchToWrite(tester);
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('Speak'));
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Tap the mic to start recording'), findsOneWidget);
  });
}
