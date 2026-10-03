import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/data/api_client.dart';

/// A memory is recorded on whichever device was to hand and played back on
/// whichever device is to hand later — and the two are often not the same one,
/// now that the web app records too. A phone records m4a and a browser records
/// webm, so the format belongs to the *recording*, and the server is the only
/// thing that knows which is which.
void main() {
  ApiClient serving(String contentType) {
    final mock = MockClient((request) async {
      return http.Response.bytes(
        Uint8List.fromList([1, 2, 3, 4]),
        200,
        headers: contentType.isEmpty ? {} : {'content-type': contentType},
      );
    });
    return ApiClient(client: mock, baseUrl: 'http://test.invalid');
  }

  test('a recording is played as the format the server served it in', () async {
    final audio = await serving('audio/webm').fetchAudio('rec-1');

    expect(audio.bytes, [1, 2, 3, 4]);
    expect(audio.playbackMimeType, 'audio/webm');
  });

  test('a phone recording keeps its own format too', () async {
    final audio = await serving('audio/mp4').fetchAudio('rec-1');
    expect(audio.playbackMimeType, 'audio/mp4');
  });

  test('charset and casing on the header are not part of the format', () async {
    final audio = await serving('Audio/WEBM; codecs=opus').fetchAudio('rec-1');
    expect(audio.playbackMimeType, 'audio/webm');
  });

  test('a response that names no audio type falls back to this platform', () async {
    // Only ever reached by a response with no type, or one from something that
    // is not the API at all — a proxy's error page, say.
    for (final served in ['', 'text/html', 'application/octet-stream']) {
      final audio = await serving(served).fetchAudio('rec-1');
      expect(audio.playbackMimeType, 'audio/mp4', reason: 'served as "$served"');
    }
  });
}
