import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/providers.dart';

/// Ingestion is asynchronous on the backend, so a new recording first appears
/// with `status: uploaded` and no title. These tests cover the notifier that
/// re-fetches until the transcript lands, so the row updates on its own.
void main() {
  Map<String, dynamic> rec(String status, String title) => {
        'id': 'r1',
        'event_date': '2025-08-16',
        'recorded_at': DateTime.now().toUtc().toIso8601String(),
        'status': status,
        'title': title,
      };

  ProviderContainer containerServing(List<Map<String, dynamic>> Function() next) {
    final client = MockClient((_) async => http.Response(jsonEncode(next()), 200));
    final container = ProviderContainer(
      overrides: [
        apiClientProvider
            .overrideWithValue(ApiClient(client: client, baseUrl: 'http://test.invalid')),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('keeps polling until the transcript arrives, then stops', () async {
    var calls = 0;
    final container = containerServing(() {
      calls++;
      return [calls == 1 ? rec('uploaded', '') : rec('indexed', 'Fishing trip with Dad')];
    });

    final first = await container.read(recordingsProvider.future);
    expect(first.single.status, 'uploaded');
    expect(first.single.title, isEmpty, reason: 'title is not ready yet');

    // One poll interval (5s) later the row should have refreshed itself.
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(container.read(recordingsProvider).value!.single.title, 'Fishing trip with Dad');

    // Now that nothing is processing, polling must stop.
    final settled = calls;
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(calls, settled, reason: 'no further fetches once everything is indexed');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('does not poll when every recording is already indexed', () async {
    var calls = 0;
    final container = containerServing(() {
      calls++;
      return [rec('indexed', 'Fishing trip with Dad')];
    });

    await container.read(recordingsProvider.future);
    expect(calls, 1);
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(calls, 1);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
