import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/audio_playback.dart';

/// The stand-in for [AudioPlayButton] on a typed memory, which has no audio to
/// play. Same 40×40 circle so a mixed list keeps one alignment grid, and it is
/// inert on purpose: a disabled play button would still read as "playable but
/// broken", which is the wrong story.
class TextMemoryGlyph extends StatelessWidget {
  const TextMemoryGlyph({super.key, this.onColor, this.backgroundColor});

  final Color? onColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = onColor ?? scheme.primary;
    return Semantics(
      label: 'Written memory',
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: backgroundColor ?? scheme.primary.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.notes_rounded, color: fg, size: 22),
      ),
    );
  }
}

/// Play/pause control for a recording. All buttons drive the single shared
/// player in [audioPlaybackProvider], so only one recording can ever be
/// playing and each button always plays its own [recordingId]. Shared by the
/// Home feed, Milestones and Recall citation cards.
class AudioPlayButton extends ConsumerWidget {
  const AudioPlayButton({
    super.key,
    required this.recordingId,
    this.onColor,
    this.backgroundColor,
  });

  final String recordingId;

  /// Icon colour override (defaults to the theme primary).
  final Color? onColor;

  /// Circle background override (defaults to a translucent primary).
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<PlaybackState>(audioPlaybackProvider, (prev, next) {
      if (next.recordingId == recordingId &&
          next.errorAt != null &&
          next.errorAt != prev?.errorAt) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play this recording.')),
        );
      }
    });

    final playback = ref.watch(audioPlaybackProvider);
    final isCurrent = playback.recordingId == recordingId;
    final playing = isCurrent && playback.playing;
    final loading = isCurrent && playback.loading;

    final scheme = Theme.of(context).colorScheme;
    final fg = onColor ?? scheme.primary;
    final bg = backgroundColor ?? scheme.primary.withValues(alpha: 0.12);

    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: loading ? null : () => ref.read(audioPlaybackProvider.notifier).toggle(recordingId),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                : Icon(playing ? Icons.pause : Icons.play_arrow, color: fg, size: 22),
          ),
        ),
      ),
    );
  }
}
