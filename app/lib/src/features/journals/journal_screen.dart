import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/audio_play_button.dart';
import '../../widgets/formatting.dart';
import '../../widgets/milestone_star_button.dart';
import '../../widgets/states.dart';
import '../memory/memory_detail_screen.dart';

/// Everything filed in one journal — or, in the [JournalScreen.unfiled] form,
/// everything filed in none.
///
/// Filters `recordingsProvider` rather than fetching a scoped list: the app
/// already holds every recording, so a second request would buy nothing and the
/// screen follows a reassignment made elsewhere for free.
class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key, required Journal this.journal});

  const JournalScreen.unfiled({super.key}) : journal = null;

  /// Null for the Unfiled view, which is a filter rather than a journal.
  final Journal? journal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordings = ref.watch(recordingsProvider);
    final journalId = journal?.id ?? '';
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(journal?.name ?? 'Unfiled')),
      body: recordings.when(
        loading: () => const AppLoadingCard(height: 200),
        error: (e, _) => AppErrorCard('Could not load memories: $e'),
        data: (recs) {
          final items = recs.where((r) => r.journalId == journalId).toList();
          if (items.isEmpty) {
            return AppEmptyState(
              icon: journal == null ? Icons.inbox_outlined : Icons.book_outlined,
              title: journal == null ? 'Nothing unfiled' : 'This journal is empty',
              message: journal == null
                  ? 'Every memory you have is filed in a journal.'
                  : 'Open a memory and choose "${journal!.name}" to file it here.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(Insets.lg),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: Insets.sm),
            itemBuilder: (_, i) {
              final r = items[i];
              return Material(
                key: ValueKey(r.id),
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(Radii.md),
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.md),
                  onTap: () => openMemoryDetail(context, r.id),
                  child: Container(
                    padding: const EdgeInsets.all(Insets.md),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        if (r.hasAudio)
                          AudioPlayButton(key: ValueKey(r.id), recordingId: r.id)
                        else
                          const TextMemoryGlyph(),
                        const SizedBox(width: Insets.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.title.isEmpty
                                    ? (r.hasAudio ? 'New recording' : 'New written memory')
                                    : r.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                prettyDate(r.eventDate),
                                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        MilestoneStarButton(r),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
