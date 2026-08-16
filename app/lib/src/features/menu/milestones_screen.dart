import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/providers.dart';
import '../../widgets/audio_play_button.dart';
import '../../widgets/formatting.dart';
import '../../widgets/milestone_star_button.dart';
import '../../widgets/states.dart';

/// The starred moments of a life, newest first.
class MilestonesScreen extends ConsumerWidget {
  const MilestonesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordings = ref.watch(recordingsProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Milestones')),
      body: recordings.when(
        loading: () => const AppLoadingCard(height: 200),
        error: (e, _) => AppErrorCard('Could not load milestones: $e'),
        data: (recs) {
          final milestones = recs.where((r) => r.isMilestone).toList();
          if (milestones.isEmpty) {
            return const AppEmptyState(
              icon: Icons.star_outline_rounded,
              title: 'No milestones yet',
              message: 'When a memory marks something big, it shows up here with a ⭐.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(Insets.lg),
            itemCount: milestones.length,
            separatorBuilder: (_, __) => const SizedBox(height: Insets.sm),
            itemBuilder: (_, i) {
              final r = milestones[i];
              return Container(
                key: ValueKey(r.id),
                padding: const EdgeInsets.all(Insets.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    AudioPlayButton(key: ValueKey(r.id), recordingId: r.id),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              MilestoneStarButton(r),
                              const SizedBox(width: Insets.xs),
                              Expanded(
                                child: Text(
                                  r.title.isEmpty ? 'Milestone' : r.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            r.summary.isEmpty ? prettyDate(r.eventDate) : r.summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
