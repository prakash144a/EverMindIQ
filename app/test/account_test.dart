import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voiceiq/src/data/models.dart';
import 'package:voiceiq/src/widgets/initials_avatar.dart';

void main() {
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

  group('sign-in parsing', () {
    test('a clear verify carries a ticket and nothing in the way', () {
      final r = VerifyResult.fromJson({'status': 'signed_up', 'ticket': 'tkt_1'});
      expect(r.isNewAccount, isTrue);
      expect(r.needsTakeover, isFalse);
      expect(r.ticket, 'tkt_1');
    });

    test('a held account is reported as a question, not an error', () {
      final r = VerifyResult.fromJson({
        'status': 'signed_in',
        'ticket': 'tkt_2',
        'active_session': {
          'device': 'an Android phone',
          'platform': 'android',
          'signed_in_at': '2026-08-21T16:12:00Z',
        },
      });
      expect(r.needsTakeover, isTrue);
      expect(r.activeSession!.device, 'an Android phone');
      expect(r.activeSession!.signedInAt, isNotNull);
    });

    test('an unnamed device still reads as something', () {
      expect(DeviceSessionInfo.fromJson(const {}).device, 'another device');
    });

    test('a claimed session carries the credential and the account', () {
      final r = SignInResult.fromJson({
        'uid': 'usr_1',
        'token': 'tok',
        'session_id': 'ses_1',
        'profile': {'preferred_name': 'Dhivya Varadhan', 'has_profile': true},
      });
      expect(r.sessionId, 'ses_1');
      expect(r.profile.initials, 'DV');
    });
  });
}
