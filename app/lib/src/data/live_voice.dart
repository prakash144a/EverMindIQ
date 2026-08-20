import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config.dart';

/// A spoken conversation with the memory AI, streamed to and from Gemini Live.
///
/// The microphone goes up as raw PCM and Gemini's voice comes back as raw PCM;
/// nothing on the device transcribes or synthesizes anything. That is the point:
/// a phone's speech recognizer and its text-to-speech voice are per-locale, and
/// they were hearing and answering in English for people whose memories are in
/// Tamil or Hindi. One model on the other end of one socket hears and speaks
/// them natively.
///
/// Binary frames are audio, JSON frames are control — the same rule the backend
/// applies in the other direction.
enum VoicePhase {
  /// Opening the socket and the audio devices.
  connecting,

  /// Microphone streaming, nothing being said back.
  listening,

  /// The model has heard a turn and is working on it.
  thinking,

  /// Playing the model's voice.
  speaking,

  /// This backend or device cannot hold a spoken conversation.
  unavailable,

  /// The plan's time for one conversation is up and the server has hung up.
  /// Distinct from [unavailable] because nothing went wrong: the call ran its
  /// full length, and the screen says so rather than apologising.
  timeUp,
}

/// Gemini Live's rates. Not ours to choose — the backend names the same two.
const int _micSampleRate = 16000;
const int _voiceSampleRate = 24000;

/// How much of the model's voice we hand to the speaker at a time. The rest
/// waits in the play queue, where we can still throw it away: the plugin has no
/// way to flush what it has already accepted, so anything fed early is audio we
/// are committed to playing through a barge-in.
const int _maxChunksAhead = 4;

/// Ask for more samples while a fifth of a second is still queued, so the next
/// chunk lands before the current one runs out.
const int _feedThresholdFrames = _voiceSampleRate ~/ 5;

class LiveVoiceSession extends ChangeNotifier {
  LiveVoiceSession(this._tokenFetch, {this.journalId});

  final Future<String?> Function() _tokenFetch;

  /// Scopes every recall in this conversation to one journal, as the Recall
  /// screen's picker does for typed questions.
  final String? journalId;

  final AudioRecorder _recorder = AudioRecorder();
  final Queue<Uint8List> _playQueue = Queue<Uint8List>();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  StreamSubscription<Uint8List>? _micSub;

  VoicePhase phase = VoicePhase.connecting;

  /// Why voice is unavailable, in words a user can act on.
  String unavailableReason = '';

  /// How long this conversation may last, from the server's handshake, and how
  /// much of it is left. The server is the one that hangs up; this exists so the
  /// screen can show the clock instead of the call simply ending.
  Duration limit = Duration.zero;
  Duration remaining = Duration.zero;
  Timer? _countdown;

  bool get isTimed => limit > Duration.zero;

  /// Mic loudness, 0..1, for the splash. Measured from the samples already
  /// being sent, so it costs nothing extra.
  double level = 0;

  /// What the model heard and what it is saying. Kept so a mis-heard question
  /// is diagnosable rather than merely disappointing.
  String heard = '';
  String spoken = '';

  /// Memories the answer drew on, as `Citation` JSON.
  List<Map<String, dynamic>> citations = const [];

