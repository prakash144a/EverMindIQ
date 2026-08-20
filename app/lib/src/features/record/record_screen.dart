import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/tokens.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/immersive_chrome.dart';
import '../../widgets/formatting.dart';
import '../../widgets/journal_picker.dart';
import '../../widgets/waveform.dart';

/// Immersive full-screen capture. Defaults to now; the date chip back-dates it.
/// Pops `true` after a successful save so the shell can refresh the feed.
///
/// Two ways in, one screen: **Write** takes typed text, **Speak** records audio.
/// They share the date chip, the phases, and the save contract — only the middle
/// of the screen differs. Write is the default because the moment a memory is
/// worth keeping is often a moment you cannot say it out loud; speaking is a
/// deliberate choice, made from the switch at the top.
class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

enum _Phase { idle, recording, saving }

enum _Mode { voice, text }

class _RecordScreenState extends ConsumerState<RecordScreen> {
  final _recorder = AudioRecorder();
  _Phase _phase = _Phase.idle;
  _Mode _mode = _Mode.text;
  DateTime _eventDate = DateTime.now();

  /// Which journal to file this into; empty means unfiled. Filing is manual, so
  /// the default is deliberately "nowhere" rather than a guess.
  String _journalId = '';
  DateTime? _startedAt;
  String? _error;

  StreamSubscription<Amplitude>? _ampSub;
  final List<double> _amps = [];
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  final _textCtl = TextEditingController();

  /// The recording length this tier allows, captured when the recorder starts.
  /// Held in state rather than read from the provider inside the ticker so the
  /// ceiling a recording is being timed against cannot change underneath it.
  int _maxSec = const UserProfile().recordingMaxSec;

  @override
  void initState() {
    super.initState();
    // Drives the character counter and the Save button's enabled state.
    _textCtl.addListener(() => setState(() {}));
  }

  /// The caller's entitlements, falling back to the free tier until the profile
  /// lands. Free is the right way to be wrong: the server enforces the real
  /// limits, so an optimistic client can only ever be a moment too generous.
  ///
  /// Two spellings because Riverpod's are not interchangeable — [_limits] is for
  /// `build`, [_limitsNow] for callbacks, which must not subscribe.
  UserProfile get _limits => _tierOf(ref.watch(profileProvider));
  UserProfile get _limitsNow => _tierOf(ref.read(profileProvider));

  static UserProfile _tierOf(AsyncValue<UserProfile> profile) =>
      profile.maybeWhen(data: (p) => p, orElse: () => const UserProfile());

