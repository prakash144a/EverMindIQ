import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/tokens.dart';
import '../../data/providers.dart';
import '../../widgets/formatting.dart';
import '../../widgets/waveform.dart';

/// Immersive full-screen capture. Defaults to now; the date chip back-dates it.
/// Pops `true` after a successful save so the shell can refresh the feed.
class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

enum _Phase { idle, recording, saving }

class _RecordScreenState extends ConsumerState<RecordScreen> {
  final _recorder = AudioRecorder();
  _Phase _phase = _Phase.idle;
  DateTime _eventDate = DateTime.now();
  DateTime? _startedAt;
  String? _error;

  StreamSubscription<Amplitude>? _ampSub;
  final List<double> _amps = [];
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void dispose() {
    _ampSub?.cancel();
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await _recorder.hasPermission()) {
        setState(() =>
            _error = 'Microphone permission denied. Allow mic access and try again.');
        return;
      }
      const config = RecordConfig(
        encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc,
      );
      String path = '';
      if (!kIsWeb) {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/voiceiq_${DateTime.now().millisecondsSinceEpoch}.m4a';
      }
      await _recorder.start(config, path: path);
      _amps.clear();
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen(_onAmplitude);
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed = DateTime.now().difference(_startedAt!));
      });
      setState(() => _phase = _Phase.recording);
    } catch (e) {
      setState(() => _error = 'Could not start recording: $e');
    }
  }

  void _onAmplitude(Amplitude amp) {
    // `current` is dBFS (roughly -45 silence .. 0 loud). Normalize to 0..1.
    final norm = ((amp.current + 45) / 45).clamp(0.0, 1.0);
    if (mounted) {
      setState(() {
        _amps.add(norm);
        if (_amps.length > 64) _amps.removeAt(0);
      });
    }
  }

  Future<void> _stopAndSave() async {
    _ampSub?.cancel();
    _ticker?.cancel();
    final source = await _recorder.stop();
    if (source == null) {
      setState(() => _phase = _Phase.idle);
      return;
    }
    setState(() => _phase = _Phase.saving);
    try {
      final bytes = kIsWeb
          ? await http.readBytes(Uri.parse(source))
          : await File(source).readAsBytes();
      final duration = _startedAt == null
          ? 0.0
          : DateTime.now().difference(_startedAt!).inMilliseconds / 1000.0;
      await ref.read(apiClientProvider).uploadAndCreate(
            audioBytes: bytes,
            contentType: kIsWeb ? 'audio/webm' : 'audio/m4a',
            durationSec: duration,
            eventDate: _isToday(_eventDate) ? null : _eventDate,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _phase = _Phase.idle;
        _error = 'Could not save: $e';
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _eventDate,
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
      helpText: 'When did this happen?',
    );
    if (picked != null) setState(() => _eventDate = picked);
  }

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  String get _elapsedLabel {
    final m = _elapsed.inMinutes;
    final s = _elapsed.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final recording = _phase == _Phase.recording;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.5),
            radius: 1.1,
            colors: [Color(0xFF241C4A), Color(0xFF0F0B1E)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: _phase == _Phase.saving
                      ? null
                      : () => Navigator.of(context).maybePop(),
                ),
              ),
              const Spacer(),
              _DateChip(
                label: _isToday(_eventDate) ? 'Today · tap to back-date' : prettyDateTime(_eventDate),
                onTap: _phase == _Phase.idle ? _pickDate : null,
              ),
              const SizedBox(height: Insets.sm),
              _MicButton(
                phase: _phase,
                onTap: switch (_phase) {
                  _Phase.idle => () => _start(),
                  _Phase.recording => () => _stopAndSave(),
                  _Phase.saving => null,
                },
              ),
              // The second, deliberate tap needs its own affordance: opening the
              // screen must never be mistaken for having started the capture.
              _ActionHint(phase: _phase),
              const SizedBox(height: Insets.lg),
              if (recording)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
                  child: WaveformView(amplitudes: _amps),
                ),
              const SizedBox(height: Insets.lg),
              Text(
                switch (_phase) {
                  _Phase.idle => 'Ready when you are',
                  _Phase.recording => 'Recording… $_elapsedLabel',
                  _Phase.saving => 'Saving & indexing…',
                },
                style: const TextStyle(
                    color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: Insets.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
                child: Text(
                  switch (_phase) {
                    _Phase.idle =>
                      'Nothing is being recorded yet. Tap the mic above to begin, '
                          'then speak naturally in any language.',
                    _Phase.recording => 'Speak naturally in any language. Tap to stop & save.',
                    _Phase.saving => 'Hang tight while we file this memory away.',
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 12.5),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Insets.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFFF9E9E)),
                  ),
                ),
              ],
              const Spacer(),
              if (_phase == _Phase.saving)
                const Padding(
                  padding: EdgeInsets.only(bottom: Insets.xxl),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70),
                  ),
                )
              else
                const SizedBox(height: Insets.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.event, color: Colors.white70, size: 16),
              const SizedBox(width: Insets.sm),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Spells out what the next tap does, so the deliberate second tap is never a
/// guess. Idle also pairs with the pulsing ring on the mic itself.
class _ActionHint extends StatelessWidget {
  const _ActionHint({required this.phase});
  final _Phase phase;

  @override
  Widget build(BuildContext context) {
    if (phase == _Phase.saving) return const SizedBox(height: 32);
    final idle = phase == _Phase.idle;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: idle ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: Colors.white.withValues(alpha: idle ? 0.35 : 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(idle ? Icons.touch_app_rounded : Icons.stop_circle_outlined,
              color: Colors.white, size: 16),
          const SizedBox(width: Insets.sm),
          Text(
            idle ? 'Tap the mic to start recording' : 'Tap to stop & save',
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _MicButton extends StatefulWidget {
  const _MicButton({required this.phase, required this.onTap});
  final _Phase phase;
  final VoidCallback? onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.phase == _Phase.idle) _pulse.repeat();
  }

  @override
  void didUpdateWidget(_MicButton old) {
    super.didUpdateWidget(old);
    if (widget.phase == _Phase.idle) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recording = widget.phase == _Phase.recording;
    final idle = widget.phase == _Phase.idle;
    return Semantics(
      button: true,
      label: switch (widget.phase) {
        _Phase.idle => 'Start recording',
        _Phase.recording => 'Stop and save recording',
        _Phase.saving => 'Saving recording',
      },
      child: SizedBox(
        width: 172,
        height: 172,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (idle)
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) {
                  final t = _pulse.value;
                  return Container(
                    width: 108 + 64 * t,
                    height: 108 + 64 * t,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.45 * (1 - t)),
                        width: 2,
                      ),
                    ),
                  );
                },
              ),
            GestureDetector(
              onTap: widget.onTap,
              child: Container(
                width: 108,
                height: 108,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: recording
                      ? const LinearGradient(colors: [Color(0xFFE5484D), Color(0xFFB4353A)])
                      : AppColors.heroWash,
                  boxShadow: [
                    BoxShadow(
                      color: (recording ? const Color(0xFFE5484D) : AppColors.violet)
                          .withValues(alpha: 0.55),
                      blurRadius: 40,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Icon(
                  recording ? Icons.stop_rounded : Icons.mic,
                  color: Colors.white,
                  size: 44,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
