import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/initials_avatar.dart';
import '../account/profile_screen.dart';
import '../home/home_screen.dart';
import '../journals/journals_screen.dart';
import '../menu/calendar_page.dart';
import '../menu/insights_screen.dart';
import '../menu/milestones_screen.dart';
import '../recall/recall_screen.dart';
import 'app_shell.dart';
import 'wide_settings.dart';

/// The app on a wide screen: a navigation rail, and the page beside it.
///
/// * The **rail** holds the places that hide in the menu on a phone, and
///   stays put whatever the page is.
/// * **Home** opens with the two things the app is for — Record and Recall —
///   and the recent memories under them. Each of the two opens its own page.
/// * Everything else that was in the menu lives on the **Settings** page,
///   which has a list of its own down its left side.
///
/// The screens themselves are the phone's, unchanged; this only arranges them.
/// That is deliberate: one set of screens to keep working, and a window dragged
/// narrower than [breakpoint] simply becomes the phone layout again.
class WideShell extends ConsumerStatefulWidget {
  const WideShell({super.key});

  /// Narrower than this and the phone layout is the better use of the space.
  static const double breakpoint = 1100;

  /// The widest an ordinary page grows. Past this a line of text is too long
  /// to read comfortably, so the extra width becomes margin.
  static const double contentMaxWidth = 920;

  @override
  ConsumerState<WideShell> createState() => _WideShellState();
}

/// The rail's destinations. Each replaces what the page area shows.
enum _Place { home, timeline, journals, milestones, insights, settings, profile }

class _WideShellState extends ConsumerState<WideShell> {
  final _content = GlobalKey<NavigatorState>();
  _Place _place = _Place.home;

  void _go(_Place place) {
    setState(() => _place = place);
    _content.currentState?.pushAndRemoveUntil(_page(place), (_) => false);
  }

  /// No transition: switching places from a rail is a change of subject, not a
  /// step deeper, and sliding a whole page sideways says the opposite.
  Route<void> _page(_Place place) => PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => _Centered(
          child: switch (place) {
            _Place.home => const _WideHome(),
            _Place.timeline => const CalendarPage(),
            _Place.journals => const JournalsScreen(),
            _Place.milestones => const MilestonesScreen(),
            _Place.insights => const InsightsScreen(),
            _Place.settings => const WideSettings(),
            _Place.profile => const ProfileScreen(),
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Rail(current: _place, onGo: _go),
            VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
            Expanded(
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                // Every page pushed in here — by the rail, or by a screen
                // opening a memory or a journal — is laid out by
                // [_PageTransitions], which is what keeps ordinary pages to a
                // readable width without each screen having to know about it.
                child: Theme(
                  data: theme.copyWith(
                    pageTransitionsTheme: PageTransitionsTheme(
                      builders: {
                        for (final platform in TargetPlatform.values)
                          platform: const _PageTransitions(),
                      },
                    ),
                  ),
                  child: ClipRect(
                    child: Navigator(
                      key: _content,
                      onGenerateInitialRoutes: (_, __) => [_page(_Place.home)],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An ordinary page: centred, and no wider than is comfortable to read.
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: WideShell.contentMaxWidth),
        child: child,
      ),
    );
  }
}

/// How a page pushed beside the rail is laid out and brought in.
///
/// Two kinds of page arrive here. Ordinary ones — a memory, a journal, a list
/// — are centred in a readable column. The immersive ones, Record and Recall,
/// are pushed as full-screen dialogs and paint their own dark ground; those get
/// the whole area, edge to edge, and keep their contents to a column
/// themselves. Deciding it here, by the kind of route, means a screen that
/// opens another screen does not have to know it is on a wide display.
class _PageTransitions extends PageTransitionsBuilder {
  const _PageTransitions();

  static const _motion = FadeUpwardsPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _motion.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      route.fullscreenDialog ? child : _Centered(child: child),
    );
  }
}

/// Home beside the rail: what to do, then what was done.
class _WideHome extends ConsumerWidget {
  const _WideHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            Row(
              children: [
                Expanded(
                  child: _HomeAction(
                    filled: true,
                    icon: Icons.fiber_manual_record,
                    title: 'Record',
                    subtitle: 'Write or speak a memory',
                    onTap: () => openRecordScreen(context, ref),
                  ),
                ),
                const SizedBox(width: Insets.lg),
                Expanded(
                  child: _HomeAction(
                    icon: Icons.search,
                    title: 'Recall',
                    subtitle: 'Ask your memories anything',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RecallScreen(),
                        fullscreenDialog: true,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One of Home's two doors. Large on purpose: these are the app.
class _HomeAction extends StatelessWidget {
  const _HomeAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// The solid sage one. Record is filled and Recall is not, as in the phone's
  /// dock: equal in size, and one of them is where a visit usually starts.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = filled ? Colors.white : scheme.onSurface;
    final soft = filled ? Colors.white.withValues(alpha: 0.82) : scheme.onSurfaceVariant;
    final radius = BorderRadius.circular(Radii.lg);

    return Semantics(
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: filled ? AppColors.heroWash : null,
            color: filled ? null : scheme.surface,
            borderRadius: radius,
            border: filled ? null : Border.all(color: scheme.outlineVariant),
          ),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(Insets.xl),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled
                          ? Colors.white.withValues(alpha: 0.18)
                          : scheme.primary.withValues(alpha: 0.12),
                    ),
                    child: Icon(icon, color: filled ? Colors.white : scheme.primary, size: 24),
                  ),
                  const SizedBox(width: Insets.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(color: ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: soft, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_rounded, color: soft),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Rail extends ConsumerWidget {
  const _Rail({required this.current, required this.onGo});

  final _Place current;
  final ValueChanged<_Place> onGo;

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
          place(_Place.settings, Icons.settings_outlined, 'Settings'),
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
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
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
            child: SizedBox(
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
            ),
          ),
        ),
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