  @override
  void dispose() {
    _ampSub?.cancel();
    _ticker?.cancel();
    _recorder.dispose();
    _textCtl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = 'Microphone permission denied. Allow mic access and try again.');
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
      _ampSub =
          _recorder.onAmplitudeChanged(const Duration(milliseconds: 120)).listen(_onAmplitude);
      _startedAt = DateTime.now();
      _maxSec = _limitsNow.recordingMaxSec;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed = DateTime.now().difference(_startedAt!));
        // Stop *and save* at the ceiling rather than discarding: the user has
        // been watching the time run down, and throwing away what they said
        // would be a punishment for using all of what they were given.
        if (_elapsed.inSeconds >= _maxSec) _stopAndSave();
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
    // The ceiling and the user's own tap can arrive within the same frame, and
    // stopping a recorder twice loses the file. First one through wins.
    if (_phase != _Phase.recording) return;
    setState(() => _phase = _Phase.saving);
    _ampSub?.cancel();
    _ticker?.cancel();
    final source = await _recorder.stop();
    if (source == null) {
      setState(() => _phase = _Phase.idle);
      return;
    }
    try {
      final bytes =
          kIsWeb ? await http.readBytes(Uri.parse(source)) : await File(source).readAsBytes();
      final duration =
          _startedAt == null ? 0.0 : DateTime.now().difference(_startedAt!).inMilliseconds / 1000.0;
      await ref.read(apiClientProvider).uploadAndCreate(
            audioBytes: bytes,
            contentType: kIsWeb ? 'audio/webm' : 'audio/m4a',
            durationSec: duration,
            eventDate: _isToday(_eventDate) ? null : _eventDate,
            journalId: _journalId,
          );
      // One voice memory just came off this month's allowance, and the number is
      // on screen the moment this pops. Refetch rather than decrement locally so
      // a recording made on another device is reflected too.
      ref.invalidate(profileProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _phase = _Phase.idle;
        _error = _messageFor(e);
      });
    }
  }

  Future<void> _saveText() async {
    final text = _textCtl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _phase = _Phase.saving;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).createTextMemory(
            text: text,
            eventDate: _isToday(_eventDate) ? null : _eventDate,
            journalId: _journalId,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _phase = _Phase.idle;
        _error = _messageFor(e);
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

  Future<void> _pickJournal() async {
    final choice = await pickJournal(context, selectedId: _journalId);
    if (choice != null) setState(() => _journalId = choice.journalId);
  }

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  String get _elapsedLabel => _clock(_elapsed.inSeconds);

  /// Elapsed against the ceiling, so the user can see the end coming rather than
  /// having the recorder stop on them without warning.
  String get _timerLabel => '$_elapsedLabel / ${_clock(_maxSec)}';

  static String _clock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ImmersiveChrome(
      child: Scaffold(
        // Keeps the compose field above the keyboard in Write mode.
        resizeToAvoidBottomInset: true,
        body: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.5),
              radius: 1.1,
              colors: [AppColors.immersiveTop, AppColors.immersiveBottom],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed:
                        _phase == _Phase.saving ? null : () => Navigator.of(context).maybePop(),
                  ),
                ),
                _ModeSwitch(
                  mode: _mode,
                  // Locked mid-capture: switching away from a live recording or a
                  // save in flight would strand it.
                  onChanged: _phase == _Phase.idle
                      ? (m) => setState(() {
                            _mode = m;
                            _error = null;
                          })
                      : null,
                ),
                Expanded(
                  child: _mode == _Mode.voice ? _buildVoiceBody() : _buildTextBody(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceBody() {
    final recording = _phase == _Phase.recording;
    final limits = _limits;
    // Refused before the microphone opens, not after the upload: a 429 arriving
    // once the audio is already on its way means the user spoke for nothing.
    final spent = !limits.canRecord;
    final idleMax = _clock(limits.recordingMaxSec);
    return Column(
      children: [
        const Spacer(),
        _chips(),
        const SizedBox(height: Insets.sm),
        _AllowanceChip(limits: limits),
        const SizedBox(height: Insets.sm),
        _MicButton(
          phase: _phase,
          onTap: switch (_phase) {
            _Phase.idle => spent ? null : () => _start(),
            _Phase.recording => () => _stopAndSave(),
            _Phase.saving => null,
          },
        ),
        // The second, deliberate tap needs its own affordance: opening the
        // screen must never be mistaken for having started the capture.
        _ActionHint(phase: _phase, blocked: spent),
        const SizedBox(height: Insets.lg),
        if (recording)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
            child: WaveformView(amplitudes: _amps),
          ),
        const SizedBox(height: Insets.lg),
        Text(
          switch (_phase) {
            _Phase.idle => spent ? 'Out of voice memories this month' : 'Ready when you are',
            _Phase.recording => 'Recording… $_timerLabel',
            _Phase.saving => 'Saving & indexing…',
          },
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: Insets.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
          child: Text(
            switch (_phase) {
              // Says the length out loud while idle. Finding out about the
              // ceiling by being cut off is the one way to meet it badly.
              _Phase.idle => spent
                  ? 'You have used all ${limits.recordingsPerMonth} of this month’s voice '
                      'memories.${_resetSentence(limits)} Writing one is always free.'
                  : 'Nothing is being recorded yet. Tap the mic above to begin, then speak '
                      'naturally in any language — up to $idleMax.',
              _Phase.recording => 'Speak naturally in any language. Tap to stop & save.',
              _Phase.saving => 'Hang tight while we file this memory away.',
            },
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 12.5),
          ),
        ),
        if (_error != null) _errorText(),
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
    );
  }

  Widget _buildTextBody() {
    final maxChars = _limits.textMaxChars;
    final saving = _phase == _Phase.saving;
    final canSave = !saving && _textCtl.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Insets.sm),
          _chips(),
          const SizedBox(height: Insets.lg),
          Expanded(
            child: TextField(
              controller: _textCtl,
              enabled: !saving,
              maxLines: null,
              expands: true,
              maxLength: maxChars,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.45),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                hintText: 'What happened? Write it in any language.',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                contentPadding: const EdgeInsets.all(Insets.lg),
                counterStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.lg),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_error != null) _errorText(),
          const SizedBox(height: Insets.md),
          FilledButton.icon(
            onPressed: canSave ? _saveText : null,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white70),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(saving ? 'Saving & indexing…' : 'Save memory'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sage,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: Insets.md),
            ),
          ),
          const SizedBox(height: Insets.lg),
        ],
      ),
    );
  }

  /// Date and journal, side by side. Both are optional decisions the user can
  /// simply not make — the point of the screen is still to capture fast.
  Widget _chips() {
    final idle = _phase == _Phase.idle;
    final name = journalNameFor(ref, _journalId);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: Insets.sm,
      runSpacing: Insets.sm,
      children: [
        _PillChip(
          icon: Icons.event,
          label: _isToday(_eventDate) ? 'Today · tap to back-date' : prettyDateTime(_eventDate),
          onTap: idle ? _pickDate : null,
        ),
        _PillChip(
          icon: Icons.book_outlined,
          label: name ?? 'No journal',
          onTap: idle ? _pickJournal : null,
        ),
      ],
    );
  }

  Widget _errorText() => Padding(
        padding: const EdgeInsets.only(top: Insets.md, left: Insets.md, right: Insets.md),
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFFFF9E9E)),
        ),
      );
}

