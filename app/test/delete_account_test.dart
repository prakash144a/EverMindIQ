import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/account/delete_account_screen.dart';

/// Closing the account.
///
/// This is the only action in the app that destroys everything at once, and the
/// data it destroys mostly cannot be re-created by the person losing it. So what
/// is tested here is the friction: that the button does nothing until the word is
/// typed, that the screen says how much is at stake in numbers rather than in the
/// abstract, and that it states plainly that no recovery exists.
///
/// The Firebase half of the flow (releasing the identity) is deliberately out of
/// scope — it needs a real Firebase app — so these stop at the API call, which is
/// the step that actually destroys the data.
void main() {
  late List<http.BaseRequest> sent;

  setUp(() => sent = []);


  Future<void> pumpDeleteAccount(
    WidgetTester tester, {
    int memories = 3,
    int audioMemories = 2,
    int journals = 2,
    String email = 'someone@example.com',
    int deleteStatus = 204,
  }) async {
    // The screen is deliberately long — it states the whole cost before it
    // offers the button. On the default 800x600 surface the confirm field and
    // the button fall below the fold, where a lazy ListView never builds them,
    // and every assertion about them would fail for a reason that has nothing
    // to do with the behaviour under test.
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = MockClient((req) async {
      sent.add(req);
      if (req.method == 'DELETE' && req.url.path == '/account') {
        return http.Response('', deleteStatus);
      }
      if (req.url.path == '/recordings') {
        return http.Response(
          jsonEncode([
            for (var i = 0; i < memories; i++)
              {
                'id': 'm$i',
                'event_date': '2026-08-15',
                'status': 'indexed',
                'source': i < audioMemories ? 'voice' : 'text',
                'audio_path': i < audioMemories ? 'gs://b/a/$i.m4a' : '',
                'duration_sec': i < audioMemories ? 12.0 : 0.0,
                'title': 'Memory $i',
              },
          ]),
          200,
        );
      }
      if (req.url.path == '/journals') {
        return http.Response(
          jsonEncode([
            for (var i = 0; i < journals; i++) {'id': 'j$i', 'name': 'Journal $i'},
          ]),
          200,
        );
      }
      if (req.url.path == '/profile') {
        return http.Response(
          jsonEncode({'email': email, 'email_verified': email.isNotEmpty, 'tier': 'free'}),
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
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const DeleteAccountScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool deleteWasSent() =>
      sent.any((r) => r.method == 'DELETE' && r.url.path == '/account');

  FilledButton deleteButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete my account'));

  testWidgets('the button is dead until the word is typed', (tester) async {
    await pumpDeleteAccount(tester);

    expect(deleteButton(tester).onPressed, isNull);

    // A near miss is still a miss.
    await tester.enterText(find.byType(TextField), 'DELET');
    await tester.pump();
    expect(deleteButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    expect(deleteButton(tester).onPressed, isNotNull);
    // Typing it is not itself the action.
    expect(deleteWasSent(), isFalse);
  });

  testWidgets('the confirmation word is not case-sensitive', (tester) async {
    // The speed bump is meant to make the action deliberate, not to punish a
    // keyboard that autocapitalises differently.
    await pumpDeleteAccount(tester);

    await tester.enterText(find.byType(TextField), 'delete');
    await tester.pump();

    expect(deleteButton(tester).onPressed, isNotNull);
  });

  testWidgets('it counts what is about to be lost', (tester) async {
    await pumpDeleteAccount(tester, memories: 47, audioMemories: 31, journals: 4);

    expect(find.text('47 memories'), findsOneWidget);
    expect(find.text('31 audio recordings'), findsOneWidget);
    expect(find.text('4 journals'), findsOneWidget);
  });

  testWidgets('a single memory is not called "1 memories"', (tester) async {
    await pumpDeleteAccount(tester, memories: 1, audioMemories: 1, journals: 1);

    expect(find.text('1 memory'), findsOneWidget);
    expect(find.text('1 audio recording'), findsOneWidget);
    expect(find.text('1 journal'), findsOneWidget);
  });

  testWidgets('an account with no audio is not told it is losing recordings',
      (tester) async {
    await pumpDeleteAccount(tester, memories: 2, audioMemories: 0);

    expect(find.textContaining('audio recording'), findsNothing);
  });

  testWidgets('it states that recovery does not exist', (tester) async {
    await pumpDeleteAccount(tester);

    expect(find.textContaining('There is no recovery'), findsOneWidget);
    expect(find.textContaining('nobody, including us, can bring any of it back'),
        findsOneWidget);
    // And points at the way to keep a copy while there still is one.
    expect(find.textContaining('Export & backup'), findsOneWidget);
  });

  testWidgets('it names the email the data is kept under', (tester) async {
    await pumpDeleteAccount(tester, email: 'prakash@example.com');

    expect(find.textContaining('prakash@example.com'), findsOneWidget);
    expect(find.textContaining('The link between this account and your email'),
        findsOneWidget);
  });

  testWidgets('an account with no email is still deletable', (tester) async {
    // Anonymous users have memories too, and are owed the same way out.
    await pumpDeleteAccount(tester, email: '');

    expect(find.textContaining('recorded on this install'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    expect(deleteButton(tester).onPressed, isNotNull);
  });

  testWidgets('confirming calls the purge endpoint', (tester) async {
    await pumpDeleteAccount(tester);

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    await tester.tap(find.text('Delete my account'));
    await tester.pump();

    expect(deleteWasSent(), isTrue);
  });

  testWidgets('a failure says so and leaves the account alone', (tester) async {
    await pumpDeleteAccount(tester, deleteStatus: 500);

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    await tester.tap(find.text('Delete my account'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not delete your account'), findsOneWidget);
    // Still here, and still able to try again.
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    expect(deleteButton(tester).onPressed, isNotNull);
  });

  testWidgets('backing out is offered right beside the destructive button',
      (tester) async {
    await pumpDeleteAccount(tester);

    expect(find.text('Keep my account'), findsOneWidget);
  });
}
