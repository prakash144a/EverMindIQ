import 'package:flutter/material.dart';

import '../../core/tokens.dart';
import '../insights/insight_screen.dart';

/// Pick a time range to generate an AI insight over your memories. (Was the
/// left "Insights" drawer; now a proper menu destination.)
class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key});

  static const _ranges = <(String, String, IconData)>[
    ('day', 'Last day', Icons.today),
    ('week', 'Last week', Icons.view_week),
    ('month', 'Last month', Icons.calendar_view_month),
    ('year', 'Last year', Icons.calendar_today),
    ('5y', 'Last 5 years', Icons.history),
    ('lifetime', 'Lifetime', Icons.all_inclusive),
  ];

  @override
  Widget build(BuildContext context) {
    void open(String range, String title, {DateTime? from, DateTime? to}) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InsightScreen(range: range, title: title, from: from, to: to),
      ));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, Insets.sm),
            child: Text(
              'A themed summary of what mattered, over any stretch of time.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          for (final (key, label, icon) in _ranges)
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(key, label),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.date_range),
            title: const Text('Custom range…'),
            onTap: () async {
              final range = await showDateRangePicker(
                context: context,
                firstDate: DateTime(1950),
                lastDate: DateTime.now(),
              );
              if (range != null && context.mounted) {
                open('custom', 'Custom range', from: range.start, to: range.end);
              }
            },
          ),
        ],
      ),
    );
  }
}
