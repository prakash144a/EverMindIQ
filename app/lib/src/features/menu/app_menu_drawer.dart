import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/initials_avatar.dart';
import '../account/profile_screen.dart';
import '../account/signup_screen.dart';
import '../feedback/feedback_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../settings/settings_screen.dart';
import 'calendar_page.dart';
import 'entities_screen.dart';
import 'export_screen.dart';
import 'insights_screen.dart';
import 'milestones_screen.dart';

/// The app's main navigation drawer — everything beyond Record / Recall / Chat.
class AppMenuDrawer extends ConsumerWidget {
  const AppMenuDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordings = ref.watch(recordingsProvider);
    final count = recordings.maybeWhen(data: (r) => r.length, orElse: () => 0);
    final profile = ref.watch(profileProvider).maybeWhen(
          data: (p) => p,
          orElse: () => const UserProfile(),
        );

    void go(Widget screen) {
      Navigator.of(context).pop();
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => go(profile.hasProfile
                  ? const ProfileScreen()
                  : const SignupScreen()),
              child: Padding(
                padding: const EdgeInsets.all(Insets.xl),
                child: Row(
                  children: [
                    InitialsAvatar(initials: profile.initials),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.preferredName.isEmpty
                                ? 'Your memories'
                                : profile.preferredName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            profile.hasProfile
                                ? '$count moment${count == 1 ? '' : 's'} kept'
                                : 'Tap to save your memories',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                children: [
                  _MenuTile(
                    icon: Icons.calendar_month_outlined,
                    label: 'Timeline & Calendar',
                    onTap: () => go(const CalendarPage()),
                  ),
                  _MenuTile(
                    icon: Icons.insights_outlined,
                    label: 'Insights',
                    onTap: () => go(const InsightsScreen()),
                  ),
                  _MenuTile(
                    icon: Icons.star_outline_rounded,
                    label: 'Milestones',
                    onTap: () => go(const MilestonesScreen()),
                  ),
                  _MenuTile(
                    icon: Icons.tag_outlined,
                    label: 'People, places & tags',
                    onTap: () => go(const EntitiesScreen()),
                  ),
                  const Divider(),
                  _MenuTile(
                    icon: Icons.settings_outlined,
                    label: 'Settings & language',
                    onTap: () => go(const SettingsScreen()),
                  ),
                  _MenuTile(
                    icon: Icons.download_outlined,
                    label: 'Export & backup',
                    onTap: () => go(const ExportScreen()),
                  ),
                  _MenuTile(
                    icon: Icons.help_outline,
                    label: 'How it works',
                    onTap: () => go(const OnboardingScreen()),
                  ),
                  _MenuTile(
                    icon: Icons.bug_report_outlined,
                    label: 'Report a problem',
                    onTap: () => go(const FeedbackScreen()),
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

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Icon(icon, color: scheme.primary, size: 20),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      onTap: onTap,
    );
  }
}
