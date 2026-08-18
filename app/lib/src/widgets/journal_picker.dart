import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/tokens.dart';
import '../data/models.dart';
import '../data/providers.dart';

/// The palette a journal's `colorIndex` points into.
///
/// Fixed and small on purpose: the point of the colour is to make a journal
/// recognisable at a glance in a list, not to be decorated.
const journalColors = <Color>[
  AppColors.violet,
  Color(0xFF2E9E7B), // green
  Color(0xFFD97706), // amber
  Color(0xFFDC5A7B), // rose
  Color(0xFF3B82C4), // blue
  Color(0xFF8B6CB8), // plum
];

Color journalColor(int index) => journalColors[index.abs() % journalColors.length];

/// What a picker returned. `null` from the sheet means the user backed out
/// without choosing, which is different from choosing Unfiled — hence a result
/// object rather than a bare `String?`.
class JournalChoice {
  const JournalChoice(this.journalId);
  final String journalId;

  bool get isUnfiled => journalId.isEmpty;
}

/// Choose the journal a memory is filed in.
///
/// Returns null if dismissed. Used from the record screen, the memory detail
/// screen and the Recall scope chip, so the "which journal?" question looks and
/// behaves identically wherever it is asked.
Future<JournalChoice?> pickJournal(
  BuildContext context, {
  required String? selectedId,
  String unfiledLabel = 'Unfiled',
  String title = 'File in a journal',
}) {
  return showModalBottomSheet<JournalChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _JournalPickerSheet(
      selectedId: selectedId,
      unfiledLabel: unfiledLabel,
      title: title,
    ),
  );
}

class _JournalPickerSheet extends ConsumerWidget {
  const _JournalPickerSheet({
    required this.selectedId,
    required this.unfiledLabel,
    required this.title,
  });

  final String? selectedId;
  final String unfiledLabel;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journals = ref.watch(journalsProvider);
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.sm),
              child: Text(title, style: Theme.of(context).textTheme.titleMedium),
            ),
            Flexible(
              child: journals.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(Insets.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(Insets.xl),
                  child: Text('Could not load journals: $e', style: TextStyle(color: scheme.error)),
                ),
                data: (items) => ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  children: [
                    _Row(
                      icon: Icons.inbox_outlined,
                      color: scheme.onSurfaceVariant,
                      label: unfiledLabel,
                      selected: selectedId != null && selectedId!.isEmpty,
                      onTap: () => Navigator.of(context).pop(const JournalChoice('')),
                    ),
                    for (final j in items)
                      _Row(
                        icon: Icons.book_outlined,
                        color: journalColor(j.colorIndex),
                        label: j.name,
                        selected: j.id == selectedId,
                        onTap: () => Navigator.of(context).pop(JournalChoice(j.id)),
                      ),
                    if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.sm, Insets.xl, 0),
                        child: Text(
                          'You have no journals yet. Create one from the menu to sort '
                          'your memories by what they are about.',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: JournalDot(icon: icon, color: color),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
      onTap: onTap,
    );
  }
}

/// The small coloured badge that stands for a journal, shared by the picker,
/// the journals list and the memory detail row.
class JournalDot extends StatelessWidget {
  const JournalDot({super.key, required this.icon, required this.color, this.size = 38});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Icon(icon, color: color, size: size * 0.53),
    );
  }
}

/// The name of the journal a memory is filed in, or null when it is unfiled or
/// the journals have not loaded. Kept here so every screen phrases it the same.
String? journalNameFor(WidgetRef ref, String journalId) {
  if (journalId.isEmpty) return null;
  final items = ref.watch(journalsProvider).valueOrNull;
  if (items == null) return null;
  for (final j in items) {
    if (j.id == journalId) return j.name;
  }
  return null;
}

/// The journal a memory is filed in, if it is filed and the list has loaded.
Journal? journalFor(WidgetRef ref, String journalId) {
  if (journalId.isEmpty) return null;
  final items = ref.watch(journalsProvider).valueOrNull;
  if (items == null) return null;
  for (final j in items) {
    if (j.id == journalId) return j;
  }
  return null;
}
