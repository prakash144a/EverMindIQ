import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../data/providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final memories = ref.watch(onThisDayProvider);
    final recordings = ref.watch(recordingsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(onThisDayProvider);
        ref.invalidate(recordingsProvider);
        await ref.read(recordingsProvider.future);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          settings.maybeWhen(
            data: (s) => s.onThisDayEnabled
                ? memories.when(
                    data: (items) => _OnThisDaySlideshow(items: items),
                    loading: () => const _LoadingCard(height: 180),
                    error: (e, _) => _ErrorCard('Could not load memories: $e'),
                  )
                : const SizedBox.shrink(),
            orElse: () => const _LoadingCard(height: 180),
          ),
          const SizedBox(height: 24),
          Text('Recent moments', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          recordings.when(
            data: (recs) => recs.isEmpty
                ? const _EmptyState()
                : Column(children: recs.take(10).map((r) => _RecordingTile(r)).toList()),
            loading: () => const _LoadingCard(height: 120),
            error: (e, _) => _ErrorCard('Could not load recordings: $e'),
          ),
        ],
      ),
    );
  }
}

class _OnThisDaySlideshow extends StatefulWidget {
  const _OnThisDaySlideshow({required this.items});
  final List<MemoryItem> items;

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
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 6), (_) {
        _page = (_page + 1) % widget.items.length;
        _controller.animateToPage(_page,
            duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
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
    if (widget.items.isEmpty) {
      return const _EmptyMemories();
    }
    return SizedBox(
      height: 190,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.items.length,
        onPageChanged: (i) => _page = i,
        itemBuilder: (_, i) => _MemoryCard(widget.items[i]),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard(this.item);
  final MemoryItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, color: scheme.onPrimaryContainer, size: 18),
                const SizedBox(width: 8),
                Text(item.reason.toUpperCase(),
                    style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5)),
              ],
            ),
            const SizedBox(height: 12),
            Text(item.title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(color: scheme.onPrimaryContainer)),
            const SizedBox(height: 8),
            Expanded(
              child: Text(item.summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onPrimaryContainer)),
            ),
            Text(_pretty(item.eventDate),
                style: TextStyle(color: scheme.onPrimaryContainer.withOpacity(0.7), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile(this.rec);
  final Recording rec;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          child: Icon(rec.isMilestone ? Icons.star : Icons.graphic_eq),
        ),
        title: Text(rec.title.isEmpty ? 'Untitled moment' : rec.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          rec.summary.isEmpty ? _statusLabel(rec.status) : rec.summary,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(_pretty(rec.eventDate), style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Column(children: [
          Icon(Icons.mic_none, size: 48),
          SizedBox(height: 8),
          Text('No moments yet. Tap the mic to record your first memory.'),
        ]),
      );
}

class _EmptyMemories extends StatelessWidget {
  const _EmptyMemories();
  @override
  Widget build(BuildContext context) => Card(
        child: Container(
          height: 120,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(16),
          child: const Text('Nothing resurfacing today — your future self will thank you for recording.'),
        ),
      );
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.height});
  final double height;
  @override
  Widget build(BuildContext context) =>
      SizedBox(height: height, child: const Center(child: CircularProgressIndicator()));
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(padding: const EdgeInsets.all(16), child: Text(message)),
      );
}

String _statusLabel(String status) => switch (status) {
      'uploaded' => 'Uploaded — waiting to process',
      'transcribing' => 'Transcribing…',
      'indexed' => 'Ready',
      'failed' => 'Processing failed',
      _ => status,
    };

String _pretty(String ymd) {
  try {
    return DateFormat.yMMMd().format(DateTime.parse(ymd));
  } catch (_) {
    return ymd;
  }
}
