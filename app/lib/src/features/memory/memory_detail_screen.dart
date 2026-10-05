import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/api_client.dart';
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
    Recording? found;
    for (final r in recordings.valueOrNull ?? const <Recording>[]) {
      if (r.id == recordingId) found = r;
    }
    final rec = found;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          // Only once the memory has actually loaded: an overflow offering to
          // delete something the screen cannot show yet is a way to delete the
          // wrong thing.
          if (rec != null)
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (choice) {
                if (choice == 'delete') deleteMemory(context, ref, rec);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error),
                    title: Text(
                      'Delete memory',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: recordings.when(
        loading: () => const AppLoadingCard(height: 200),
        error: (e, _) => AppErrorCard('Could not load this memory: $e'),
        data: (_) {
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

/// Ask, then erase. Pops the screen on success, since what it was showing is
/// gone.
///
/// The confirmation is deliberately heavier than the journal one next door.
/// Deleting a journal moves memories to Unfiled and can be undone by hand;
/// this destroys the only copy of something the user cannot write again — so
/// the dialog spells out what goes, says plainly that we cannot get it back,
/// and names the action "Delete forever" rather than "OK".
Future<void> deleteMemory(BuildContext context, WidgetRef ref, Recording rec) async {
  final scheme = Theme.of(context).colorScheme;
  final title = rec.title.isEmpty ? 'this memory' : '“${rec.title}”';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.delete_forever_outlined, color: scheme.error),
      title: const Text('Delete this memory?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You are about to delete $title.'),
          const SizedBox(height: Insets.md),
          // Itemised rather than summarised: "everything" is easy to skim past,
          // and the audio is the part people do not expect to lose.
          _GoesWith(rec.hasAudio
              ? const [
                  'The original recording — the audio itself',
                  'Its transcript and summary',
                  'Everything the AI found in it',
                  'Its place in your timeline, journals and insights',
                ]
              : const [
                  'The words you wrote',
                  'Its summary',
                  'Everything the AI found in it',
                  'Its place in your timeline, journals and insights',
                ]),
          const SizedBox(height: Insets.md),
          Text(
            'This cannot be undone. We keep no copy anywhere, so nobody — including '
            'us — can bring it back.',
            style: TextStyle(fontWeight: FontWeight.w600, color: scheme.error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Keep it'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete forever'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  try {
    await ref.read(recordingsProvider.notifier).remove(rec.id);
    if (!context.mounted) return;
    // No "Undo" action on this snackbar, deliberately. Offering one would be a
    // lie: the audio object is already gone.
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Memory deleted.')));
    Navigator.of(context).maybePop();
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Could not delete that memory: $e')));
  }
}

/// The bullet list of what a delete takes with it.
class _GoesWith extends StatelessWidget {
  const _GoesWith(this.items);
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.remove, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(item,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
      ],
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

  /// Give this memory a title of the user's own.
  ///
  /// Not optimistic, unlike the journal above: the server can refuse a rename
  /// (the memory may be mid-processing), so the title moves once it has agreed.
  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final title = await _promptForTitle(context, rec.title);
    if (title == null || title == rec.title) return;
    try {
      await ref.read(recordingsProvider.notifier).rename(rec.id, title);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_editError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final processing = isProcessing(rec.status);
    // Once the words are the user's own, a memory in flight is being re-read,
    // not transcribed — whichever way it was first captured.
    final ownWords = !rec.hasAudio || rec.transcriptEdited;
    // The title and the words can be changed for a few days after a memory is
    // saved, then never again. The controls stay on the page, disabled, with a
    // line saying why — vanishing would read as a bug. The server refuses the
    // same edits, so this is a courtesy rather than the gate.
    final windowDays =
        (ref.watch(profileProvider).valueOrNull ?? const UserProfile()).editWindowDays;
    final editable = rec.editableWithin(windowDays);
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
            // Not while processing: ingestion writes the whole memory back when
            // it finishes, and the server refuses an edit it would overwrite.
            if (!processing) ...[
              IconButton(
                tooltip: 'Rename',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: editable ? () => _rename(context, ref) : null,
              ),
              // A recording that never produced a transcript has nothing for
              // the AI to title.
              _NewTitleButton(
                recordingId: rec.id,
                enabled: editable && rec.transcript.trim().isNotEmpty,
              ),
            ],
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
        if (!editable) ...[
          const SizedBox(height: Insets.xs),
          Text(
            'Editing closed ${_days(windowDays)} after this memory was saved.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
          ),
        ],
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
            text: statusLabel(rec.status, source: ownWords ? 'text' : rec.source),
            detail: ownWords
                ? 'Your words are saved. The AI is still reading them.'
                : 'The transcript appears here once it is ready.',
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
          const SizedBox(height: Insets.xs),
          // The one part of the page with no way to edit it, so say why.
          Text(
            editable
                ? 'Written by AI. It is rewritten when you edit the memory below.'
                : 'Written by AI.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
          ),
        ],
        const SizedBox(height: Insets.xl),
        SectionHeader(
          rec.hasAudio ? 'Transcript' : 'What you wrote',
          action: processing ? null : 'Edit',
          onAction: editable ? () => _openEditor(context, rec, windowDays) : null,
        ),
        const SizedBox(height: Insets.sm),
        if (rec.hasAudio)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              rec.transcriptEdited
                  ? 'Transcribed by AI from your recording, then edited by you.'
                  : 'Transcribed by AI from your recording — it may not be word-perfect.',
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

/// "7 days", "1 day" — the window is configured on the server, so it can be either.
String _days(int n) => n == 1 ? '1 day' : '$n days';

/// Turn a refused edit into something worth reading.
///
/// Both of these are ordinary answers rather than faults, so they get a plain
/// sentence instead of a status code.
String _editError(Object e) {
  if (e is ApiException) {
    if (e.statusCode == 409) {
      return 'This memory is still being processed. Try again in a moment.';
    }
    if (e.statusCode == 413) return 'That is longer than your plan allows.';
    // The window closed while the page was open, or this device's clock is off.
    if (e.statusCode == 403) return 'This memory can no longer be edited.';
  }
  return 'Could not save that: $e';
}

Future<String?> _promptForTitle(BuildContext context, String initial) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Rename memory'),
      content: TextField(
        controller: controller,
        autofocus: true,
        // The server's cap. Longer than a journal name, still a title.
        maxLength: 80,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'A title for this memory'),
        onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

/// Asks the AI for a different title.
///
/// The way back from a rename that was a mistake, and the way on from an AI
/// title that was not liked — each press replaces the current one. Holds its
/// own busy state because the model takes a few seconds, and a second press in
/// that time would only pay for a title nobody sees.
class _NewTitleButton extends ConsumerStatefulWidget {
  const _NewTitleButton({required this.recordingId, required this.enabled});

  final String recordingId;
  final bool enabled;

  @override
  ConsumerState<_NewTitleButton> createState() => _NewTitleButtonState();
}

class _NewTitleButtonState extends ConsumerState<_NewTitleButton> {
  bool _busy = false;

  Future<void> _run() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(recordingsProvider.notifier).regenerateTitle(widget.recordingId);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_editError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Generate a new title',
      visualDensity: VisualDensity.compact,
      onPressed: widget.enabled && !_busy ? _run : null,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.auto_awesome_outlined, size: 20),
    );
  }
}

Future<void> _openEditor(BuildContext context, Recording rec, int windowDays) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _EditTextScreen(rec, windowDays: windowDays),
    ),
  );
}

