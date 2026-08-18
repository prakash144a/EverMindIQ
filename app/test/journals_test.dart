import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/journals/journals_screen.dart';
import 'package:voiceiq/src/features/memory/memory_detail_screen.dart';

/// Journals: managing them, the tier ceiling, and filing a memory into one.
///
/// The ceiling is the first entitlement the app enforces visually, so the tests
/// that matter most here are the ones about what happens *at* it — a control
/// that silently vanishes is a bug report, not a paywall.
void main() {
  /// Requests the widget under test made, in order — so a test can assert what
  /// reached the server, not just what the UI drew.
  late List<http.BaseRequest> sent;
  late List<Map<String, dynamic>> journals;
  late List<Map<String, dynamic>> recordings;

  setUp(() {
    sent = [];
    journals = [];
    recordings = [];
  });

  Map<String, dynamic> journal(String id, String name) =>
      {'id': id, 'name': name, 'color_index': 0};

  Map<String, dynamic> recording({
    String id = 'a',
    String title = 'Fishing trip',
    String journalId = '',
  }) =>
      {
        'id': id,
        'event_date': '2025-08-16',
        'recorded_at': DateTime.now().toUtc().toIso8601String(),
        'status': 'indexed',
        'source': 'text',
        'title': title,
        'transcript': 'Something that happened.',
        'summary': 'A summary.',
        'duration_sec': 0,
        'journal_id': journalId,
      };

  /// A client that serves the mutable [journals] / [recordings] lists and
  /// records every request. Journal writes mutate the list, so a test can assert
  /// the screen re-renders from what the server actually returned.
  MockClient serving({int createStatus = 201}) {
    return MockClient((req) async {
      sent.add(req);
      final path = req.url.path;
      if (path == '/journals' && req.method == 'GET') {
        return http.Response(jsonEncode(journals), 200);
      }
      if (path == '/journals' && req.method == 'POST') {
        if (createStatus != 201) {
          return http.Response(
            jsonEncode({
              'detail': {'error': 'journal_limit', 'limit': 2, 'tier': 'free'},
            }),
            createStatus,
          );
        }
        final name = jsonDecode(req.body)['name'] as String;
        final created = journal('new-${journals.length}', name);
        journals.add(created);
        return http.Response(jsonEncode(created), 201);
      }
      if (path.startsWith('/journals/') && req.method == 'DELETE') {
        journals.removeWhere((j) => j['id'] == path.split('/').last);
        return http.Response(jsonEncode({'unfiled': 3}), 200);
      }
      if (path.startsWith('/journals/') && req.method == 'PATCH') {
        final id = path.split('/').last;
        final name = jsonDecode(req.body)['name'] as String;
        final updated = journal(id, name);
        journals[journals.indexWhere((j) => j['id'] == id)] = updated;
        return http.Response(jsonEncode(updated), 200);
      }
      if (path == '/recordings') return http.Response(jsonEncode(recordings), 200);
      if (path.startsWith('/recordings/') && req.method == 'PATCH') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final id = path.split('/').last;
        final row = recordings.firstWhere((r) => r['id'] == id);
        return http.Response(jsonEncode({...row, ...body}), 200);
      }
      if (path == '/profile') {
        return http.Response(jsonEncode({'journals_max': 2, 'tier': 'free'}), 200);
      }
      return http.Response('{}', 200);
    });
  }

  Future<void> pump(WidgetTester tester, Widget home, {MockClient? client}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(
            ApiClient(client: client ?? serving(), baseUrl: 'http://test.invalid'),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: home),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  // -- the list ---------------------------------------------------------------

  testWidgets('journals list with Unfiled always first', (tester) async {
    journals = [journal('j1', 'Travel')];
    recordings = [
      recording(id: 'a', journalId: 'j1'),
      recording(id: 'b'),
    ];
    await pump(tester, const JournalsScreen());

    expect(find.text('Travel'), findsOneWidget);
    // Unfiled is permanent, not conditional — it is the only route to memories
    // recorded before journals existed.
    expect(find.text('Unfiled'), findsOneWidget);
    expect(find.text('1 memory'), findsNWidgets(2));
  });

  testWidgets('Unfiled shows even when everything is filed', (tester) async {
    journals = [journal('j1', 'Travel')];
    recordings = [recording(id: 'a', journalId: 'j1')];
    await pump(tester, const JournalsScreen());

    expect(find.text('Unfiled'), findsOneWidget);
    expect(find.text('0 memories'), findsOneWidget);
  });

  testWidgets('creating a journal posts it and shows it', (tester) async {
    await pump(tester, const JournalsScreen());

    await tester.tap(find.text('New journal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Politics');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final post = sent.firstWhere((r) => r.method == 'POST' && r.url.path == '/journals');
    expect(jsonDecode((post as http.Request).body)['name'], 'Politics');
    expect(find.text('Politics'), findsOneWidget);
  });

  testWidgets('renaming a journal patches it and the row follows', (tester) async {
    journals = [journal('j1', 'Travel')];
    await pump(tester, const JournalsScreen());

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Trips');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Travel'), findsNothing);
  });

  // -- the ceiling ------------------------------------------------------------

  testWidgets('at the ceiling the button is disabled and says so', (tester) async {
    journals = [journal('j1', 'Travel'), journal('j2', 'Politics')];
    await pump(tester, const JournalsScreen());

    // Disabled rather than hidden, and the count is the whole explanation.
    expect(find.text('2 of 2'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('below the ceiling the button works', (tester) async {
    journals = [journal('j1', 'Travel')];
    await pump(tester, const JournalsScreen());

    expect(find.text('1 of 2'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('a rejected create is explained in words, not a status code', (tester) async {
    await pump(tester, const JournalsScreen(), client: serving(createStatus: 403));

    await tester.tap(find.text('New journal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Sports');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('You have used all your journals.'), findsOneWidget);
  });

  // -- deleting ---------------------------------------------------------------

  testWidgets('deleting warns that memories move rather than vanish', (tester) async {
    journals = [journal('j1', 'Travel')];
    recordings = [
      recording(id: 'a', journalId: 'j1'),
      recording(id: 'b', journalId: 'j1'),
    ];
    await pump(tester, const JournalsScreen());

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Nobody should fear that deleting a journal deletes what is in it.
    expect(find.textContaining('2 memories will move to Unfiled'), findsOneWidget);
    expect(find.textContaining('Nothing is deleted'), findsOneWidget);
  });

  testWidgets('cancelling a delete leaves the journal alone', (tester) async {
    journals = [journal('j1', 'Travel')];
    await pump(tester, const JournalsScreen());

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(sent.any((r) => r.method == 'DELETE'), isFalse);
    expect(find.text('Travel'), findsOneWidget);
  });

  testWidgets('confirming a delete removes the row and reports the move', (tester) async {
    journals = [journal('j1', 'Travel')];
    await pump(tester, const JournalsScreen());

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(sent.any((r) => r.method == 'DELETE' && r.url.path == '/journals/j1'), isTrue);
    expect(find.text('Travel'), findsNothing);
    expect(find.text('3 memories moved to Unfiled.'), findsOneWidget);
  });

  // -- filing from the memory detail screen -----------------------------------

  testWidgets('an unfiled memory offers to be filed', (tester) async {
    journals = [journal('j1', 'Travel')];
    recordings = [recording(id: 'a')];
    await pump(tester, const MemoryDetailScreen(recordingId: 'a'));

    expect(find.text('Not in a journal'), findsOneWidget);
    expect(find.text('File it'), findsOneWidget);
  });

  testWidgets('a filed memory names its journal', (tester) async {
    journals = [journal('j1', 'Travel')];
    recordings = [recording(id: 'a', journalId: 'j1')];
    await pump(tester, const MemoryDetailScreen(recordingId: 'a'));

    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
  });

  testWidgets('picking a journal patches the memory and the row updates', (tester) async {
    journals = [journal('j1', 'Travel')];
    recordings = [recording(id: 'a')];
    await pump(tester, const MemoryDetailScreen(recordingId: 'a'));

    await tester.tap(find.text('File it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Travel').last);
    await tester.pumpAndSettle();

    final patch = sent.firstWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/recordings/a');
    expect(jsonDecode((patch as http.Request).body), {'journal_id': 'j1'});
    // Optimistic, so the row has already moved.
    expect(find.text('Change'), findsOneWidget);
  });

  testWidgets('unfiling from the picker sends an empty id, not a null', (tester) async {
    journals = [journal('j1', 'Travel')];
    recordings = [recording(id: 'a', journalId: 'j1')];
    await pump(tester, const MemoryDetailScreen(recordingId: 'a'));

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unfiled'));
    await tester.pumpAndSettle();

    final patch = sent.firstWhere((r) => r.method == 'PATCH');
    expect(jsonDecode((patch as http.Request).body), {'journal_id': ''});
  });
}
