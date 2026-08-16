import 'package:flutter/material.dart';

import '../../core/tokens.dart';

/// Export & backup — surfaces the intent; the data-export pipeline lands in a
/// later phase (see docs/milestones.md, Phase 3).
class ExportScreen extends StatelessWidget {
  const ExportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Export & backup')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(Insets.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_outlined, size: 48, color: scheme.primary),
              const SizedBox(height: Insets.lg),
              Text('Your memories, yours to keep',
                  style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: Insets.sm),
              Text(
                'Download every recording, transcript and summary as a single archive. '
                'Coming in a future update.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Insets.xl),
              const FilledButton.tonal(
                onPressed: null,
                child: Text('Prepare export'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