/// Rewrite a memory's words: what was typed, or the transcript of what was said.
///
/// A page of its own rather than a field in place, because saving is not a
/// small act — the summary is rewritten and the memory is indexed again — and
/// the note above the field is where that gets said before it happens.
class _EditTextScreen extends ConsumerStatefulWidget {
  const _EditTextScreen(this.rec, {required this.windowDays});
  final Recording rec;
  final int windowDays;

  @override
  ConsumerState<_EditTextScreen> createState() => _EditTextScreenState();
}

class _EditTextScreenState extends ConsumerState<_EditTextScreen> {
  late final TextEditingController _ctl = TextEditingController(text: widget.rec.transcript);
  bool _saving = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _ctl.text.trim();
    if (text.isEmpty) return;
    if (text == widget.rec.transcript.trim()) {
      // Nothing changed, so nothing for the AI to re-read.
      Navigator.of(context).pop();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(recordingsProvider.notifier).rewrite(widget.rec.id, text);
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Memory updated. Its summary is rewritten to match.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(_editError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rec = widget.rec;
    final profile = ref.watch(profileProvider).valueOrNull ?? const UserProfile();
    // The tier's cap, but never below what is already there: a long transcript,
    // or text written on a plan since lapsed, must still be correctable.
    final maxChars =
        rec.transcript.length > profile.textMaxChars ? rec.transcript.length : profile.textMaxChars;
    final canSave = !_saving && _ctl.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(rec.hasAudio ? 'Edit transcript' : 'Edit memory'),
        actions: [
          TextButton(onPressed: canSave ? _save : null, child: const Text('Save')),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                'Saving rewrites the summary to match.',
                if (rec.hasAudio)
                  'The title stays as it is, and the recording itself is not changed.'
                else
                  'The title stays as it is.',
                'A memory can be edited for ${_days(widget.windowDays)} after it is saved.',
              ].join(' '),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
            const SizedBox(height: Insets.md),
            Expanded(
              child: TextField(
                controller: _ctl,
                enabled: !_saving,
                autofocus: true,
                maxLines: null,
                expands: true,
                maxLength: maxChars,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(fontSize: 15, height: 1.5),
                decoration: const InputDecoration(border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
      ),
    );
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
