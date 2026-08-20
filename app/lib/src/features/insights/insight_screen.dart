import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/ai_orb.dart';

/// Shows an AI-generated insight for a range. Custom ranges pass explicit dates.
///
/// The server caches one insight per (range, from, to), and `to` is always
/// today — so the model runs at most once per range per day, and every later
/// visit is served from that cache. The waiting state below therefore only
/// appears on the day's first look, which is exactly when it is worth saying
/// out loud that an AI is reading the period rather than a page failing to load.
class InsightScreen extends ConsumerStatefulWidget {
  const InsightScreen({
    super.key,
    required this.range,
    required this.title,
    this.from,
    this.to,
  });

  final String range;
  final String title;
  final DateTime? from;
  final DateTime? to;

  @override
  ConsumerState<InsightScreen> createState() => _InsightScreenState();
}

class _InsightScreenState extends ConsumerState<InsightScreen> {
  /// Held in state, not started in `build`: a rebuild (theme change, keyboard,
  /// a parent repaint) must not fire a second generation request.
  late final Future<Insight> _future = _load();

  Future<Insight> _load() {
    if (widget.range == 'custom') {
      return ref.read(apiClientProvider).insight('custom', from: widget.from, to: widget.to);
    }
    return ref.read(insightProvider(widget.range).future);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<Insight>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _GeneratingState(title: widget.title);
          }
          if (snap.hasError) {
            return Center(child: Text('Could not load insight: ${snap.error}'));
          }
          final ins = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${_pretty(ins.dateFrom)} – ${_pretty(ins.dateTo)}  ·  ${ins.recordingCount} moment(s)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (ins.themes.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: ins.themes.map((t) => Chip(label: Text(t))).toList(),
                ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    ins.summary.isEmpty ? 'No memories in this period yet.' : ins.summary,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _pretty(String ymd) {
    try {
      return DateFormat.yMMMd().format(DateTime.parse(ymd));
    } catch (_) {
      return ymd;
    }
  }
}

/// The wait. A spinner alone reads as "loading a page that already exists";
/// this says what is actually happening — the model is reading the period —
/// and cycles through the steps so a long wait still looks like progress.
class _GeneratingState extends StatefulWidget {
  const _GeneratingState({required this.title});
  final String title;

  @override
  State<_GeneratingState> createState() => _GeneratingStateState();
}

class _GeneratingStateState extends State<_GeneratingState> {
  static const _steps = <String>[
    'Gathering your memories…',
    'Reading through the period…',
    'Finding the themes that recur…',
    'Writing your summary…',
  ];

  int _step = 0;
  late final Stream<int> _tick = Stream<int>.periodic(
    const Duration(seconds: 4),
    (i) => i + 1,
  ).takeWhile((i) => i < _steps.length);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<int>(
      stream: _tick,
      builder: (context, snap) {
        _step = snap.data ?? _step;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(Insets.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AiOrb(size: 96),
                const SizedBox(height: Insets.xl),
                Text(
                  'Creating your insight',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  'The AI is reading your ${widget.title.toLowerCase()} of memories '
                  'and pulling out what mattered.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
                const SizedBox(height: Insets.xl),
                AnimatedSwitcher(
                  duration: Motion.medium,
                  child: Text(
                    _steps[_step],
                    key: ValueKey(_step),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: Insets.md),
                Text(
                  'This takes a few seconds the first time each day. After that it is instant.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
