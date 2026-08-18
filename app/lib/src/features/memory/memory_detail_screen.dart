import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/audio_play_button.dart';
import '../../widgets/formatting.dart';
import '../../widgets/journal_picker.dart';
import '../../widgets/milestone_star_button.dart';
import '../../widgets/section_header.dart';
import '../../widgets/states.dart';

/// Opens the full view of one memory. The lists only ever have room for a
/// title, so this is the only place the memory itself can actually be read.
Future<void> openMemoryDetail(BuildContext context, String recordingId) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => MemoryDetailScreen(recordingId: recordingId)),
  );
}

/// One memory in full: what was said or written, what the AI made of it, and
/// playback when there is audio.
///
/// Takes an id rather than a [Recording] and reads from [recordingsProvider], so
/// the screen follows the row it came from — a transcript that lands while this
/// is open appears here, and starring stays in step with the list behind it.
class MemoryDetailScreen extends ConsumerWidget {
  const MemoryDetailScreen({super.key, required this.recordingId});

  final String recordingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordings = ref.watch(recordingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      body: recordings.when(
        loading: () => const AppLoadingCard(height: 200),
        error: (e, _) => AppErrorCard('Could not load this memory: $e'),
        data: (recs) {
          Recording? rec;
          for (final r in recs) {
            if (r.id == recordingId) rec = r;
          }
          if (rec == null) {
            // Deleted, or on another device's account. Nothing to recover here.
            return const AppEmptyState(
              icon: Icons.search_off_rounded,
              title: 'Memory not found',
              message: 'This memory is no longer in your timeline.',
            );
          }
          return _Body(rec);
        },
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body(this.rec);
  final Recording rec;

  /// Move this memory to another journal.
  ///
  /// Optimistic through [RecordingsNotifier.setJournal], so the row here and
  /// every list behind it change together and roll back together.
  Future<void> _refile(BuildContext context, WidgetRef ref) async {
    final choice = await pickJournal(context, selectedId: rec.journalId);
    if (choice == null) return;
    if (choice.journalId == rec.journalId) return;
    try {
      await ref.read(recordingsProvider.notifier).setJournal(rec.id, choice.journalId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not move that memory: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final processing = isProcessing(rec.status);
    return ListView(
      padding: const EdgeInsets.all(Insets.lg),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                rec.title.isEmpty ? _fallbackTitle : rec.title,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: MilestoneStarButton(rec),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Text(
          _subtitle,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
        ),
        const SizedBox(height: Insets.md),
        _JournalRow(
          journal: journalFor(ref, rec.journalId),
          onTap: () => _refile(context, ref),
        ),
        const SizedBox(height: Insets.lg),
        if (rec.hasAudio) _PlaybackRow(rec.id),
        if (processing) ...[
          const SizedBox(height: Insets.md),
          _Banner(
            icon: null,
            text: statusLabel(rec.status, source: rec.source),
            detail: rec.hasAudio
                ? 'The transcript appears here once it is ready.'
                : 'Your words are saved. The AI is still reading them.',
            color: scheme.surfaceContainerHighest,
            onColor: scheme.onSurfaceVariant,
          ),
        ] else if (rec.status == 'failed') ...[
          const SizedBox(height: Insets.md),
          _Banner(
            icon: Icons.error_outline,
            text: statusLabel(rec.status),
            detail: rec.hasAudio
                ? 'The audio is kept, so this can be retried.'
                : 'Your text is kept exactly as you wrote it.',
            color: scheme.errorContainer,
            onColor: scheme.onErrorContainer,
          ),
        ],
        if (rec.summary.isNotEmpty) ...[
          const SizedBox(height: Insets.xl),
          const SectionHeader('Summary'),
          const SizedBox(height: Insets.sm),
          Text(rec.summary, style: const TextStyle(fontSize: 15, height: 1.45)),
        ],
        const SizedBox(height: Insets.xl),
        SectionHeader(rec.hasAudio ? 'Transcript' : 'What you wrote'),
        const SizedBox(height: Insets.sm),
        if (rec.hasAudio)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              'Transcribed by AI from your recording — it may not be word-perfect.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
            ),
          ),
        _TranscriptBody(rec: rec, processing: processing),
        if (rec.mood.isNotEmpty ||
            rec.people.isNotEmpty ||
            rec.places.isNotEmpty ||
            rec.tags.isNotEmpty) ...[
          const SizedBox(height: Insets.xl),
          const SectionHeader('In this memory'),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              if (rec.mood.isNotEmpty)
                Chip(avatar: const Icon(Icons.mood, size: 16), label: Text(rec.mood)),
              for (final p in rec.people)
                Chip(avatar: const Icon(Icons.person_outline, size: 16), label: Text(p)),
              for (final p in rec.places)
                Chip(avatar: const Icon(Icons.place_outlined, size: 16), label: Text(p)),
              for (final t in rec.tags)
                Chip(avatar: const Icon(Icons.tag, size: 16), label: Text(t)),
            ],
          ),
        ],
        const SizedBox(height: Insets.xxl),
      ],
    );
  }

  String get _fallbackTitle => rec.hasAudio ? 'Untitled recording' : 'Untitled written memory';

  /// "Aug 15, 2025 · written · 2d ago" — the event date first, because that is
  /// the date the memory is *about*, which may be long before it was captured.
  String get _subtitle {
    final parts = <String>[
      prettyDate(rec.eventDate),
      if (rec.hasAudio) _duration else 'written',
      relativeTime(rec.recordedAt),
    ];
    return parts.join('  ·  ');
  }

  String get _duration {
    final total = rec.durationSec.round();
    if (total <= 0) return 'recorded';
    final m = total ~/ 60;
    final s = total % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }
}

