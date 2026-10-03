import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/auth.dart';
import '../../data/live_voice.dart';
import '../../data/providers.dart';
import '../../widgets/immersive_chrome.dart';

/// Live voice mode — a hands-free conversation with the memory AI, carried end
/// to end by Gemini Live: the microphone streams up as PCM and the model's own
/// voice comes back down the same socket.
///
/// Nothing here is turn-based any more. There is no on-device recognizer to
/// wait for and no text-to-speech voice reading an answer back, which is what
/// makes it work in the languages the memories are actually in — and what lets
/// someone talk over the answer and be heard.
///
/// No chat bubbles: just an audio-reactive splash that reflects listening /
/// thinking / speaking, with the model's own words underneath so a mis-heard
/// question is visible rather than merely disappointing.
class VoiceModeScreen extends ConsumerStatefulWidget {
  const VoiceModeScreen({super.key});

  @override
  ConsumerState<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends ConsumerState<VoiceModeScreen> {
  late final LiveVoiceSession _voice;

  @override
  void initState() {
    super.initState();
    _voice = LiveVoiceSession(
      ref.read(liveTokenProvider),
      // A call opened while Recall is scoped to one journal stays scoped to it,
      // exactly as a typed question would.
      journalId: ref.read(recallScopeProvider),
    );
    _voice.addListener(_onVoice);
    _voice.start();
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoice);
    _voice.dispose();
    super.dispose();
  }

  void _onVoice() {
    if (mounted) setState(() {});
  }

  Future<void> _end() async {
    await _voice.stop();
    if (mounted) Navigator.of(context).maybePop();
  }

  String get _label => switch (_voice.phase) {
        VoicePhase.connecting => 'Connecting…',
        VoicePhase.listening => _voice.muted ? 'Muted' : 'Listening…',
        VoicePhase.thinking => 'Recalling…',
        VoicePhase.speaking => 'Speaking…',
        VoicePhase.unavailable => 'Voice unavailable',
        VoicePhase.timeUp => 'Time’s up',
      };

  /// The line under the splash: what is being said, when there is something.
  String get _caption {
    if (_voice.phase == VoicePhase.timeUp) {
      return 'This conversation reached its ${_minutes(_voice.limit)} limit. '
          'Start another whenever you like.';
    }
    if (_voice.phase == VoicePhase.unavailable) return _voice.unavailableReason;
    if (_voice.phase == VoicePhase.speaking && _voice.spoken.isNotEmpty) {
      return _voice.spoken;
    }
    if (_voice.phase == VoicePhase.thinking && _voice.heard.isNotEmpty) {
      return '“${_voice.heard}”';
    }
    // Said last, so a live transcript still wins: the mic can be off while the
    // answer is still playing, and the words are the more useful line then.
    if (_voice.muted) return 'Microphone off. Tap the mic when you want to talk.';
    return 'Speak naturally — ask anything about your memories.';
  }

  /// "1 hour" / "10 minute", read as an adjective ("its 10 minute limit"), so a
  /// whole number of hours is said in hours rather than as 60 minutes.
  static String _minutes(Duration d) {
    final m = d.inMinutes;
    if (m >= 60 && m % 60 == 0) {
      final h = m ~/ 60;
      return h == 1 ? '1 hour' : '$h hours';
    }
    return '$m minute';
  }

