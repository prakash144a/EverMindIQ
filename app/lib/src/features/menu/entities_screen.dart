import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/section_header.dart';
import '../../widgets/states.dart';

/// Browse memories by who / where / what — aggregated from recording entities.
class EntitiesScreen extends ConsumerWidget {
  const EntitiesScreen({super.key});

  Map<String, int> _tally(List<Recording> recs, List<String> Function(Recording) pick) {
    final counts = <String, int>{};
    for (final r in recs) {
      for (final v in pick(r)) {
        if (v.trim().isEmpty) continue;
        counts[v] = (counts[v] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {for (final e in entries) e.key: e.value};
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordings = ref.watch(recordingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('People, places & tags')),
      body: recordings.when(
        loading: () => const AppLoadingCard(height: 200),
        error: (e, _) => AppErrorCard('Could not load: $e'),
        data: (recs) {
          final people = _tally(recs, (r) => r.people);
          final places = _tally(recs, (r) => r.places);
          final tags = _tally(recs, (r) => r.tags);
          if (people.isEmpty && places.isEmpty && tags.isEmpty) {
            return const AppEmptyState(
              icon: Icons.tag_outlined,
              title: 'Nothing tagged yet',
              message:
                  'As your memories are processed, the people, places and themes in them collect here.',
            );
          }
          return ListView(
            padding: const EdgeInsets.all(Insets.lg),
            children: [
              _EntityGroup('People', Icons.people_outline, people),
              _EntityGroup('Places', Icons.place_outlined, places),
              _EntityGroup('Tags', Icons.tag, tags),
            ],
          );
        },
      ),
    );
  }
}

class _EntityGroup extends StatelessWidget {
  const _EntityGroup(this.title, this.icon, this.counts);
  final String title;
  final IconData icon;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    if (counts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              for (final e in counts.entries)
                Chip(
                  avatar: Icon(icon, size: 16),
                  label: Text('${e.key}  ·  ${e.value}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
