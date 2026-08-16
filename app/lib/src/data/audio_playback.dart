import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Which recording (if any) the single app-wide player is currently holding.
class PlaybackState {
  const PlaybackState({
    this.recordingId,
    this.playing = false,
    this.loading = false,
    this.errorAt,
  });

  /// Id of the recording loaded into the player, or being fetched for it.
  final String? recordingId;
  final bool playing;
  final bool loading;

  /// Bumped whenever playback fails, so listeners can show a message once.
  final DateTime? errorAt;

  PlaybackState copyWith({
    String? recordingId,
    bool clearRecordingId = false,
    bool? playing,
    bool? loading,
    DateTime? errorAt,
  }) =>
      PlaybackState(
        recordingId: clearRecordingId ? null : (recordingId ?? this.recordingId),
        playing: playing ?? this.playing,
        loading: loading ?? this.loading,
        errorAt: errorAt ?? this.errorAt,
      );
}

/// Owns the one and only [AudioPlayer] in the app.
///
/// Having a single player is what guarantees the two behaviours the list needs:
/// starting a recording implicitly stops whatever was playing, and the bytes in
/// the player always belong to [PlaybackState.recordingId] — a row can never
/// play another row's audio, because nothing is cached per-widget.
class AudioPlaybackController extends Notifier<PlaybackState> {
  final _player = AudioPlayer();
  StreamSubscription<PlayerState>? _sub;

  /// Id whose bytes are actually loaded in [_player] (null while empty).
  String? _loadedId;

  /// Id of the most recent [toggle] request; used to drop stale fetches.
  String? _requestedId;

  @override
  PlaybackState build() {
    // Keep the source loaded when a memo finishes so tapping it again replays
    // it from the start instead of silently doing nothing.
    _player.setReleaseMode(ReleaseMode.stop);
    _sub = _player.onPlayerStateChanged.listen((s) {
      if (s == PlayerState.completed) {
        // Keep _loadedId so re-tapping replays without another fetch.
        state = state.copyWith(playing: false);
      } else {
        state = state.copyWith(playing: s == PlayerState.playing);
      }
    });
    ref.onDispose(() {
      _sub?.cancel();
      _player.dispose();
    });
    return const PlaybackState();
  }

  /// Play [recordingId], pausing/resuming if it is already the loaded one.
  Future<void> toggle(String recordingId) async {
    if (recordingId == _loadedId) {
      if (state.playing) {
        await _player.pause();
      } else {
        await _player.resume();
      }
      return;
    }

    // A different recording: tear down the current one first so the two can
    // never overlap, then fetch fresh bytes for the requested id.
    _requestedId = recordingId;
    await _player.stop();
    _loadedId = null;
    state = state.copyWith(recordingId: recordingId, playing: false, loading: true);

    try {
      final bytes = await ref.read(apiClientProvider).fetchAudioBytes(recordingId);
      if (_requestedId != recordingId) return; // superseded by a later tap
      if (bytes.isEmpty) throw Exception('no audio yet');
      await _player.play(BytesSource(bytes, mimeType: kIsWeb ? 'audio/webm' : 'audio/mp4'));
      if (_requestedId != recordingId) return;
      _loadedId = recordingId;
      state = state.copyWith(loading: false);
    } catch (_) {
      if (_requestedId != recordingId) return;
      _loadedId = null;
      // Keep the id on the state so only the tapped button reports the failure.
      state = PlaybackState(recordingId: recordingId, errorAt: DateTime.now());
    }
  }

  /// Stop playback entirely (e.g. before opening the record screen).
  Future<void> stop() async {
    _requestedId = null;
    _loadedId = null;
    await _player.stop();
    state = const PlaybackState();
  }
}

final audioPlaybackProvider =
    NotifierProvider<AudioPlaybackController, PlaybackState>(AudioPlaybackController.new);
