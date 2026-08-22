import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/auth.dart';
import 'package:voiceiq/src/data/models.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/account/login_screen.dart';

/// The way in, and the question it has to ask on the way.
///
/// Signing in is the only route to any memory now, so what matters here is that
/// it cannot take someone's phone from them silently: an account already open
/// elsewhere is a prompt, and a "no" leaves both devices exactly as they were.
///
/// Firebase is stubbed out entirely — [_FakeAuth] stands in for the controller,
/// so these exercise the screen's decisions rather than the platform's.
class _FakeAuth extends AuthController {
  SignInResult? signedIn;
  int acknowledged = 0;

  @override
  AuthState build() => const AuthState(AuthStage.signedOut);

  @override
  Future<void> signIn(SignInResult result) async {
    signedIn = result;
    state = const AuthState(AuthStage.signedIn);
  }

  @override
  void acknowledgeEnded() => acknowledged++;
}

void main() {
  late List<http.BaseRequest> sent;
  late _FakeAuth auth;

  setUp(() {
    sent = [];
    auth = _FakeAuth();
  });

  /// [heldElsewhere]: the account is already open on another device.
  /// [claimStatus]: what `/auth/session` answers with.
  Future<void> pumpLogin(
    WidgetTester tester, {
    bool heldElsewhere = false,
    int otpStatus = 204,
    SessionEndedException? notice,
  }) async {
    const otherDevice = {
      'device': 'an Android phone',
      'platform': 'android',
      'signed_in_at': '2026-08-21T16:12:00Z',
    };
    final client = MockClient((req) async {
      sent.add(req);
      switch (req.url.path) {
        case '/auth/otp/request':
          return http.Response(
            otpStatus == 204 ? '' : '{"detail":"Please wait 42s"}',
            otpStatus,
          );
        case '/auth/otp/verify':
          return http.Response(
            jsonEncode({
              'status': 'signed_in',
              'ticket': 'tkt_1',
              if (heldElsewhere) 'active_session': otherDevice,
            }),
            200,
          );
        case '/auth/session':
          return http.Response(
            jsonEncode({
              'uid': 'usr_1',
              'token': 'tok_1',
              'session_id': 'ses_1',
              'profile': {'preferred_name': 'Prakash', 'has_profile': true},
            }),
            200,
          );
      }
      return http.Response('{}', 200);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider
              .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
          authControllerProvider.overrideWith(() => auth),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: LoginScreen(notice: notice),
        ),
      ),
    );
    await tester.pump();
  }

  /// Let the request complete and any dialog animate in.
  ///
  /// Not `pumpAndSettle`: the buttons hold an indeterminate progress spinner
  /// while a request is in flight — and after a successful sign-in it never
  /// stops, because the real app has swapped the whole screen out by then.
  /// An animation that never ends is an app that never settles.
  Future<void> tick(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> enterEmail(WidgetTester tester, [String email = 'p@example.com']) async {
    await tester.enterText(find.byType(TextField).first, email);
    await tester.tap(find.text('Email me a code'));
    await tick(tester);
    // Run the resend cooldown out so its ticker does not outlive the test.
    await tester.pump(const Duration(seconds: 61));
  }

  Future<void> enterCode(WidgetTester tester, [String code = '123456']) async {
    await tester.enterText(find.byType(TextField).first, code);
    await tester.tap(find.text('Sign in'));
    await tick(tester);
  }

  http.Request posted(List<http.BaseRequest> sent, String path) =>
      sent.firstWhere((r) => r.url.path == path) as http.Request;

  group('asking for a code', () {
    testWidgets('sends the address and moves on to the code', (tester) async {
      await pumpLogin(tester);
      await enterEmail(tester);

      expect(jsonDecode(posted(sent, '/auth/otp/request').body), {'email': 'p@example.com'});
      expect(find.textContaining('We emailed a six-digit code'), findsOneWidget);
    });

    testWidgets('a malformed address never reaches the server', (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextField).first, 'nope');
      await tester.tap(find.text('Email me a code'));
      await tester.pump();

      expect(sent.any((r) => r.url.path == '/auth/otp/request'), isFalse);
      expect(find.text('Please enter a valid email address.'), findsOneWidget);
    });

    testWidgets('a throttled request keeps the user on the form', (tester) async {
      await pumpLogin(tester, otpStatus: 429);
      await enterEmail(tester);

      expect(find.textContaining('Please wait 42s'), findsOneWidget);
      expect(find.textContaining('We emailed a six-digit code'), findsNothing);
    });
  });

  group('signing in', () {
    testWidgets('a good code claims a session and signs the device in', (tester) async {
      await pumpLogin(tester);
      await enterEmail(tester);
      await enterCode(tester);

      expect(jsonDecode(posted(sent, '/auth/session').body), {
        'ticket': 'tkt_1',
        'takeover': false,
      });
      expect(auth.signedIn?.sessionId, 'ses_1');
    });

    testWidgets('an account open elsewhere is a question, asked before taking it',
        (tester) async {
      await pumpLogin(tester, heldElsewhere: true);
      await enterEmail(tester);
      await enterCode(tester);

      expect(find.text('Already signed in somewhere'), findsOneWidget);
      expect(find.textContaining('an Android phone'), findsOneWidget);
      expect(
        sent.any((r) => r.url.path == '/auth/session'),
        isFalse,
        reason: 'nobody is signed out until the question is answered',
      );
    });

    testWidgets('answering yes takes the account over', (tester) async {
      await pumpLogin(tester, heldElsewhere: true);
      await enterEmail(tester);
      await enterCode(tester);
      await tester.tap(find.text('Continue here'));
      await tick(tester);

      expect(jsonDecode(posted(sent, '/auth/session').body)['takeover'], isTrue);
      expect(auth.signedIn?.uid, 'usr_1');
    });

    testWidgets('answering no leaves the other device alone', (tester) async {
      await pumpLogin(tester, heldElsewhere: true);
      await enterEmail(tester);
      await enterCode(tester);
      await tester.tap(find.text('Cancel'));
      await tick(tester);

      expect(sent.any((r) => r.url.path == '/auth/session'), isFalse);
      expect(auth.signedIn, isNull);
      expect(find.text('Sign in'), findsOneWidget, reason: 'still on the code step');
    });
  });

  group('being signed out from elsewhere', () {
    testWidgets('says which device took over, and that nothing was lost', (tester) async {
      await pumpLogin(
        tester,
        notice: SessionEndedException(
          code: 'session_replaced',
          message: 'Your account was opened on an Android phone.',
          replacedBy: const DeviceSessionInfo(device: 'an Android phone'),
        ),
      );

      expect(find.text('You were signed out'), findsOneWidget);
      expect(find.textContaining('an Android phone'), findsOneWidget);
      expect(find.textContaining('Nothing was lost'), findsOneWidget);
    });

    testWidgets('a plain sign-out explains itself without blaming a device',
        (tester) async {
      await pumpLogin(
        tester,
        notice: SessionEndedException(code: 'signed_out', message: 'You have been signed out.'),
      );

      expect(find.text('You were signed out'), findsOneWidget);
      expect(find.textContaining('Sign in to open your memories again'), findsOneWidget);
    });

    testWidgets('the explanation is dropped once they start signing back in',
        (tester) async {
      await pumpLogin(
        tester,
        notice: SessionEndedException(code: 'signed_out', message: 'You have been signed out.'),
      );
      await enterEmail(tester);

      expect(auth.acknowledged, 1);
    });
  });
}
