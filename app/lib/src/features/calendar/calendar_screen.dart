import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../memory/memory_detail_screen.dart';

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final recordings = ref.watch(recordingsProvider);

    return recordings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load: $e')),
      data: (recs) {
        final byDay = <DateTime, List<Recording>>{};
        for (final r in recs) {
          final d = DateTime(r.eventDateTime.year, r.eventDateTime.month, r.eventDateTime.day);
          byDay.putIfAbsent(d, () => []).add(r);
        }
        final dayItems = byDay[DateTime(_selected.year, _selected.month, _selected.day)] ?? const [];

        return Column(
          children: [
            TableCalendar<Recording>(
              firstDay: DateTime.utc(2000, 1, 1),
              lastDay: DateTime.now().add(const Duration(days: 1)),
              focusedDay: _focused,
              selectedDayPredicate: (d) => _sameDay(d, _selected),
              eventLoader: (d) =>
                  byDay[DateTime(d.year, d.month, d.day)] ?? const [],
              onDaySelected: (selected, focused) {
                setState(() {
                  _selected = selected;
                  _focused = focused;
                });
              },
              calendarStyle: CalendarStyle(
                markerDecoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: dayItems.isEmpty
                  ? Center(
                      child: Text('No recordings on ${DateFormat.yMMMd().format(_selected)}'),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: dayItems.length,
                      itemBuilder: (_, i) {
                        final r = dayItems[i];
                        return ListTile(
                          leading: Icon(r.isMilestone
                              ? Icons.star
                              : (r.hasAudio ? Icons.graphic_eq : Icons.notes_rounded)),
                          title: Text(r.title.isEmpty ? 'Untitled moment' : r.title),
                          subtitle: Text(
                            r.summary.isEmpty ? r.transcript : r.summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => openMemoryDetail(context, r.id),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
