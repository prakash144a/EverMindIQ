import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/content_navigator.dart';
import '../../widgets/initials_avatar.dart';
import '../account/profile_screen.dart';
import '../feedback/feedback_screen.dart';
import '../home/home_screen.dart';
import '../journals/journals_screen.dart';
import '../menu/calendar_page.dart';
import '../menu/entities_screen.dart';
import '../menu/export_screen.dart';
import '../menu/insights_screen.dart';
import '../menu/milestones_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../recall/recall_screen.dart';
import '../settings/settings_screen.dart';
import 'quick_composer.dart';

/// The app on a wide screen: three panes instead of one.
///
/// * A slim **rail** with the places that used to hide in the menu.
/// * The **memories** in the middle — the feed, with a composer at the top of
///   it, and anything opened from it (a memory, a journal, the capture screen)
///   appearing in this same pane.
/// * **Recall**, always open on the right, so asking about a memory does not
///   mean leaving the memories.
///
/// The screens themselves are the phone's, unchanged; this only arranges them.
/// That is deliberate: one set of screens to keep working, and a window dragged
/// narrower than [breakpoint] simply becomes the phone layout again.
class WideShell extends ConsumerStatefulWidget {
  const WideShell({super.key});

  /// Narrower than this and three panes stop fitting: the rail, a readable
  /// column of memories, and a conversation wide enough to read.
  static const double breakpoint = 1100;

  /// The widest the middle pane's content grows. Past this a line of text is
  /// too long to read comfortably, so the extra width becomes margin.
  static const double contentMaxWidth = 920;

  @override
  ConsumerState<WideShell> createState() => _WideShellState();
}

/// The rail's own destinations. Each replaces what the middle pane shows.
enum _Place { home, timeline, journals, milestones, insights, profile }

/// The rest of the old menu. Each opens over the current place, with a way back.
enum _More { people, export, help, feedback, settings }

class _WideShellState extends ConsumerState<WideShell> {
  final _content = GlobalKey<NavigatorState>();
  _Place _place = _Place.home;

  void _go(_Place place) {
    setState(() => _place = place);
    _content.currentState?.pushAndRemoveUntil(_page(place), (_) => false);
  }

  void _open(_More more) {
    _content.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => switch (more) {
          _More.people => const EntitiesScreen(),
          _More.export => const ExportScreen(),
          _More.help => const OnboardingScreen(),
          _More.feedback => const FeedbackScreen(),
          _More.settings => const SettingsScreen(),
        },
      ),
    );
  }

  /// No transition: switching places from a rail is a change of subject, not a
  /// step deeper, and sliding a whole pane sideways says the opposite.
  Route<void> _page(_Place place) => PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => switch (place) {
          _Place.home => const _WideHome(),
          _Place.timeline => const CalendarPage(),
          _Place.journals => const JournalsScreen(),
          _Place.milestones => const MilestonesScreen(),
          _Place.insights => const InsightsScreen(),
          _Place.profile => const ProfileScreen(),
        },
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ContentNavigator(
      navigatorKey: _content,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final recallWidth = (box.maxWidth * 0.3).clamp(380.0, 460.0);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Rail(current: _place, onGo: _go, onMore: _open),
                  VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
                  Expanded(
                    child: ColoredBox(
                      color: theme.scaffoldBackgroundColor,
                      child: Center(
                        child: ConstrainedBox(
                          constraints:
                              const BoxConstraints(maxWidth: WideShell.contentMaxWidth),
                          child: ClipRect(
                            child: Navigator(
                              key: _content,
                              onGenerateInitialRoutes: (_, __) => [_page(_Place.home)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: recallWidth, child: const RecallScreen(embedded: true)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Home, as the middle pane shows it: a title and the composer, then the feed.
class _WideHome extends StatelessWidget {
  const _WideHome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: HomeScreen(
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Insets.lg),
            Text('Your memories', style: theme.textTheme.headlineMedium),
            const SizedBox(height: Insets.xs),
            Text(
              DateFormat('EEEE, d MMMM').format(DateTime.now()),
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.xl),
            const QuickComposer(),
          ],
        ),
      ),
    );
  }
}

class _Rail extends ConsumerWidget {
  const _Rail({required this.current, required this.onGo, required this.onMore});

  final _Place current;
  final ValueChanged<_Place> onGo;
  final ValueChanged<_More> onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider).maybeWhen(
          data: (p) => p,
          orElse: () => const UserProfile(),
        );

    Widget place(_Place place, IconData icon, String label) => _RailItem(
          icon: icon,
          label: label,
          selected: current == place,
          onTap: () => onGo(place),
        );

    return Container(
      width: 88,
      color: scheme.surface,
      padding: const EdgeInsets.symmetric(vertical: Insets.lg),
      child: Column(
        children: [
          const _Mark(),
          const SizedBox(height: Insets.lg),
          place(_Place.home, Icons.home_outlined, 'Home'),
          place(_Place.timeline, Icons.calendar_month_outlined, 'Timeline'),
          place(_Place.journals, Icons.book_outlined, 'Journals'),
          place(_Place.milestones, Icons.star_outline_rounded, 'Milestones'),
          place(_Place.insights, Icons.insights_outlined, 'Insights'),
          PopupMenuButton<_More>(
            tooltip: 'More',
            position: PopupMenuPosition.over,
            offset: const Offset(80, 0),
            onSelected: onMore,
            itemBuilder: (_) => const [
              PopupMenuItem(value: _More.people, child: Text('People, places & tags')),
              PopupMenuItem(value: _More.export, child: Text('Export & backup')),
              PopupMenuItem(value: _More.settings, child: Text('Settings & language')),
              PopupMenuDivider(),
              PopupMenuItem(value: _More.help, child: Text('How it works')),
              PopupMenuItem(value: _More.feedback, child: Text('Report a problem')),
            ],
            // Not a button of its own: the popup menu is already the tap target.
            child: const _RailLabel(icon: Icons.more_horiz_rounded, label: 'More'),
          ),
          const Spacer(),
          Tooltip(
            message: profile.preferredName.isEmpty ? 'Your profile' : profile.preferredName,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onGo(_Place.profile),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: 2,
                    color: current == _Place.profile ? scheme.primary : Colors.transparent,
                  ),
                ),
                child: InitialsAvatar(initials: profile.initials, size: 40),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Material(
          color: selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: onTap,
            child: _RailLabel(icon: icon, label: label, selected: selected),
          ),
        ),
      ),
    );
  }
}

class _RailLabel extends StatelessWidget {
  const _RailLabel({required this.icon, required this.label, this.selected = false});

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return SizedBox(
      width: 76,
      height: 58,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// The app's mark, drawn rather than loaded: the same rings as the icon.
class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: AppColors.heroWash,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
