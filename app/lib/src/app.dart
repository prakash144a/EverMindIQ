import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config.dart';
import 'core/theme.dart';
import 'core/theme_mode_store.dart';
import 'data/auth.dart';
import 'data/models.dart';
import 'data/providers.dart';
import 'data/theme_mode_provider.dart';
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

/// Signs the user in before showing the app. The backend requires a real
/// Firebase ID token, so we must have a user before any request is made.
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signIn = ref.watch(ensureSignedInProvider);
    return signIn.when(
      data: (_) => const _SettingsSync(child: AppShell()),
      loading: () => const _SplashScreen(),
      error: (e, _) => _SignInErrorScreen(
        error: e,
        onRetry: () => ref.invalidate(ensureSignedInProvider),
      ),
    );
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

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _SignInErrorScreen extends StatelessWidget {
  const _SignInErrorScreen({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              const Text('Could not sign in',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