  @override
  Widget build(BuildContext context) {
    return ImmersiveChrome(
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.35),
              radius: 1.2,
              colors: [AppColors.immersiveTop, AppColors.immersiveBottom],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: _end,
                  ),
                ),
                const Spacer(),
                _VoiceSplash(
                  phase: _voice.phase,
                  level: _voice.level,
                  muted: _voice.muted,
                ),
                const SizedBox(height: Insets.xxl),
                Text(
                  _label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                ),
                if (_voice.isTimed && _voice.phase != VoicePhase.timeUp) ...[
                  const SizedBox(height: 6),
                  _RemainingClock(remaining: _voice.remaining),
                ],
                const SizedBox(height: Insets.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
                  child: Text(
                    _caption,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xxl),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Nothing left to mute once the call is over, but the slot
                      // stays so the end button does not jump sideways.
                      Opacity(
                        opacity: _voice.isLive ? 1 : 0,
                        child: IgnorePointer(
                          ignoring: !_voice.isLive,
                          child: _MuteButton(
                            muted: _voice.muted,
                            onTap: _voice.toggleMute,
                          ),
                        ),
                      ),
                      const SizedBox(width: Insets.xl),
                      // Once the server has hung up there is nothing left to end,
                      // so the red button becomes the way out rather than a
                      // second one.
                      _EndButton(
                        onTap: _end,
                        ended: _voice.phase == VoicePhase.timeUp,
                      ),
                      // Balances the mute button so the end button stays on the
                      // screen's centre line, where a thumb expects it.
                      const SizedBox(width: _MuteButton.size + Insets.xl),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Audio-reactive splash: concentric rings that swell with the mic level while
/// listening, a steady glow while thinking/speaking.
class _VoiceSplash extends StatelessWidget {
  const _VoiceSplash({
    required this.phase,
    required this.level,
    this.muted = false,
  });
  final VoicePhase phase;
  final double level;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final listening = phase == VoicePhase.listening;
    // A muted mic hears nothing, so the rings sit still rather than resting at
    // the steady glow that means "working".
    final reactive = listening ? level : (muted ? 0.0 : 0.35);
    const base = 150.0;
    return SizedBox(
      width: 300,
      height: 300,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: base + reactive * 130,
            height: base + reactive * 130,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.sage.withValues(alpha: 0.10),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: base + reactive * 70,
            height: base + reactive * 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.sage.withValues(alpha: 0.18),
            ),
          ),
          Container(
            width: base,
            height: base,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                center: Alignment(-0.3, -0.4),
                radius: 0.95,
                colors: [AppColors.sageMist, AppColors.sage, AppColors.sageDeep],
                stops: [0.0, 0.55, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.sage.withValues(alpha: 0.55),
                  blurRadius: 50,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Icon(
              switch (phase) {
                VoicePhase.speaking => Icons.volume_up_rounded,
                VoicePhase.thinking => Icons.auto_awesome,
                VoicePhase.unavailable => Icons.mic_off_rounded,
                VoicePhase.listening when muted => Icons.mic_off_rounded,
                // An hourglass, not a crossed-out mic: the call ended because it
                // ran its course, which is a different thing from a failure.
                VoicePhase.timeUp => Icons.hourglass_bottom_rounded,
                _ => Icons.mic_rounded,
              },
              color: Colors.white,
              size: 48,
            ),
          ),
          if (phase == VoicePhase.thinking)
            const SizedBox(
              width: base + 24,
              height: base + 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white24),
              ),
            ),
        ],
      ),
    );
  }
}

/// Time left in this conversation. A clock rather than a bar: someone deciding
/// whether to ask one more question needs the number, not a proportion.
class _RemainingClock extends StatelessWidget {
  const _RemainingClock({required this.remaining});
  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final seconds = remaining.inSeconds;
    // Amber for the last minute. Red would read as a fault, and running out of
    // time you were told you had is not one.
    final low = seconds <= 60;
    final label = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} left';
    return Semantics(
      liveRegion: low,
      child: Text(
        label,
        style: TextStyle(
          color: low ? const Color(0xFFF5C46B) : Colors.white38,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Holds the microphone back while the answer plays, so a noisy room does not
/// count as talking over it. Sits beside the end button because the two are the
/// only things there is to do during a call.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});
  final bool muted;
  final VoidCallback onTap;

  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: muted,
      label: muted ? 'Unmute the microphone' : 'Mute the microphone',
      child: Material(
        color: muted
            ? Colors.white.withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.16),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              // Inverted while muted: at a glance, the filled button is the one
              // that is doing something to the call.
              color: muted ? AppColors.immersiveBottom : Colors.white,
              size: 26,
            ),
          ),
        ),
      ),
    );
  }
}

class _EndButton extends StatelessWidget {
  const _EndButton({required this.onTap, this.ended = false});
  final VoidCallback onTap;

  /// The call is already over; this is now "close the screen".
  final bool ended;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: ended ? 'Close' : 'End the conversation',
      child: Material(
        color: ended ? Colors.white.withValues(alpha: 0.16) : const Color(0xFFE5484D),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const SizedBox(
            width: 64,
            height: 64,
            child: Icon(Icons.close_rounded, color: Colors.white, size: 30),
          ),
        ),
      ),
    );
  }
}
