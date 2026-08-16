import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/error_log.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/feedback/feedback_screen.dart';

void main() {
  late List<http.BaseRequest> sent;

  setUp(() {
    sent = [];
    ErrorLog.instance.clear();
  });
  tearDown(() => ErrorLog.instance.clear());

  Future<void> pumpForm(
    WidgetTester tester, {
    String? prefill,
    int status = 201,
  }) async {
    final client = MockClient((req) async {
      sent.add(req);
      return http.Response(status == 201 ? jsonEncode({'id': 'f1'}) : 'boom', status);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider
              .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: FeedbackScreen(prefillMessage: prefill),
        ),
      ),
    );
    await tester.pump();
  }

  /// The form grows once diagnostics are shown, pushing the button out of view.
  Future<void> tapSend(WidgetTester tester) async {
    final send = find.text('Send report');
    await tester.ensureVisible(send);
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
  }

  group('ErrorLog', () {
    test('keeps newest first and collapses an immediate repeat', () {
      ErrorLog.instance.add(source: 'recordings', message: 'boom');
      ErrorLog.instance.add(source: 'recordings', message: 'boom');
      expect(ErrorLog.instance.entries, hasLength(1),
          reason: 'a provider that keeps failing must not flood the log');

      ErrorLog.instance.add(source: 'settings', message: 'other');
      expect(ErrorLog.instance.entries.first.message, 'other');
    });

    test('caps the buffer', () {
      for (var i = 0; i < 40; i++) {
        ErrorLog.instance.add(source: 's$i', message: 'm$i');
      }
      expect(ErrorLog.instance.entries.length, lessThanOrEqualTo(20));
      expect(ErrorLog.instance.entries.first.message, 'm39');
    });

    test('a report carries the source, message and stack', () {
      ErrorLog.instance.add(source: 'recordings', message: 'bad cast', details: '#0 main');
      final report = ErrorLog.instance.latest!.toReport();
      expect(report, contains('recordings'));
      expect(report, contains('bad cast'));
      expect(report, contains('#0 main'));
    });
  });

  testWidgets('sends the report with the captured error attached', (tester) async {
    ErrorLog.instance.add(
      source: 'recordings',
      message: "type 'List<dynamic>' is not a subtype of type 'String?' in type cast",
      details: '#0 Recording.fromJson',
    );

    await pumpForm(tester);
    expect(find.text('Attach technical details'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Pulled to refresh and it broke.');
    await tapSend(tester);

    final post = sent.single as http.Request;
    expect(post.method, 'POST');
    expect(post.url.path, '/feedback');

    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['kind'], 'problem');
    expect(body['message'], 'Pulled to refresh and it broke.');
    expect(body['diagnostics'], contains('is not a subtype'));
    expect(body['diagnostics'], contains('recordings'));
    expect(body['platform'], isNotEmpty);
  });

  testWidgets('an empty message is refused before any request', (tester) async {
    await pumpForm(tester);
    await tapSend(tester);

    expect(sent, isEmpty);
    expect(find.text('Please describe what happened.'), findsOneWidget);
  });

  testWidgets('diagnostics can be left out', (tester) async {
    ErrorLog.instance.add(source: 'recordings', message: 'secret-ish detail');
    await pumpForm(tester);

    await tester.enterText(find.byType(TextField), 'Just an idea.');
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tapSend(tester);

    final body = jsonDecode((sent.single as http.Request).body) as Map<String, dynamic>;
    expect(body['diagnostics'], isEmpty);
  });

  testWidgets('a server failure keeps the form and explains why', (tester) async {
    await pumpForm(tester, status: 500);

    await tester.enterText(find.byType(TextField), 'Something broke.');
    await tapSend(tester);

    expect(find.textContaining('Could not send'), findsOneWidget);
    expect(find.byType(FeedbackScreen), findsOneWidget, reason: 'the draft must survive');
  });

  testWidgets('an error card prefills the form', (tester) async {
    await pumpForm(tester, prefill: 'Could not load recordings: bad cast');
    expect(find.text('Could not load recordings: bad cast'), findsOneWidget);
  });
}