/// " It resets on 1 September." — or nothing, before the profile lands.
String _resetSentence(UserProfile limits) {
  final on = limits.recordingsMonthResetsOn;
  return on == null ? '' : ' Your allowance resets on ${prettyDateTime(on)}.';
}

/// Turn a save failure into a sentence about what happened.
///
/// The two voice limits are expected answers rather than errors, and both stay
/// reachable despite the checks above — a stale profile, or a second device
/// spending the same allowance — so both get plain words instead of a code.
///
/// Keyed on the `error` code rather than the status: 413 covers both a recording
/// that ran long and a typed memory that ran long, and only the server knows
/// which one it refused.
String _messageFor(Object e) {
  return switch (e is ApiException ? _errorCode(e) : '') {
    'recording_quota' => 'That used up this month’s voice memories, so this one could '
        'not be saved. Writing memories is always free.',
    'recording_too_long' => 'That recording is longer than your plan allows.',
    _ => 'Could not save: $e',
  };
}

/// The server's machine-readable reason, or `''` when there isn't one.
String _errorCode(ApiException e) {
  try {
    final detail = (jsonDecode(e.body) as Map<String, dynamic>)['detail'];
    return detail is Map ? asText(detail['error']) : '';
  } catch (_) {
    return ''; // not every failure body is our JSON — a proxy's HTML, say
  }
}

/// How much of the month's voice allowance is left, above the mic.
///
/// Always visible rather than only near the ceiling: a number that appears when
/// you are nearly out is a warning, and a number that was always there is
/// simply how the plan works.
class _AllowanceChip extends StatelessWidget {
  const _AllowanceChip({required this.limits});
  final UserProfile limits;

  @override
  Widget build(BuildContext context) {
    final left = limits.recordingsLeftThisMonth;
    final out = left == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: out ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(out ? Icons.hourglass_empty_rounded : Icons.graphic_eq_rounded,
              size: 14, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            out
                ? 'No voice memories left this month'
                : '$left of ${limits.recordingsPerMonth} voice memories left this month',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Write / Speak, in that order because Write is the default. Disabled (rather
/// than hidden) mid-capture so the screen never appears to lose a mode.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, this.onChanged});
  final _Mode mode;
  final ValueChanged<_Mode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tab(_Mode.text, Icons.edit_note, 'Write'),
          _tab(_Mode.voice, Icons.mic, 'Speak'),
        ],
      ),
    );
  }

  Widget _tab(_Mode value, IconData icon, String label) {
    final selected = mode == value;
    final enabled = onChanged != null;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: enabled ? () => onChanged!(value) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 16,
                    color: Colors.white.withValues(alpha: enabled || selected ? 0.9 : 0.4)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: enabled || selected ? 0.95 : 0.4),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
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

