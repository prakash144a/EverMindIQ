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

/// Covers how a "Recent moments" row reads: a title and an age, plus an
/// in-progress note only while the backend is still transcribing.
void main() {
  Map<String, dynamic> rec({
    required String id,
    required String status,
    required String title,
    required Duration age,
  }) =>
      {
        'id': id,
        'event_date': '2025-08-16',
        'recorded_at': DateTime.now().toUtc().subtract(age).toIso8601String(),
        'status': status,
        'title': title,
        'summary': 'The user went to the lake and spent the morning fishing.',
      };

  /// Requests the widget under test made, in order — so a test can assert what
  /// reached the server, not just what the UI drew.
  late List<http.BaseRequest> sent;

  setUp(() => sent = []);

  Future<void> pumpHome(
    WidgetTester tester,
    List<Map<String, dynamic>> recs, {
    bool patchFails = false,
  }) async {
    final client = MockClient((req) async {
      sent.add(req);
      if (req.method == 'PATCH') {
        if (patchFails) return http.Response('nope', 500);
        final patch = jsonDecode(req.body) as Map<String, dynamic>;
        final id = req.url.pathSegments.last;
        final updated = {
          ...recs.firstWhere((r) => r['id'] == id),
          ...patch,
          'is_milestone_manual': true,
        };
        return http.Response(jsonEncode(updated), 200);
      }
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
        child: MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a finished recording shows only its title and age', (tester) async {
    await pumpHome(tester, [
      rec(
        id: 'a',
        status: 'indexed',
        title: 'Fishing trip with Dad',
        age: const Duration(days: 2),
      ),
    ]);

    expect(find.text('Fishing trip with Dad'), findsOneWidget);
    expect(find.text('2d ago'), findsOneWidget);
    expect(find.text('AI is transcribing…'), findsNothing);
    // The third-person summary must not leak into the list.
    expect(find.textContaining('The user went to'), findsNothing);
  });

  testWidgets('a recording still being processed shows the progress note', (tester) async {
    await pumpHome(tester, [
      rec(id: 'b', status: 'uploaded', title: '', age: const Duration(seconds: 3)),
    ]);

    expect(find.text('New recording'), findsOneWidget);
    expect(find.text('AI is transcribing…'), findsOneWidget);
    expect(find.text('just now'), findsOneWidget);
  });

  testWidgets('a failed recording says so instead of spinning forever', (tester) async {
    await pumpHome(tester, [
      rec(id: 'c', status: 'failed', title: '', age: const Duration(hours: 3)),
    ]);

    expect(find.text('Processing failed'), findsOneWidget);
    expect(find.text('AI is transcribing…'), findsNothing);
    expect(find.text('3h ago'), findsOneWidget);
  });

  testWidgets('tapping the star marks a recording as a milestone', (tester) async {
    await pumpHome(tester, [
      rec(id: 'a', status: 'indexed', title: 'An ordinary Tuesday', age: const Duration(days: 1)),
    ]);

    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.star_outline_rounded));
    await tester.pumpAndSettle();

    final patch = sent.firstWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/recordings/a');
    expect(jsonDecode((patch as http.Request).body), {'is_milestone': true});

    expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    // The row's star fills in and the Milestones rail appears above the list,
    // so there are now two filled stars on screen.
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(2));
    expect(find.text('Milestones'), findsOneWidget);
  });

  testWidgets('a failed star request rolls the icon back', (tester) async {
    await pumpHome(
      tester,
      [rec(id: 'a', status: 'indexed', title: 'An ordinary Tuesday', age: const Duration(days: 1))],
      patchFails: true,
    );

    await tester.tap(find.byIcon(Icons.star_outline_rounded));
    await tester.pumpAndSettle();

    expect(sent.any((r) => r.method == 'PATCH'), isTrue);
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget,
        reason: 'the star must not claim a change the server rejected');
    expect(find.text('Could not update this milestone.'), findsOneWidget);
  });
}
