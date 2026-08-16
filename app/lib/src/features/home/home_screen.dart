import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/audio_play_button.dart';
import '../../widgets/formatting.dart';
import '../../widgets/memory_card.dart';
import '../../widgets/milestone_star_button.dart';
import '../../widgets/section_header.dart';
import '../../widgets/states.dart';
import '../menu/milestones_screen.dart';
import '../shell/app_shell.dart';

/// Home — a warm resurfacing feed: the "On This Day" keepsake, a row of
/// milestones, and the most recent moments.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final memories = ref.watch(onThisDayProvider);
    final recordings = ref.watch(recordingsProvider);

    final intervalSec = settings.maybeWhen(
      data: (s) => s.slideshowIntervalSec,
      orElse: () => 6,
    );
    final showSlideshow = settings.maybeWhen(
      data: (s) => s.onThisDayEnabled,
      orElse: () => true,
    );

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(onThisDayProvider);
        ref.invalidate(recordingsProvider);
        await ref.read(recordingsProvider.future);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, Insets.xxl),
        children: [
          if (showSlideshow) ...[
            memories.when(
              data: (items) => items.isEmpty
                  ? const _EmptyMemories()
                  : _OnThisDaySlideshow(items: items, intervalSec: intervalSec),
              loading: () => const AppLoadingCard(height: 190),
              error: (e, _) => AppErrorCard('Could not load memories: $e'),
            ),
            const SizedBox(height: Insets.xl),
          ],

          // Milestones row
          recordings.maybeWhen(
            data: (recs) {
              final milestones = recs.where((r) => r.isMilestone).toList();
              if (milestones.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    'Milestones',
                    action: 'See all',
                    onAction: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const MilestonesScreen()),
                    ),
                  ),
                  const SizedBox(height: Insets.sm),
                  SizedBox(
                    // 96 left the chip 1px short once its border was accounted for.
                    height: 104,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: milestones.length,
                      separatorBuilder: (_, __) => const SizedBox(width: Insets.md),
                      itemBuilder: (_, i) => _MilestoneChip(milestones[i]),
                    ),
                  ),
                  const SizedBox(height: Insets.xl),
                ],
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),

          const SectionHeader('Recent moments'),
          const SizedBox(height: Insets.sm),
          recordings.when(
            data: (recs) => recs.isEmpty
                ? AppEmptyState(
                    icon: Icons.mic_none,
                    title: 'No moments yet',
                    message: 'Speak a memory and it\'s kept — in any language, any time.',
                    actionLabel: 'Record your first memory',
                    onAction: () => openRecordScreen(context, ref),
                  )
                : Column(
                    children: [
                      for (final r in recs.take(10)) ...[
                        _RecordingTile(r, key: ValueKey(r.id)),
                        const SizedBox(height: Insets.sm),
                      ],
                    ],
                  ),
            loading: () => const AppLoadingCard(height: 120),
            error: (e, _) => AppErrorCard('Could not load recordings: $e'),
          ),
        ],
      ),
    );
  }
}

class _OnThisDaySlideshow extends StatefulWidget {
  const _OnThisDaySlideshow({required this.items, required this.intervalSec});
  final List<MemoryItem> items;
  final int intervalSec;

  @override
  State<_OnThisDaySlideshow> createState() => _OnThisDaySlideshowState();
}

class _OnThisDaySlideshowState extends State<_OnThisDaySlideshow> {
  final _controller = PageController();
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant _OnThisDaySlideshow old) {
    super.didUpdateWidget(old);
    if (old.intervalSec != widget.intervalSec || old.items.length != widget.items.length) {
      _restartTimer();
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.items.length > 1) {
      // Respects the user's slideshow-interval setting.
      _timer = Timer.periodic(Duration(seconds: widget.intervalSec.clamp(3, 30)), (_) {
        _page = (_page + 1) % widget.items.length;
        _controller.animateToPage(
          _page,
          duration: Motion.medium,
          curve: Curves.easeInOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 200,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => MemoryCard(widget.items[i]),
          ),
        ),
        if (widget.items.length > 1) ...[
          const SizedBox(height: Insets.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < widget.items.length; i++)
                AnimatedContainer(
                  duration: Motion.fast,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _MilestoneChip extends StatelessWidget {
  const _MilestoneChip(this.rec);
  final Recording rec;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 150,
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.star_rounded, color: scheme.tertiary, size: 18),
          const Spacer(),
          Text(
            rec.title.isEmpty ? 'Milestone' : rec.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            prettyDate(rec.eventDate),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile(this.rec, {super.key});
  final Recording rec;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          AudioPlayButton(recordingId: rec.id),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rec.title.isEmpty ? 'New recording' : rec.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                // Only shown until the pipeline has produced a real title.
                if (isProcessing(rec.status)) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        statusLabel(rec.status),
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ] else if (rec.status == 'failed') ...[
                  const SizedBox(height: 3),
                  Text(
                    statusLabel(rec.status),
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MilestoneStarButton(rec),
              Text(relativeTime(rec.recordedAt),
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyMemories extends StatelessWidget {
  const _EmptyMemories();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 120,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Text(
        'Nothing resurfacing today — your future self will thank you for recording.',
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
