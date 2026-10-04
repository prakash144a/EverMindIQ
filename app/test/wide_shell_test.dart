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
import 'package:voiceiq/src/data/models.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/shell/app_shell.dart';
import 'package:voiceiq/src/features/shell/quick_composer.dart';
import 'package:voiceiq/src/widgets/attach_placeholder.dart';

/// The app on a wide screen is three panes — a rail, the memories with a
/// composer, and Recall always open — and on a phone-sized one it is exactly
/// what it was. Same screens, same data; only the arrangement differs, so what
/// matters here is which arrangement a window gets and that the new pieces in
/// the wide one actually reach the server.
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

  Future<void> pumpShell(WidgetTester tester, Size window, {bool saveFails = false}) async {
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
        case '/recordings/text':
          if (saveFails) return http.Response('{"detail":"nope"}', 500);
          return http.Response(
            jsonEncode({'id': 'new', 'event_date': '2026-10-04', 'status': 'uploaded', 'source': 'text'}),
            201,
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
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const AppShell()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  const desktop = Size(1440, 900);
  const phone = Size(400, 800);

  http.Request posted(String path) =>
      sent.lastWhere((r) => r.url.path == path && r.method == 'POST') as http.Request;

  group('which layout a window gets', () {
    testWidgets('a wide window is three panes', (tester) async {
      await pumpShell(tester, desktop);

      // The rail: places that used to be behind the menu.
      for (final place in ['Home', 'Timeline', 'Journals', 'Milestones', 'Insights', 'More']) {
        expect(find.text(place), findsOneWidget, reason: place);
      }
      // The memories, with the composer above them.
      expect(find.text('Your memories'), findsOneWidget);
      expect(find.byType(QuickComposer), findsOneWidget);
      expect(find.text('The story about the bicycle'), findsOneWidget);
      // Recall, open without being asked for.
      expect(find.text('Recall'), findsOneWidget);
      expect(find.text('Ask your memories…'), findsOneWidget);
      // And none of the phone's chrome.
      expect(find.text('Record'), findsNothing);
    });

    testWidgets('a phone-sized window is the phone layout, untouched', (tester) async {
      await pumpShell(tester, phone);

      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Recall'), findsOneWidget); // the dock button, not a pane
      expect(find.byType(QuickComposer), findsNothing);
      expect(find.text('Timeline'), findsNothing);
      expect(find.text('Ask your memories…'), findsNothing);
    });

    testWidgets('the rail changes what the middle pane shows, and Recall stays', (tester) async {
      await pumpShell(tester, desktop);

      await tester.tap(find.text('Journals'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(QuickComposer), findsNothing);
      expect(find.text('Ask your memories…'), findsOneWidget);
    });
  });

  group('writing a memory in place', () {
    testWidgets('typing and saving posts the memory and empties the field', (tester) async {
      await pumpShell(tester, desktop);

      final field = find.descendant(
        of: find.byType(QuickComposer),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '  We drove to the coast at sunrise.  ');
      await tester.pump();
      expect(DraftStore.current, isNotEmpty, reason: 'kept as a draft before it is saved');

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(jsonDecode(posted('/recordings/text').body),
          {'text': 'We drove to the coast at sunrise.'});
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(DraftStore.current, isEmpty);
    });

    testWidgets('a save that fails keeps what was written', (tester) async {
      await pumpShell(tester, desktop, saveFails: true);

      final field = find.descendant(
        of: find.byType(QuickComposer),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Too precious to lose to an error.');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.widget<TextField>(field).controller!.text, 'Too precious to lose to an error.');
      expect(DraftStore.current, 'Too precious to lose to an error.');
      expect(find.textContaining('Could not save'), findsOneWidget);
    });

    testWidgets('nothing can be saved until something is written', (tester) async {
      await pumpShell(tester, desktop);

      final save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(save.onPressed, isNull);
    });
  });

  group('attachments', () {
    testWidgets('the place for photos, videos and files says it is not built yet',
        (tester) async {
      await pumpShell(tester, desktop);

      await tester.tap(find.byType(AttachPlaceholderButton));
      // Not `pumpAndSettle`: the Recall pane's orb breathes for as long as it is
      // on screen, and on a wide screen it always is.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

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

  group('recall beside the memories', () {
    testWidgets('a question typed in the pane is asked, and answered there', (tester) async {
      await pumpShell(tester, desktop);

      await tester.enterText(
        find.widgetWithText(TextField, 'Ask your memories…'),
        'When did Appa tell the bicycle story?',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      expect(jsonDecode(posted('/chat').body)['question'], 'When did Appa tell the bicycle story?');
      expect(find.text('On 1 October.'), findsOneWidget);
      // Still three panes: the answer did not take the window over.
      expect(find.byType(QuickComposer), findsOneWidget);
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
