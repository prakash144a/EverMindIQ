import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/core/device_identity.dart';
import 'package:voiceiq/src/data/api_client.dart';

/// The install id identifies one installation so the backend can tell that two
/// accounts share a phone. It rides on the headers of requests the app already
/// makes, so what matters is that it is actually attached to every one.
void main() {
  late List<http.BaseRequest> sent;

  ApiClient clientRecording() {
    sent = [];
    final mock = MockClient((request) async {
      sent.add(request);
      return http.Response(jsonEncode([]), 200);
    });
    return ApiClient(client: mock, baseUrl: 'http://test.invalid');
  }

  setUp(() => DeviceIdentity.setForTesting('install-abc'));
  tearDown(() => DeviceIdentity.setForTesting(''));

  test('every request carries the install id, platform and app version', () async {
    await clientRecording().listRecordings();

    expect(sent.single.headers['X-Install-Id'], 'install-abc');
    expect(sent.single.headers['X-Platform'], isNotEmpty);
    expect(sent.single.headers['X-App-Version'], isNotEmpty);
  });

  test('the header is omitted rather than sent empty when unknown', () async {
    // Storage can be unavailable — on web, or on a device with no writable
    // support directory. The request must still go through.
    DeviceIdentity.setForTesting('');

    await clientRecording().listRecordings();

    expect(sent.single.headers.containsKey('X-Install-Id'), isFalse);
    expect(sent.single.headers['Authorization'], isNotNull);
  });

  test('generated ids are random and hex', () async {
    // Reaches the fallback path: no writable directory is bound in a unit test,
    // so `ensure` returns a freshly generated value rather than throwing.
    DeviceIdentity.setForTesting('');
    final first = await DeviceIdentity.ensure();
    DeviceIdentity.setForTesting('');
    final second = await DeviceIdentity.ensure();

    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(first, isNot(second));
  });

  test('a resolved id is reused rather than regenerated', () async {
    DeviceIdentity.setForTesting('already-set');
    expect(await DeviceIdentity.ensure(), 'already-set');
  });
}
