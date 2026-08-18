import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/journal_picker.dart';
import '../../widgets/states.dart';
import 'journal_screen.dart';

/// Journals — what a memory is *about*, as opposed to when it happened.
///
/// Unfiled is a permanent first row rather than something that appears when
/// non-empty: it is the only route to the memories recorded before journals
/// existed, and hiding it would leave that backlog unreachable.
class JournalsScreen extends ConsumerWidget {
  const JournalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journals = ref.watch(journalsProvider);
    final recordings = ref.watch(recordingsProvider).valueOrNull ?? const <Recording>[];
    final journalsMax = ref.watch(profileProvider).maybeWhen(
          data: (p) => p.journalsMax,
          orElse: () => const UserProfile().journalsMax,
        );

    int countIn(String journalId) => recordings.where((r) => r.journalId == journalId).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Journals')),
      body: journals.when(
        loading: () => const AppLoadingCard(height: 200),
        error: (e, _) => AppErrorCard('Could not load journals: $e'),
        data: (items) {
          final atCeiling = items.length >= journalsMax;
          return ListView(
            padding: const EdgeInsets.all(Insets.lg),
            children: [
              Text(
                'Sort your memories by what they are about, then ask the AI about '
                'one journal at a time.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: Insets.lg),
              _JournalTile(
                icon: Icons.inbox_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                name: 'Unfiled',
                count: countIn(''),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const JournalScreen.unfiled()),
                ),
              ),
              const SizedBox(height: Insets.sm),
              for (final j in items) ...[
                _JournalTile(
                  key: ValueKey(j.id),
                  icon: Icons.book_outlined,
                  color: journalColor(j.colorIndex),
                  name: j.name,
                  count: countIn(j.id),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => JournalScreen(journal: j)),
                  ),
                  onEdit: () => _rename(context, ref, j),
                  onDelete: () => _confirmDelete(context, ref, j, countIn(j.id)),
                ),
                const SizedBox(height: Insets.sm),
              ],
              const SizedBox(height: Insets.md),
              Row(
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New journal'),
                    // Disabled rather than hidden: a control that vanishes reads
                    // as a bug, and the count beside it explains itself.
                    onPressed: atCeiling ? null : () => _create(context, ref),
                  ),
                  const SizedBox(width: Insets.md),
                  Text(
                    '${items.length} of $journalsMax',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await _promptForName(context, title: 'New journal');
    if (name == null || !context.mounted) return;
    try {
      await ref.read(journalsProvider.notifier).create(name);
    } catch (e) {
      if (context.mounted) _say(context, _messageFor(e));
    }
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Journal journal) async {
    final name = await _promptForName(context, title: 'Rename journal', initial: journal.name);
    if (name == null || name == journal.name || !context.mounted) return;
    try {
      await ref.read(journalsProvider.notifier).rename(journal.id, name);
    } catch (e) {
      if (context.mounted) _say(context, _messageFor(e));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Journal journal,
    int count,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${journal.name}"?'),
        // Says plainly what survives. Deleting a journal is a filing decision,
        // and someone must never fear it will take their memories with it.
        content: Text(
          count == 0
              ? 'The journal is empty, so nothing else changes.'
              : '$count ${count == 1 ? 'memory' : 'memories'} will move to Unfiled. '
                  'Nothing is deleted.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final unfiled = await ref.read(journalsProvider.notifier).remove(journal.id);
      if (context.mounted && unfiled > 0) {
        _say(context, '$unfiled ${unfiled == 1 ? 'memory' : 'memories'} moved to Unfiled.');
      }
    } catch (e) {
      if (context.mounted) _say(context, _messageFor(e));
    }
  }
}

Future<String?> _promptForName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'Travel, Thoughts, Politics…'),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

/// Turn a failure into something worth reading.
///
/// The ceiling and the duplicate name are both ordinary, expected answers — not
/// errors — so they get a plain sentence rather than a status code.
String _messageFor(Object e) {
  if (e is ApiException) {
    if (e.statusCode == 403) return 'You have used all your journals.';
    if (e.statusCode == 409) return 'You already have a journal with that name.';
  }
  return 'Could not save that: $e';
}

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class _JournalTile extends StatelessWidget {
  const _JournalTile({
    super.key,
    required this.icon,
    required this.color,
    required this.name,
    required this.count,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  final IconData icon;
  final Color color;
  final String name;
  final int count;
  final VoidCallback onTap;

  /// Absent on Unfiled, which is a view rather than a journal.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              JournalDot(icon: icon, color: color),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      count == 1 ? '1 memory' : '$count memories',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (onEdit != null || onDelete != null)
                PopupMenuButton<String>(
                  tooltip: 'Journal options',
                  onSelected: (v) => v == 'rename' ? onEdit?.call() : onDelete?.call(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                )
              else
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
