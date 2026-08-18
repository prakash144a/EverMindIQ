import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme_mode_store.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/theme_mode_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _languages = <String, String>{
    'auto': 'Match my question',
    'en': 'English',
    'ta': 'Tamil',
    'hi': 'Hindi',
    'fr': 'French',
  };

  static const _themeModes = <String, String>{
    'system': 'Match my device',
    'light': 'Light',
    'dark': 'Dark',
  };

  Future<void> _save(BuildContext context, WidgetRef ref, UserSettings s) async {
    try {
      await ref.read(apiClientProvider).saveSettings(s);
    } catch (e) {
      // Without this the control silently snaps back on the next rebuild and
      // the user is left guessing whether the change took.
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      ref.invalidate(settingsProvider);
      ref.invalidate(onThisDayProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load settings: $e')),
        data: (s) => ListView(
          children: [
            SwitchListTile(
              title: const Text('On This Day slideshow'),
              subtitle: const Text('Resurface memories from years ago on the home screen'),
              value: s.onThisDayEnabled,
              onChanged: (v) =>
                  _save(context, ref, s.copyWith(onThisDayEnabled: v)),
            ),
            SwitchListTile(
              title: const Text('Notifications'),
              subtitle: const Text('Get notified when a memory resurfaces'),
              value: s.notificationsEnabled,
              onChanged: (v) =>
                  _save(context, ref, s.copyWith(notificationsEnabled: v)),
            ),
            const Divider(),
            ListTile(
              title: const Text('Answer language'),
              subtitle: const Text('Language the AI replies in'),
              trailing: DropdownButton<String>(
                value: _languages.containsKey(s.answerLanguage) ? s.answerLanguage : 'auto',
                items: _languages.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    _save(context, ref, s.copyWith(answerLanguage: v));
                  }
                },
              ),
            ),
            ListTile(
              title: const Text('Appearance'),
              subtitle: const Text('Light or dark, or follow your device'),
              trailing: DropdownButton<String>(
                // Reads what is actually painted rather than the saved value,
                // so the control is right the instant it is tapped — before the
                // save has been round-tripped.
                value: ThemeModeStore.encode(ref.watch(themeModeProvider)),
                items: _themeModes.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    ref
                        .read(themeModeProvider.notifier)
                        .set(ThemeModeStore.decode(v), s);
                  }
                },
              ),
            ),
            const Divider(),
            ListTile(
              title: Text('Slideshow interval: ${s.slideshowIntervalSec}s'),
              subtitle: Slider(
                min: 3,
                max: 15,
                divisions: 12,
                value: s.slideshowIntervalSec.toDouble(),
                label: '${s.slideshowIntervalSec}s',
                onChanged: (v) {},
                onChangeEnd: (v) =>
                    _save(context, ref, s.copyWith(slideshowIntervalSec: v.round())),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
