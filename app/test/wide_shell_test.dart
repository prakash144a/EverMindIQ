import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/draft_store.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/ai_conversation.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/audio_playback.dart';
import 'package:voiceiq/src/data/models.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/recall/recall_screen.dart';
import 'package:voiceiq/src/features/record/record_screen.dart';
import 'package:voiceiq/src/features/shell/app_shell.dart';
import 'package:voiceiq/src/features/shell/wide_settings.dart';
import 'package:voiceiq/src/widgets/attach_placeholder.dart';

/// The app on a wide screen is a rail and a page beside it; on a phone-sized
/// one it is exactly what it was. Same screens, same data — only the
/// arrangement differs, so what matters here is which arrangement a window
/// gets, that Home's two doors open the pages they name, and that everything
/// that used to be in the menu can still be reached.
void main() {
  late List<http.BaseRequest> sent;

  setUp(() {
    sent = [];
    DraftStore.setForTesting('');
  });

  final memory = {
    'id': 'm1',
    'event_date': '2026-10-01',
    'recorded_at': DateTime.now().toUtc().subtract(const Duration(hours: 2)).toIso8601String(),
    'status': 'indexed',
    'title': 'The story about the bicycle',
    'source': 'text',
    'summary': 'Appa told the story about the bicycle again.',
  };

  Future<void> pumpShell(WidgetTester tester, Size window) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final client = MockClient((req) async {
      sent.add(req);
      switch (req.url.path) {
        case '/recordings':
          return http.Response(jsonEncode([memory]), 200);
        case '/memories/on-this-day':
          return http.Response(jsonEncode({'items': []}), 200);
        case '/profile':
          return http.Response(
            jsonEncode({'preferred_name': 'Prakash', 'has_profile': true, 'text_max_chars': 1000}),
            200,
          );
        case '/chat':
          return http.Response(
            jsonEncode({
              'answer': 'On 1 October.',
              'citations': [
                {'recording_id': 'm1', 'event_date': '2026-10-01', 'snippet': 'the bicycle', 'source': 'text'},
              ],
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
          audioPlaybackProvider.overrideWith(_QuietPlayback.new),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const AppShell()),
      ),
    );
    await settle(tester);
  }

  const desktop = Size(1440, 900);
  const phone = Size(400, 800);

  http.Request posted(String path) =>
      sent.lastWhere((r) => r.url.path == path && r.method == 'POST') as http.Request;

  group('which layout a window gets', () {
    testWidgets('a wide window is a rail and a page', (tester) async {
      await pumpShell(tester, desktop);

      // The rail: the places that are behind the menu on a phone.
      for (final place in ['Home', 'Timeline', 'Journals', 'Milestones', 'Insights', 'Settings']) {
        expect(find.text(place), findsOneWidget, reason: place);
      }
      expect(find.text('More'), findsNothing, reason: 'it is called Settings now');

      // Home: the two things the app is for, then the recent memories.
      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Recall'), findsOneWidget);
      expect(find.text('Recent moments'), findsOneWidget);
      expect(find.text('The story about the bicycle'), findsOneWidget);

      // Recall is somewhere to go, not something pinned to the side.
      expect(find.byType(RecallScreen), findsNothing);
    });

    testWidgets('a phone-sized window is the phone layout, untouched', (tester) async {
      await pumpShell(tester, phone);

      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Recall'), findsOneWidget);
      expect(find.text('Timeline'), findsNothing);
      expect(find.text('Settings'), findsNothing);
      expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    });
  });

  group("home's two doors", () {
    testWidgets('Record opens the record page, beside the rail', (tester) async {
      await pumpShell(tester, desktop);

      await tester.tap(find.text('Record'));
      await settle(tester);

      expect(find.byType(RecordScreen), findsOneWidget);
      expect(find.text('What happened? Write it in any language.'), findsOneWidget);
      expect(find.text('Timeline'), findsOneWidget, reason: 'the rail stays');
    });

    testWidgets('Recall opens the recall page, and a question is answered there',
        (tester) async {
      await pumpShell(tester, desktop);

      await tester.tap(find.text('Recall'));
      await settle(tester);
      expect(find.byType(RecallScreen), findsOneWidget);
      expect(find.text('Timeline'), findsOneWidget, reason: 'the rail stays');

      await tester.enterText(
        find.widgetWithText(TextField, 'Ask anything about your memories…'),
        'When did Appa tell the bicycle story?',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await settle(tester);

      expect(jsonDecode(posted('/chat').body)['question'], 'When did Appa tell the bicycle story?');
      expect(find.text('On 1 October.'), findsOneWidget);
    });

    testWidgets('closing either comes back to Home', (tester) async {
      await pumpShell(tester, desktop);

      await tester.tap(find.text('Recall'));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.close));
      await settle(tester);

      expect(find.byType(RecallScreen), findsNothing);
      expect(find.text('Recent moments'), findsOneWidget);
    });

    testWidgets('the rail leaves a page that is open', (tester) async {
      await pumpShell(tester, desktop);

      await tester.tap(find.text('Record'));
      await settle(tester);
      await tester.tap(find.text('Journals'));
      await settle(tester);

      expect(find.byType(RecordScreen), findsNothing);
    });
  });

  group('settings', () {
    testWidgets('holds everything the menu used to, down its left side', (tester) async {
      await pumpShell(tester, desktop);

      await tester.tap(find.text('Settings'));
      await settle(tester);

      expect(find.byType(WideSettings), findsOneWidget);
      for (final section in [
        'General & language',
        'People, places & tags',
        'Export & backup',
        'How it works',
        'Report a problem',
      ]) {
        // Once in the list; a second time is the open section's own title.
        expect(find.text(section), findsAtLeastNWidgets(1), reason: section);
      }
    });

    testWidgets('choosing a section shows it without leaving the page', (tester) async {
      await pumpShell(tester, desktop);
      await tester.tap(find.text('Settings'));
      await settle(tester);

      await tester.tap(find.text('Export & backup'));
      await settle(tester);

      // In the list and as the section's heading; the list is still there.
      expect(find.text('Export & backup'), findsNWidgets(2));
      expect(find.text('Report a problem'), findsOneWidget);
      expect(find.byType(WideSettings), findsOneWidget);
    });
  });

  group('attachments', () {
    testWidgets('the place for photos, videos and files says it is not built yet',
        (tester) async {
      await pumpShell(tester, desktop);
      await tester.tap(find.text('Record'));
      await settle(tester);

      await tester.tap(find.byType(AttachPlaceholderButton));
      await settle(tester);

      expect(find.text(AttachPlaceholderButton.comingSoon), findsOneWidget);
      for (final kind in ['Photo', 'Video', 'File']) {
        expect(find.text(kind), findsOneWidget, reason: kind);
        final item = tester.widget<PopupMenuItem<void>>(
          find.ancestor(of: find.text(kind), matching: find.byType(PopupMenuItem<void>)),
        );
        expect(item.enabled, isFalse, reason: '$kind must not look like it works');
      }
      // A placeholder: opening it reaches no server.
      expect(sent.any((r) => r.url.path.contains('upload')), isFalse);
    });
  });

  group('the conversation itself', () {
    ChatAnswer answer(String text) => ChatAnswer(answer: text, citations: const []);

    test('an answer follows its question', () async {
      final ai = AiConversation((q, {journalId}) async => answer('Last spring.'));
      await ai.send('  When did we plant the garden?  ');

      expect(ai.messages.map((m) => m.text), ['When did we plant the garden?', 'Last spring.']);
      expect(ai.messages.first.fromUser, isTrue);
      expect(ai.thinking, isFalse);
    });

    test('the scope is passed through exactly as given', () async {
      final scopes = <String?>[];
      final ai = AiConversation((q, {journalId}) async {
        scopes.add(journalId);
        return answer('ok');
      });
      await ai.send('a');
      await ai.send('b', journalId: '');
      await ai.send('c', journalId: 'j1');

      // Omitted, empty and named are three different instructions to the server.
      expect(scopes, [null, '', 'j1']);
    });

    test('a failure is said in the conversation, not left hanging', () async {
      final ai = AiConversation((q, {journalId}) async => throw Exception('offline'));
      await ai.send('Are you there?');

      expect(ai.thinking, isFalse, reason: 'this used to sit at "Recalling…" forever');
      expect(ai.messages, hasLength(2));
      expect(ai.messages.last.fromUser, isFalse);
      expect(ai.messages.last.text, contains('could not reach your memories'));
    });

    test('an empty question asks nothing', () async {
      var asked = 0;
      final ai = AiConversation((q, {journalId}) async {
        asked++;
        return answer('ok');
      });
      await ai.send('   ');

      expect(asked, 0);
      expect(ai.messages, isEmpty);
    });
  });
}

/// Opening the record page first stops whatever memory is playing. There is no
/// audio plugin under test, so the real controller's `stop` never returns and
/// the page never opens; this one has nothing to stop.
class _QuietPlayback extends AudioPlaybackController {
  @override
  PlaybackState build() => const PlaybackState();

  @override
  Future<void> stop() async {}
}

/// Let requests land and transitions finish.
///
/// Not `pumpAndSettle`: the Recall page's orb breathes for as long as it is on
/// screen, and an animation that never ends is an app that never settles.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 500));
}
