import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// The native [PcmPlayer]: `flutter_pcm_sound`, which is what this app has
/// always used on a phone. See `pcm_player.dart` for the contract.
class PcmPlayer {
  void Function(int framesRemaining)? _needsMore;
  bool _open = false;

  void onNeedsMore(void Function(int framesRemaining) callback) => _needsMore = callback;

  Future<void> setup({required int sampleRate, required int feedThresholdFrames}) async {
    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    await FlutterPcmSound.setFeedThreshold(feedThresholdFrames);
    FlutterPcmSound.setFeedCallback((remaining) => _needsMore?.call(remaining));
    _open = true;
  }

  Future<void> feed(Uint8List pcm) async {
    if (!_open) return;
    // The plugin sends `bytes.buffer` wholesale, ignoring any view offset, so
    // the ByteData must own its backing store exactly. A copy guarantees it.
    final owned = Uint8List.fromList(pcm);
    await FlutterPcmSound.feed(PcmArrayInt16(bytes: owned.buffer.asByteData()));
  }

  Future<void> release() async {
    if (!_open) return;
    _open = false;
    FlutterPcmSound.setFeedCallback(null);
    try {
      await FlutterPcmSound.release();
    } catch (_) {/* best effort: the call is over either way */}
  }
}
