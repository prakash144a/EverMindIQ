import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../data/providers.dart';

/// Shows an AI-generated insight for a range. Custom ranges pass explicit dates.
class InsightScreen extends ConsumerWidget {
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

  Future<Insight> _load(WidgetRef ref) {
    if (range == 'custom') {
      return ref.read(apiClientProvider).insight('custom', from: from, to: to);
    }
    return ref.read(insightProvider(range).future);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<Insight>(
        future: _load(ref),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
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