/// A pill on the dark capture ground. Used for both the date and the journal so
/// the two optional decisions read as the same kind of thing.
class _PillChip extends StatelessWidget {
  const _PillChip({required this.icon, required this.label, this.onTap});
  final IconData icon;
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
              Icon(icon, color: Colors.white70, size: 16),
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
  const _ActionHint({required this.phase, this.blocked = false});
  final _Phase phase;

  /// The month's voice allowance is gone, so the mic is inert. The hint has to
  /// stop promising a tap that does nothing.
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    if (phase == _Phase.saving) return const SizedBox(height: 32);
    final idle = phase == _Phase.idle;
    final lit = idle && !blocked;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: lit ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: Colors.white.withValues(alpha: lit ? 0.35 : 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            switch ((idle, blocked)) {
              (true, true) => Icons.lock_clock,
              (true, false) => Icons.touch_app_rounded,
              _ => Icons.stop_circle_outlined,
            },
            color: Colors.white.withValues(alpha: blocked && idle ? 0.6 : 1),
            size: 16,
          ),
          const SizedBox(width: Insets.sm),
          Text(
            switch ((idle, blocked)) {
              (true, true) => 'Switch to Write, or wait for next month',
              (true, false) => 'Tap the mic to start recording',
              _ => 'Tap to stop & save',
            },
            style: TextStyle(
              color: Colors.white.withValues(alpha: blocked && idle ? 0.6 : 1),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
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
  // Built here rather than as a `late final` initialiser. The ring does not run
  // when the button is inert, so nothing would touch a lazy field until
  // `dispose` — and creating a ticker against an already-deactivated element
  // trips an assertion.
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
    if (_beckons) _pulse.repeat();
  }

  @override
  void didUpdateWidget(_MicButton old) {
    super.didUpdateWidget(old);
    if (_beckons) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
  }

  /// Idle *and* tappable. The ring invites a tap, so it must not run when there
  /// is no tap to accept.
  bool get _beckons => widget.phase == _Phase.idle && widget.onTap != null;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recording = widget.phase == _Phase.recording;
    // Idle with nothing to tap — the month's voice allowance is gone. Shown flat
    // and dimmed, because a button that looks live and then ignores you is worse
    // than one that plainly cannot be pressed. (Saving is not this: the spinner
    // below already explains why the button has stopped responding.)
    final inert = widget.phase == _Phase.idle && widget.onTap == null;
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: switch (widget.phase) {
        _Phase.idle => widget.onTap == null
            ? 'Recording unavailable: no voice memories left this month'
            : 'Start recording',
        _Phase.recording => 'Stop and save recording',
        _Phase.saving => 'Saving recording',
      },
      child: SizedBox(
        width: 172,
        height: 172,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_beckons)
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
                  color: inert ? Colors.white.withValues(alpha: 0.10) : null,
                  gradient: inert
                      ? null
                      : recording
                          ? const LinearGradient(
                              colors: [Color(0xFFE5484D), Color(0xFFB4353A)])
                          : AppColors.heroWash,
                  border: inert
                      ? Border.all(color: Colors.white.withValues(alpha: 0.18), width: 2)
                      : null,
                  boxShadow: inert
                      ? null
                      : [
                          BoxShadow(
                            color: (recording ? const Color(0xFFE5484D) : AppColors.sage)
                                .withValues(alpha: 0.55),
                            blurRadius: 40,
                            spreadRadius: 4,
                          ),
                        ],
                ),
                child: Icon(
                  inert
                      ? Icons.mic_off_rounded
                      : recording
                          ? Icons.stop_rounded
                          : Icons.mic,
                  color: Colors.white.withValues(alpha: inert ? 0.45 : 1),
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
