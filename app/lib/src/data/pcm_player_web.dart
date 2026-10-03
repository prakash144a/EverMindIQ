import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// The browser [PcmPlayer]: Web Audio, scheduling each chunk of the model's
/// voice directly onto the audio clock. See `pcm_player.dart` for the contract.
///
/// There is no queue to hand the chunks to, so this keeps one: `_playhead` is
/// the context time at which the next chunk should start, and every chunk is
/// scheduled at exactly that instant and moves it along by its own duration.
/// Playing chunks back to back matters more than it sounds — starting each one
/// "now" would leave a seam between every 20 milliseconds of speech, and the
/// answer would arrive as a stutter.
class PcmPlayer {
  /// How far ahead of the clock to start after running dry. Scheduling exactly
  /// at `currentTime` is scheduling in the past by the time the browser acts on
  /// it, which it resolves by playing the chunk late — and then the next one is
  /// late too. A few milliseconds of slack absorbs that without being audible.
  static const _leadIn = 0.05;

  web.AudioContext? _context;
  int _sampleRate = 24000;
  int _thresholdFrames = 0;
  double _playhead = 0;

  void Function(int framesRemaining)? _needsMore;
  Timer? _poll;

  /// Still-scheduled chunks, kept only so [release] can cut them off. Nothing
  /// else stops them: a source node that has been started plays to its end
  /// whether or not anything still refers to it.
  final List<web.AudioBufferSourceNode> _scheduled = [];

  void onNeedsMore(void Function(int framesRemaining) callback) => _needsMore = callback;

  Future<void> setup({required int sampleRate, required int feedThresholdFrames}) async {
    _sampleRate = sampleRate;
    _thresholdFrames = feedThresholdFrames;
    _context = _openContext(sampleRate);
    // A context created while the page has not been interacted with starts
    // suspended. Voice mode is opened by a tap, so this ordinarily resolves at
    // once; awaiting it means the first chunk is not scheduled onto a clock
    // that is not running yet.
    try {
      await _context!.resume().toDart;
    } catch (_) {/* already running, or the browser will start it on the first sound */}
    _playhead = _context!.currentTime;

    // The native plugin asks for more audio from inside its own callback. Here
    // nothing calls us, so the asking is driven from a timer: every tick that
    // finds the queue short says so. A tenth of the threshold's worth of time
    // is frequent enough to refill smoothly and far too slow to be a cost.
    final period = math.max(20, (feedThresholdFrames / sampleRate * 1000 / 10).round());
    _poll = Timer.periodic(Duration(milliseconds: period), (_) => _askIfShort());
  }

  /// A context at the model's own rate when the browser will give us one, so
  /// nothing has to be resampled. If it refuses — some browsers only allow
  /// their hardware rate — a default context still plays the audio correctly,
  /// because an `AudioBuffer` that disagrees with its context is resampled on
  /// the way out.
  web.AudioContext _openContext(int sampleRate) {
    try {
      return web.AudioContext(web.AudioContextOptions(sampleRate: sampleRate));
    } catch (_) {
      return web.AudioContext();
    }
  }

  Future<void> feed(Uint8List pcm) async {
    final context = _context;
    if (context == null || pcm.lengthInBytes < 2) return;

    // Int16 little-endian, which is what both Gemini Live and the microphone
    // deal in, scaled to the -1..1 floats Web Audio wants. `asInt16List` needs
    // an even offset into the backing store and the chunk may be a view onto a
    // socket frame, so read through a ByteData rather than assuming alignment.
    final view = ByteData.sublistView(pcm);
    final frames = pcm.lengthInBytes ~/ 2;
    final samples = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final buffer = context.createBuffer(1, frames, _sampleRate);
    buffer.copyToChannel(samples.toJS, 0);

    final source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);

    // Behind the clock means the speaker ran dry while this chunk was in
    // flight; there is no catching up, so start afresh rather than scheduling
    // into the past and playing everything late from here on.
    final now = context.currentTime;
    final startAt = _playhead > now ? _playhead : now + _leadIn;
    source.start(startAt);
    _playhead = startAt + frames / _sampleRate;

    _scheduled.add(source);
    source.onended = ((web.Event _) {
      _scheduled.remove(source);
    }).toJS;
  }

  /// Frames still ahead of the clock. Zero means the speaker has run dry, which
  /// is the caller's signal that a spoken turn has finished playing.
  int _framesQueued() {
    final context = _context;
    if (context == null) return 0;
    final ahead = _playhead - context.currentTime;
    return ahead <= 0 ? 0 : (ahead * _sampleRate).round();
  }

  void _askIfShort() {
    final needsMore = _needsMore;
    if (needsMore == null || _context == null) return;
    final queued = _framesQueued();
    if (queued <= _thresholdFrames) needsMore(queued);
  }

  Future<void> release() async {
    _poll?.cancel();
    _poll = null;
    _needsMore = null;
    for (final source in _scheduled) {
      try {
        source.stop();
      } catch (_) {/* already finished */}
    }
    _scheduled.clear();
    final context = _context;
    _context = null;
    if (context == null) return;
    try {
      await context.close().toDart;
    } catch (_) {/* best effort: the call is over either way */}
  }
}
