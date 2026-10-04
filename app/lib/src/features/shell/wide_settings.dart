import 'package:flutter/material.dart';

import '../../core/tokens.dart';
import '../feedback/feedback_screen.dart';
import '../menu/entities_screen.dart';
import '../menu/export_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../settings/settings_screen.dart';

/// Settings on a wide screen: a list of sections down the left, and the chosen
/// one beside it.
///
/// On a phone each of these is its own entry in the menu drawer. Beside a rail
/// there is no drawer, and a "More" button that opens a list of unrelated
/// things is just a drawer with a worse name — so they are gathered here, under
/// the one word people already look for, and moving between them never leaves
/// the page.
///
/// The sections are the phone's screens, shown as they are. Two of them close
/// themselves when they finish, which is right for a screen that was pushed and
/// wrong for one that is part of a page: those are told what to do instead.
class WideSettings extends StatefulWidget {
  const WideSettings({super.key});

  @override
  State<WideSettings> createState() => _WideSettingsState();
}

enum _Section {
  general(Icons.tune_rounded, 'General & language'),
  people(Icons.tag_outlined, 'People, places & tags'),
  export(Icons.download_outlined, 'Export & backup'),
  help(Icons.help_outline, 'How it works'),
  feedback(Icons.bug_report_outlined, 'Report a problem');

  const _Section(this.icon, this.label);

  final IconData icon;
  final String label;
}

class _WideSettingsState extends State<WideSettings> {
  _Section _section = _Section.general;

  void _show(_Section section) => setState(() => _section = section);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 248,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.xl, Insets.md, Insets.lg),
              // No heading of its own: the rail has already said "Settings",
              // and the open section titles itself.
              children: [
                for (final section in _Section.values)
                  _SectionTile(
                    section: section,
                    selected: section == _section,
                    onTap: () => _show(section),
                  ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            // Keyed by section so each starts fresh: a half-written problem
            // report does not reappear after it has been sent.
            child: KeyedSubtree(
              key: ValueKey(_section),
              child: switch (_section) {
                _Section.general => const SettingsScreen(),
                _Section.people => const EntitiesScreen(),
                _Section.export => const ExportScreen(),
                _Section.help => OnboardingScreen(onDone: () => _show(_Section.general)),
                _Section.feedback => FeedbackScreen(onSent: () => _show(_Section.general)),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section, required this.selected, required this.onTap});

  final _Section section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurface;
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Material(
          color: selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: 13),
              child: Row(
                children: [
                  Icon(section.icon, size: 20, color: color),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
