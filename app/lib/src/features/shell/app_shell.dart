import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/tokens.dart';
import '../../data/audio_playback.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/hero_action_button.dart';
import '../account/signup_screen.dart';
import '../home/home_screen.dart';
import '../menu/app_menu_drawer.dart';
import '../recall/recall_screen.dart';
import '../record/record_screen.dart';
import '../settings/settings_screen.dart';

/// Opens the record screen and, once something has been captured, refreshes the
/// feed and offers to create a profile.
///
/// Top-level so the Home empty state can start a recording too — the nudge
/// "tap Record to capture your first memory" should be tappable.
Future<void> openRecordScreen(BuildContext context, WidgetRef ref) async {
  // Don't let a playing memory bleed into the new recording.
  await ref.read(audioPlaybackProvider.notifier).stop();
  if (!context.mounted) return;
  final created = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const RecordScreen(), fullscreenDialog: true),
  );
  if (created != true) return;

  ref.invalidate(recordingsProvider);
  ref.invalidate(onThisDayProvider);

  // The moment the first memory exists is the moment it's worth protecting, so
  // this is where we ask — not before the user has seen the app do anything.
  if (!context.mounted) return;
  final profile = await ref.read(profileProvider.future).catchError((_) => const UserProfile());
  if (!context.mounted) return;
  if (!profile.hasProfile && !profile.signupPromptDismissed) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SignupScreen()),
    );
  }
}

/// App scaffold. Home is the single landing surface; the two hero actions —
/// **Record** and **Recall** — live in the bottom dock. Recall itself offers
/// both voice and typed input, so there's no separate chat entry. Everything
/// else lives in the menu.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  Future<void> _openRecord(BuildContext context, WidgetRef ref) async {
    await openRecordScreen(context, ref);
  }

  void _openRecall(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const RecallScreen(), fullscreenDialog: true),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      drawer: const AppMenuDrawer(),
      appBar: AppBar(
        title: const Text(AppConfig.appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: const HomeScreen(),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, Insets.md),
          child: Row(
            children: [
              Expanded(
                child: HeroActionButton(
                  icon: const Icon(Icons.fiber_manual_record),
                  label: 'Record',
                  onTap: () => _openRecord(context, ref),
                ),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: HeroActionButton(
                  icon: const Icon(Icons.search),
                  label: 'Recall',
                  filled: false,
                  onTap: () => _openRecall(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
