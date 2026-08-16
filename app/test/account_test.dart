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
import 'package:voiceiq/src/features/account/signup_screen.dart';
import 'package:voiceiq/src/widgets/initials_avatar.dart';

void main() {
  late List<http.BaseRequest> sent;

  setUp(() => sent = []);

  Future<void> pumpSignup(
    WidgetTester tester, {
    bool restoreOnly = false,
    int otpStatus = 204,
  }) async {
    final client = MockClient((req) async {
      sent.add(req);
      if (req.url.path == '/auth/otp/request') {
        return http.Response(
          otpStatus == 204 ? '' : '{"detail":"Please wait 42s"}',
          otpStatus,
        );
      }
      if (req.url.path == '/profile') {
        return http.Response(jsonEncode({'has_profile': false}), 200);
      }
      return http.Response('{}', 200);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider
              .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SignupScreen(restoreOnly: restoreOnly),
        ),
      ),
    );
    await tester.pump();
  }

  group('initials', () {
    test('a full name uses the first and last words', () {
      expect(initialsFor('Prakash Annadurai'), 'PA');
      expect(initialsFor('Dhivya Varadhan'), 'DV');
    });

    test('a middle name is skipped in favour of the surname', () {
      expect(initialsFor('Ada Barbara King Lovelace'), 'AL');
    });

    test('one word falls back to its first two letters', () {
      expect(initialsFor('Dhivya'), 'DH');
      expect(initialsFor('prakash'), 'PR');
    });

    test('a single letter name does not crash', () {
      expect(initialsFor('D'), 'D');
    });

    test('no usable name yields nothing, so the caller can show an icon', () {
      expect(initialsFor(''), '');
      expect(initialsFor('   '), '');
      expect(initialsFor('123 !!'), '');
    });

    test('extra whitespace and punctuation are ignored', () {
      expect(initialsFor('  Prakash   Annadurai  '), 'PA');
      expect(initialsFor("O'Brien Smith"), 'OS');
    });
  });

  group('InitialsAvatar', () {
    testWidgets('shows the initials when there is a name', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: InitialsAvatar(initials: 'PA'))),
      );
      expect(find.text('PA'), findsOneWidget);
      expect(find.byIcon(Icons.person), findsNothing);
    });

    testWidgets('falls back to an icon when anonymous', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: InitialsAvatar(initials: ''))),
      );
      expect(find.byIcon(Icons.person), findsOneWidget);
    });
  });

  group('UserProfile', () {
    test('an absent profile parses to the anonymous default', () {
      final p = UserProfile.fromJson({'has_profile': false});
      expect(p.hasProfile, isFalse);
      expect(p.initials, '');
    });

    test('a verified profile carries name, email and initials', () {
      final p = UserProfile.fromJson({
        'preferred_name': 'Prakash Annadurai',
        'email': 'p@example.com',
        'email_verified': true,
        'has_profile': true,
      });
      expect(p.initials, 'PA');
      expect(p.hasProfile, isTrue);
    });
  });

  group('VerifyResult', () {
    test('a signup restores nothing', () {
      final r = VerifyResult.fromJson({
        'status': 'signed_up',
        'profile': {'has_profile': true},
      });
      expect(r.isRestore, isFalse);
      expect(r.restoredRecordings, 0);
    });

    test('a restore reports how much came back', () {
      final r = VerifyResult.fromJson({
        'status': 'restored',
        'merged': {'recordings': 2},
        'profile': {'preferred_name': 'Dhivya Varadhan', 'has_profile': true},
      });
      expect(r.isRestore, isTrue);
      expect(r.restoredRecordings, 2);
      expect(r.profile.initials, 'DV');
    });
  });

  group('signup form', () {
    testWidgets('asks for a name and email, then requests a code', (tester) async {
      await pumpSignup(tester);

      await tester.enterText(find.byType(TextField).first, 'Prakash Annadurai');
      await tester.enterText(find.byType(TextField).last, 'p@example.com');
      await tester.tap(find.text('Email me a code'));
      await tester.pumpAndSettle();

      final post = sent.firstWhere((r) => r.url.path == '/auth/otp/request') as http.Request;
      expect(jsonDecode(post.body), {'email': 'p@example.com'});
      expect(find.text('Enter your code'), findsOneWidget);
    });

    testWidgets('a missing name is refused before any request', (tester) async {
      await pumpSignup(tester);

      await tester.enterText(find.byType(TextField).last, 'p@example.com');
      await tester.tap(find.text('Email me a code'));
      await tester.pump();

      expect(sent.any((r) => r.url.path == '/auth/otp/request'), isFalse);
      expect(find.text('Please tell us what to call you.'), findsOneWidget);
    });

    testWidgets('a malformed email is refused before any request', (tester) async {
      await pumpSignup(tester);

      await tester.enterText(find.byType(TextField).first, 'Prakash');
      await tester.enterText(find.byType(TextField).last, 'nope');
      await tester.tap(find.text('Email me a code'));
      await tester.pump();

      expect(sent.any((r) => r.url.path == '/auth/otp/request'), isFalse);
      expect(find.text('Please enter a valid email address.'), findsOneWidget);
    });

    testWidgets('restore mode asks only for the email', (tester) async {
      await pumpSignup(tester, restoreOnly: true);

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
    });

    testWidgets('the signup form offers a restore path', (tester) async {
      await pumpSignup(tester);
      expect(find.textContaining('I already have an account'), findsOneWidget);

      await tester.tap(find.textContaining('I already have an account'));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget, reason: 'the name field is dropped');
    });

    testWidgets('"Not now" records the dismissal so it stops asking', (tester) async {
      await pumpSignup(tester);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      final patch = sent.firstWhere((r) => r.method == 'PATCH') as http.Request;
      expect(patch.url.path, '/profile');
      expect(jsonDecode(patch.body), {'signup_prompt_dismissed': true});
    });

    testWidgets('a rate-limited request keeps the user on the form', (tester) async {
      await pumpSignup(tester, otpStatus: 429);

      await tester.enterText(find.byType(TextField).first, 'Prakash');
      await tester.enterText(find.byType(TextField).last, 'p@example.com');
      await tester.tap(find.text('Email me a code'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not send the code'), findsOneWidget);
      expect(find.text('Enter your code'), findsNothing);
    });
  });
}
