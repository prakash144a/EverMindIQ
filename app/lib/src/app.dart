import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config.dart';
import 'core/theme.dart';
import 'core/theme_mode_store.dart';
import 'data/auth.dart';
import 'data/models.dart';
import 'data/providers.dart';
import 'data/theme_mode_provider.dart';
import 'features/account/login_screen.dart';
import 'features/shell/app_shell.dart';

class MemoriesIQApp extends ConsumerWidget {
  const MemoriesIQApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Reads the on-device cache, which `main` resolved before the first
      // frame; the account's copy is adopted later by [_SettingsSync].
      themeMode: ref.watch(themeModeProvider),
      home: const _AuthGate(),
    );
  }
}

/// Login, or the app. Nothing in between.
///
/// The memories belong to an email address rather than to this phone, so there
/// is nothing to show until someone says which account they are — and when that
/// account is opened on another device, this falls back here carrying the
/// explanation for why.
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return switch (auth.stage) {
      AuthStage.signedOut => LoginScreen(notice: auth.endedReason),
      AuthStage.signedIn => const _SettingsSync(child: AppShell()),
    };
  }
}

/// Applies the account's saved theme once settings load.
///
/// Sits below the auth gate on purpose: settings need a signed-in user, and the
/// app must not wait on that to paint. Until this runs, the device's cached
/// choice is already showing — so on every launch after the first, adopting the
/// server value is a no-op the user never sees.
class _SettingsSync extends ConsumerWidget {
  const _SettingsSync({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AsyncValue<UserSettings>>(settingsProvider, (_, next) {
      final settings = next.valueOrNull;
      if (settings != null) {
        ref
            .read(themeModeProvider.notifier)
            .adoptFromServer(ThemeModeStore.decode(settings.themeMode));
      }
    });
    // Starts the fetch and keeps it alive; the listener above fires on the
    // loading -> data transition.
    ref.watch(settingsProvider);
    return child;
  }
}
