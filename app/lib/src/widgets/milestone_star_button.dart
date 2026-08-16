import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';

/// Tappable milestone star. Ingestion makes the first guess; this lets the user
/// correct it, and the backend then stops second-guessing that choice.
class MilestoneStarButton extends ConsumerWidget {
  const MilestoneStarButton(this.rec, {super.key});

  final Recording rec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final on = rec.isMilestone;
    return IconButton(
      icon: Icon(
        on ? Icons.star_rounded : Icons.star_outline_rounded,
        size: 18,
        color: on ? scheme.tertiary : scheme.outline,
      ),
      tooltip: on ? 'Remove milestone' : 'Mark as milestone',
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      onPressed: () async {
        try {
          await ref.read(recordingsProvider.notifier).toggleMilestone(rec.id);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not update this milestone.')),
            );
          }
        }
      },
    );
  }
}