  bool _closed = false;
  bool _audioReady = false;
  bool _speakerIdle = true;
  bool _pcmSetUp = false;

  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      _fail('Microphone access is off. Turn it on in Settings to talk.');
      return;
    }
    try {
      final token = await _tokenFetch() ?? AppConfig.devUid;
      final channel = WebSocketChannel.connect(AppConfig.wsLiveUri(token));
      _channel = channel;
      _socketSub = channel.stream.listen(
        _onFrame,
        onDone: () => _fail('The connection closed.'),
        onError: (_) => _fail('Lost the connection.'),
      );
      channel.sink.add(jsonEncode({
        'type': 'audio_start',
        if (journalId != null) 'journal_id': journalId,
      }));
    } catch (_) {
      _fail('Could not reach the server.');
    }
  }

  // ---------------------------------------------------------------- incoming

  void _onFrame(dynamic frame) {
    if (_closed) return;
    if (frame is List<int>) {
      _onVoiceChunk(Uint8List.fromList(frame));
      return;
    }
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(frame as String) as Map<String, dynamic>;
    } catch (_) {
      return; // malformed frame; the stream is still good
    }
    switch (msg['type']) {
      case 'ready':
        // Read before branching: an unavailable backend still told us the budget,
        // and the screen shows it either way.
        final seconds = (msg['limit_sec'] as num?)?.toInt() ?? 0;
        limit = Duration(seconds: seconds);
        remaining = limit;
        if (msg['audio'] == true) {
          unawaited(_openAudio());
        } else {
          // The backend said plainly that it cannot do this. Say so rather than
          // sitting on a listening screen that will never answer.
          _fail(msg['reason'] == 'mock'
              ? 'This build is pointed at the offline backend, which has no voice.'
              : 'Voice is unavailable on this server.');
        }
      case 'input_transcript':
        heard = (msg['text'] as String?) ?? '';
        if (heard.trim().isNotEmpty) phase = VoicePhase.thinking;
        notifyListeners();
      case 'output_transcript':
        spoken = (msg['text'] as String?) ?? '';
        notifyListeners();
      case 'citations':
        citations =
            ((msg['citations'] as List?) ?? const []).cast<Map<String, dynamic>>();
        notifyListeners();
      case 'interrupted':
        // Talked over. Drop everything not yet played; what the speaker already
        // holds is a fraction of a second and drains on its own.
        _playQueue.clear();
        phase = VoicePhase.listening;
        notifyListeners();
      case 'turn_complete':
        if (_playQueue.isEmpty && _speakerIdle) {
          phase = VoicePhase.listening;
          notifyListeners();
        }
      case 'limit_reached':
        // Not routed through `_fail`: the call did not break, it finished. The
        // server has already closed its side, so all that is left is to release
        // the microphone and let the screen say so.
        _playQueue.clear();
        phase = VoicePhase.timeUp;
        remaining = Duration.zero;
        notifyListeners();
        unawaited(_teardown());
      case 'error':
        _fail((msg['message'] as String?) ?? 'Something went wrong.');
    }
  }

  void _onVoiceChunk(Uint8List pcm) {
    _playQueue.add(pcm);
    if (phase != VoicePhase.speaking) {
      phase = VoicePhase.speaking;
      notifyListeners();
    }
    if (_speakerIdle) {
      _speakerIdle = false;
      _feed(0);
    }
  }

  // ---------------------------------------------------------------- outgoing

  Future<void> _openAudio() async {
    try {
      await FlutterPcmSound.setLogLevel(LogLevel.error);
      await FlutterPcmSound.setup(
        sampleRate: _voiceSampleRate,
        channelCount: 1,
      );
      await FlutterPcmSound.setFeedThreshold(_feedThresholdFrames);
      FlutterPcmSound.setFeedCallback(_feed);
      _pcmSetUp = true;

      final mic = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _micSampleRate,
        numChannels: 1,
        // Without echo cancellation the microphone picks the answer back up and
        // the model interrupts itself, mid-sentence, forever.
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ));
      _micSub = mic.listen(_onMicChunk);
      _audioReady = true;
      phase = VoicePhase.listening;
      _startCountdown();
      notifyListeners();
    } catch (_) {
      _fail('This device would not start the microphone.');
    }
  }

  /// Tick the displayed clock down. Purely cosmetic — the server owns the actual
  /// hang-up, so this never has to be trusted, only roughly in step. It floors at
  /// zero and waits for `limit_reached` rather than closing the call itself.
  void _startCountdown() {
    if (!isTimed) return;
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed) return;
      final left = remaining - const Duration(seconds: 1);
      remaining = left.isNegative ? Duration.zero : left;
      notifyListeners();
    });
  }

  void _onMicChunk(Uint8List pcm) {
    if (_closed || _channel == null) return;
    _channel!.sink.add(pcm);
    final loudness = _rms(pcm);
    if ((loudness - level).abs() > 0.02) {
      level = loudness;
      notifyListeners();
    }
  }

  /// Hand the speaker more of the model's voice, shallowly.
  void _feed(int remainingFrames) {
    if (_closed || !_pcmSetUp) return;
    var fed = 0;
    while (_playQueue.isNotEmpty && fed < _maxChunksAhead) {
      final chunk = _playQueue.removeFirst();
      // The plugin sends `bytes.buffer` wholesale, ignoring any view offset, so
      // the ByteData must own its backing store exactly. A copy guarantees it.
      final owned = Uint8List.fromList(chunk);
      unawaited(FlutterPcmSound.feed(PcmArrayInt16(bytes: owned.buffer.asByteData())));
      fed++;
    }
    if (fed == 0 && remainingFrames == 0) {
      // Nothing queued and nothing playing: the turn is over.
      _speakerIdle = true;
      if (phase == VoicePhase.speaking) {
        phase = VoicePhase.listening;
        notifyListeners();
      }
    }
  }

  static double _rms(Uint8List pcm) {
    if (pcm.lengthInBytes < 2) return 0;
    final samples = pcm.buffer.asInt16List(
      pcm.offsetInBytes,
      pcm.lengthInBytes ~/ 2,
    );
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    final rms = math.sqrt(sum / samples.length) / 32768;
    // Speech sits low on a linear scale; a square root opens up the quiet end
    // so the splash moves with an ordinary speaking voice.
    return math.sqrt(rms).clamp(0.0, 1.0);
  }

  void _fail(String reason) {
    if (_closed || phase == VoicePhase.unavailable) return;
    unavailableReason = reason;
    phase = VoicePhase.unavailable;
    notifyListeners();
    unawaited(_teardown());
  }

  /// Ends the call and releases the microphone and speaker.
  Future<void> stop() async {
    if (_closed) return;
    try {
      _channel?.sink.add(jsonEncode({'type': 'audio_end'}));
    } catch (_) {/* already gone */}
    await _teardown();
  }

  Future<void> _teardown() async {
    if (_closed) return;
    _closed = true;
    _countdown?.cancel();
    _countdown = null;
    _playQueue.clear();
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {/* best effort */}
    if (_pcmSetUp) {
      FlutterPcmSound.setFeedCallback(null);
      try {
        await FlutterPcmSound.release();
      } catch (_) {/* best effort */}
      _pcmSetUp = false;
    }
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {/* already gone */}
    _channel = null;
    _audioReady = false;
  }

  /// Whether audio is actually flowing, for the screen to reflect.
  bool get isLive => _audioReady && !_closed;

  @override
  void dispose() {
    unawaited(_teardown());
    _recorder.dispose();
    super.dispose();
  }
}
