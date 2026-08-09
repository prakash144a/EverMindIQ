import 'package:flutter/material.dart';

import 'insight_screen.dart';

/// Left drawer: pick a time range to generate AI insights over your memories.
class InsightsDrawer extends StatelessWidget {
  const InsightsDrawer({super.key});

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
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(Icons.insights),
                  const SizedBox(width: 12),
                  Text('Insights', style: Theme.of(context).textTheme.headlineSmall),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final (key, label, icon) in _ranges)
                    ListTile(
                      leading: Icon(icon),
                      title: Text(label),
                      onTap: () {
                        Navigator.of(context).pop(); // close drawer
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => InsightScreen(range: key, title: label),
                        ));
                      },
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
                        Navigator.of(context).pop();
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => InsightScreen(
                            range: 'custom',
                            title: 'Custom range',
                            from: range.start,
                            to: range.end,
                          ),
                        ));
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
