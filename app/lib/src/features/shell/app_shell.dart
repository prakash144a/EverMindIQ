import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../calendar/calendar_screen.dart';
import '../home/home_screen.dart';
import '../insights/insights_drawer.dart';
import '../record/record_sheet.dart';
import '../settings/settings_screen.dart';
import '../talk/talk_screen.dart';

/// App scaffold: bottom bar (Home · Calendar · [Record] · Talk) + Insights drawer.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  static const _titles = ['VoiceIQ', 'Calendar', 'Talk to AI'];

  final _pages = const [HomeScreen(), CalendarScreen(), TalkScreen()];

  /// Central action menu: capture a new moment, or jump to Talk to recall past ones.
  Future<void> _openActionMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.mic)),
              title: const Text('Record a moment'),
              subtitle: const Text('Capture a memory by voice'),
              onTap: () => Navigator.pop(context, 'record'),
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.forum)),
              title: const Text('Recall Moments'),
              subtitle: const Text('Talk to AI for insights about your moments'),
              onTap: () => Navigator.pop(context, 'recall'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'record') {
      await _openRecordSheet();
    } else if (action == 'recall') {
      setState(() => _index = 2);
    }
  }

  Future<void> _openRecordSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const RecordSheet(),
    );
    if (created == true && mounted) {
      // Refresh the data-backed screens.
      ref.invalidate(recordingsProvider);
      ref.invalidate(onThisDayProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(_titles[_index]),
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
      drawer: const InsightsDrawer(),
      body: IndexedStack(index: _index, children: _pages),
      floatingActionButton: FloatingActionButton.large(
        onPressed: _openActionMenu,
        tooltip: 'Record or recall a moment',
        child: const Icon(Icons.add, size: 32),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavButton(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home,
              label: 'Home',
              selected: _index == 0,
              onTap: () => setState(() => _index = 0),
            ),
            _NavButton(
              icon: Icons.calendar_month_outlined,
              selectedIcon: Icons.calendar_month,
              label: 'Calendar',
              selected: _index == 1,
              onTap: () => setState(() => _index = 1),
            ),
            const SizedBox(width: 48), // notch gap for the FAB
            _NavButton(
              icon: Icons.forum_outlined,
              selectedIcon: Icons.forum,
              label: 'Talk',
              selected: _index == 2,
              onTap: () => setState(() => _index = 2),
            ),
            _NavButton(
              icon: Icons.insights_outlined,
              selectedIcon: Icons.insights,
              label: 'Insights',
              selected: false,
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected ? selectedIcon : icon, color: color, size: 24),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
