import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/tokens.dart';
import '../../data/audio_playback.dart';
import '../../data/providers.dart';
import '../../widgets/hero_action_button.dart';
import '../home/home_screen.dart';
import '../menu/app_menu_drawer.dart';
import '../recall/recall_screen.dart';
import '../record/record_screen.dart';
import '../settings/settings_screen.dart';
import 'wide_shell.dart';

/// Opens the record screen and, once something has been captured, refreshes the
/// feed.
///
/// Top-level so the Home empty state can start a recording too — the nudge
/// "tap Record to capture your first memory" should be tappable.
///
/// It used to end by asking the user to create an account, because until then
/// their memories lived on the phone alone. Nothing reaches this screen without
/// an account any more, so there is nothing left to ask.
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
}

/// App scaffold. Home is the single landing surface; the two hero actions —
/// **Record** and **Recall** — live in the bottom dock. Recall itself offers
/// both voice and typed input, so there's no separate chat entry. Everything
/// else lives in the menu.
///
/// That is the phone's layout, and on a phone-sized window it is unchanged. On
/// a wide one the same screens sit beside a navigation rail instead — see
/// [WideShell] — because a layout built for a thumb, stretched across a
/// monitor, hides nine destinations behind a menu and spends the rest of the
/// width on two enormous buttons.
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
    return LayoutBuilder(
      builder: (context, box) =>
          box.maxWidth >= WideShell.breakpoint ? const WideShell() : _phone(context, ref),
    );
  }

  Widget _phone(BuildContext context, WidgetRef ref) {
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
