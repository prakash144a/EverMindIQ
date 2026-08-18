import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/config.dart';
import '../../core/tokens.dart';
import '../../data/ai_conversation.dart';
import '../../data/auth.dart';
import '../../widgets/immersive_chrome.dart';

/// Live voice mode — a hands-free, streaming-style conversation with the memory
/// AI. Opening it starts listening; you speak, it recalls, and the answer is
/// read back aloud, then it listens again. No transcript or chat bubbles: just
/// an audio-reactive splash that reflects listening / thinking / speaking.
///
/// This is turn-based on top of the existing `/live` retrieval + on-device
/// speech; native full-duplex Gemini Live audio is a later, deeper transport.
class VoiceModeScreen extends ConsumerStatefulWidget {
  const VoiceModeScreen({super.key});

  @override
  ConsumerState<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

enum _Phase { connecting, listening, thinking, speaking, error }

class _VoiceModeScreenState extends ConsumerState<VoiceModeScreen> {
  late final AiConversation _ai;
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  _Phase _phase = _Phase.connecting;
  bool _active = true;
  bool _awaitingReply = false;
  bool _speechReady = false;
  double _level = 0; // mic sound level while listening
  int _aiSeen = 0;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(firebaseAuthProvider);
    _ai = AiConversation(() async =>
        await auth.currentUser?.getIdToken() ?? AppConfig.devUid);
    _ai.addListener(_onAi);
    _ai.connect();
    _initTts();
    _boot();
  }

  @override
  void dispose() {
    _active = false;
    _ai.removeListener(_onAi);
    _ai.dispose();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    _tts.setCompletionHandler(() {
      // Finished speaking the answer → listen again.
      if (_active) _startListening();
    });
    _tts.setCancelHandler(() {
      if (_active && _phase == _Phase.speaking) _startListening();
    });
    _tts.setErrorHandler((_) {
      if (_active) _startListening();
    });
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {/* best effort */}
  }

  Future<void> _boot() async {
    try {
      _speechReady = await _speech.initialize(
        onStatus: (_) {
          if (mounted) setState(() {});
        },
        onError: (_) {
          if (_active) _startListening();
        },
      );
    } catch (_) {
      _speechReady = false;
    }
    if (!mounted) return;
    if (!_speechReady) {
      setState(() => _phase = _Phase.error);
      return;
    }
    _startListening();
  }

  void _onAi() {
    final aiCount = _ai.messages.where((m) => !m.fromUser).length;
    if (aiCount > _aiSeen) {
      _aiSeen = aiCount;
      if (_awaitingReply && !_ai.thinking) {
        _awaitingReply = false;
        final reply = _ai.messages.lastWhere((m) => !m.fromUser).text;
        _speak(reply);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _startListening() async {
    if (!_active) return;
    try {
      await _speech.stop();
    } catch (_) {}
    if (!_active || !mounted) return;
    setState(() {
      _phase = _Phase.listening;
      _level = 0;
    });
    try {
      await _speech.listen(
        onResult: _onResult,
        onSoundLevelChange: (l) {
          if (mounted) setState(() => _level = l);
        },
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: stt.ListenMode.dictation,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  void _onResult(SpeechRecognitionResult r) {
    if (!r.finalResult) return;
    final text = r.recognizedWords.trim();
    if (text.isEmpty) {
      // Heard nothing usable — keep waiting.
      if (_active) _startListening();
      return;
    }
    setState(() {
      _phase = _Phase.thinking;
      _awaitingReply = true;
    });
    _ai.send(text);
  }

  Future<void> _speak(String text) async {
    if (!_active) return;
    setState(() => _phase = _Phase.speaking);
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      if (_active) _startListening();
    }
  }

  Future<void> _end() async {
    _active = false;
    try {
      await _speech.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
    if (mounted) Navigator.of(context).maybePop();
  }

  String get _label => switch (_phase) {
        _Phase.connecting => 'Connecting…',
        _Phase.listening => 'Listening…',
        _Phase.thinking => 'Recalling…',
        _Phase.speaking => 'Speaking…',
        _Phase.error => 'Voice unavailable',
      };

  @override
  Widget build(BuildContext context) {
    // Normalize the mic level (~ -2..10 on Android) into 0..1 for the splash.
    final norm = ((_level + 2) / 12).clamp(0.0, 1.0);
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
                _VoiceSplash(phase: _phase, level: norm),
                const SizedBox(height: Insets.xxl),
                Text(
                  _label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: Insets.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
                  child: Text(
                    _phase == _Phase.error
                        ? "This device has no speech recognizer. Go back and type instead."
                        : 'Speak naturally — ask anything about your memories.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xxl),
                  child: _EndButton(onTap: _end),
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
  const _VoiceSplash({required this.phase, required this.level});
  final _Phase phase;
  final double level;

  @override
  Widget build(BuildContext context) {
    final listening = phase == _Phase.listening;
    final reactive = listening ? level : 0.35;
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
                _Phase.speaking => Icons.volume_up_rounded,
                _Phase.thinking => Icons.auto_awesome,
                _Phase.error => Icons.mic_off_rounded,
                _ => Icons.mic_rounded,
              },
              color: Colors.white,
              size: 48,
            ),
          ),
          if (phase == _Phase.thinking)
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

class _EndButton extends StatelessWidget {
  const _EndButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFE5484D),
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
    );
  }
}