/// Which journal this memory is filed in, and the way to change it.
///
/// Always shown, even when unfiled — a row that only appears once a memory is
/// filed would leave no way to file the ones that are not.
class _JournalRow extends StatelessWidget {
  const _JournalRow({required this.journal, required this.onTap});

  final Journal? journal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filed = journal != null;
    final color = filed ? journalColor(journal!.colorIndex) : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Insets.sm, horizontal: Insets.xs),
          child: Row(
            children: [
              JournalDot(
                icon: filed ? Icons.book_outlined : Icons.inbox_outlined,
                color: color,
                size: 30,
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Text(
                  filed ? journal!.name : 'Not in a journal',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: filed ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(filed ? 'Change' : 'File it',
                  style: TextStyle(color: scheme.primary, fontSize: 12.5)),
              Icon(Icons.chevron_right, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _TranscriptBody extends StatelessWidget {
  const _TranscriptBody({required this.rec, required this.processing});
  final Recording rec;
  final bool processing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (rec.transcript.isEmpty) {
      return Text(
        processing
            ? 'Not ready yet.'
            : (rec.hasAudio
                ? 'No transcript was produced for this recording.'
                : 'This memory has no text.'),
        style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      // Selectable so a memory can be copied out — the export screen is the
      // bulk path, but one paragraph should not need it.
      child: SelectableText(
        rec.transcript,
        style: const TextStyle(fontSize: 15, height: 1.5),
      ),
    );
  }
}

class _PlaybackRow extends StatelessWidget {
  const _PlaybackRow(this.recordingId);
  final String recordingId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        AudioPlayButton(recordingId: recordingId),
        const SizedBox(width: Insets.md),
        Text(
          'Play the original recording',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.detail,
    required this.color,
    required this.onColor,
  });

  /// Null draws a spinner instead — used while ingestion is still running.
  final IconData? icon;
  final String text;
  final String detail;
  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: icon == null
                ? CircularProgressIndicator(strokeWidth: 2, color: onColor)
                : Icon(icon, size: 18, color: onColor),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    style: TextStyle(color: onColor, fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 2),
                Text(detail, style: TextStyle(color: onColor, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
