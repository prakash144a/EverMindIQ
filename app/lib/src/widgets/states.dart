import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../features/feedback/feedback_screen.dart';

/// Shared loading / error / empty states, replacing the duplicated private
/// `_LoadingCard` / `_ErrorCard` / `_EmptyState` widgets across features.

class AppLoadingCard extends StatelessWidget {
  const AppLoadingCard({super.key, this.height = 140});
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: const Center(child: CircularProgressIndicator()),
      );
}

class AppErrorCard extends StatelessWidget {
  const AppErrorCard(this.message, {super.key, this.canReport = true});

  final String message;

  /// Offers a "Report" action that opens the feedback form with this error
  /// prefilled. On by default so every failure the user sees is reportable.
  final bool canReport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
                ),
              ],
            ),
            if (canReport)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: Icon(Icons.bug_report_outlined,
                      size: 18, color: scheme.onErrorContainer),
                  label: Text('Report', style: TextStyle(color: scheme.onErrorContainer)),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FeedbackScreen(prefillMessage: message),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? title;

  /// Optional call to action — an empty state that tells you what to do next
  /// should let you do it.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxl, horizontal: Insets.lg),
      child: Column(
        children: [
          Icon(icon, size: 48, color: scheme.primary.withValues(alpha: 0.7)),
          const SizedBox(height: Insets.md),
          if (title != null) ...[
            Text(title!, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Insets.xs),
          ],
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: Insets.md),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
