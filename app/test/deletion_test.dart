import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/providers.dart';
import 'package:voiceiq/src/features/memory/memory_detail_screen.dart';

/// Deleting a memory, from the screen that offers it.
///
/// The thing worth pinning down is not that a DELETE goes out — it is the
/// *guard rails around it*, because the action cannot be taken back. So: nothing
/// is sent until the user confirms, the confirmation says plainly that recovery
/// is impossible, and a failure leaves the memory visibly intact rather than
/// quietly gone from the list while still on the server.
void main() {
  late List<http.BaseRequest> sent;

  setUp(() => sent = []);

  Map<String, dynamic> memoryJson({
    String id = 'm1',
    String title = 'A ridge walk at sunrise',
    bool hasAudio = true,
  }) =>
      {
        'id': id,
        'event_date': '2026-08-15',
        'recorded_at': '2026-08-15T06:30:00Z',
        'status': 'indexed',
        'source': hasAudio ? 'voice' : 'text',
        'audio_path': hasAudio ? 'gs://b/users/alice/audio/$id.m4a' : '',
        'duration_sec': hasAudio ? 42.0 : 0.0,
        'title': title,
        'transcript': 'We climbed the ridge before the light came up.',
      };

  Future<void> pumpDetail(
    WidgetTester tester, {
    bool hasAudio = true,
    int deleteStatus = 204,
  }) async {
    final client = MockClient((req) async {
      sent.add(req);
      if (req.method == 'DELETE' && req.url.path == '/recordings/m1') {
        return http.Response('', deleteStatus);
      }
      if (req.url.path == '/recordings') {
        return http.Response(jsonEncode([memoryJson(hasAudio: hasAudio)]), 200);
      }
      if (req.url.path == '/journals') return http.Response(jsonEncode([]), 200);
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
          // Pushed onto a host route rather than being `home`, because the
          // screen closes itself after a successful delete — and popping the
          // only route on the stack does nothing, which would make that test
          // pass for the wrong reason.
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => openMemoryDetail(context, 'm1'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> openDeleteDialog(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete memory'));
    await tester.pumpAndSettle();
  }

  bool deleteWasSent() =>
      sent.any((r) => r.method == 'DELETE' && r.url.path == '/recordings/m1');

  testWidgets('the memory is not deletable in one tap', (tester) async {
    await pumpDetail(tester);
    await openDeleteDialog(tester);

    // Choosing the menu item opens a question, it does not perform the delete.
    expect(find.text('Delete this memory?'), findsOneWidget);
    expect(deleteWasSent(), isFalse);
  });

  testWidgets('the confirmation says recovery is impossible', (tester) async {
    await pumpDetail(tester);
    await openDeleteDialog(tester);

    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(find.textContaining('We keep no copy anywhere'), findsOneWidget);
    expect(find.textContaining('nobody — including us — can bring it back'), findsOneWidget);
    // The button names the consequence rather than agreeing to a question.
    expect(find.text('Delete forever'), findsOneWidget);
  });

  testWidgets('it names the audio, which is what people do not expect to lose',
      (tester) async {
    await pumpDetail(tester);
    await openDeleteDialog(tester);

    expect(find.textContaining('The original recording'), findsOneWidget);
  });

  testWidgets('a written memory is not described as having audio', (tester) async {
    await pumpDetail(tester, hasAudio: false);
    await openDeleteDialog(tester);

    expect(find.textContaining('The original recording'), findsNothing);
    expect(find.textContaining('The words you wrote'), findsOneWidget);
  });

  testWidgets('backing out sends nothing', (tester) async {
    await pumpDetail(tester);
    await openDeleteDialog(tester);

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    expect(deleteWasSent(), isFalse);
    expect(find.text('Delete this memory?'), findsNothing);
  });

  testWidgets('confirming deletes it and leaves the screen', (tester) async {
    await pumpDetail(tester);
    await openDeleteDialog(tester);

    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();

    expect(deleteWasSent(), isTrue);
    expect(find.text('Memory deleted.'), findsOneWidget);
    // What the screen was showing no longer exists, so the screen goes too.
    expect(find.byType(MemoryDetailScreen), findsNothing);
  });

  testWidgets('no undo is offered, because there is none', (tester) async {
    await pumpDetail(tester);
    await openDeleteDialog(tester);
    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SnackBar, 'Memory deleted.'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('a failed delete keeps the memory on screen', (tester) async {
    // The list is not updated optimistically, so a row that failed to delete
    // must never look as though it did.
    await pumpDetail(tester, deleteStatus: 500);
    await openDeleteDialog(tester);

    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not delete that memory'), findsOneWidget);
    expect(find.byType(MemoryDetailScreen), findsOneWidget);
    expect(find.text('A ridge walk at sunrise'), findsOneWidget);
  });

  testWidgets('a memory already gone on the server counts as deleted', (tester) async {
    // Two devices, one memory: the second delete must not report an error about
    // something neither of them can see any more.
    await pumpDetail(tester, deleteStatus: 404);
    await openDeleteDialog(tester);

    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();

    expect(find.text('Memory deleted.'), findsOneWidget);
  });
}
