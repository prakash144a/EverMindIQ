import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _languages = <String, String>{
    'auto': 'Match my question',
    'en': 'English',
    'ta': 'Tamil',
    'hi': 'Hindi',
    'fr': 'French',
  };

  Future<void> _save(WidgetRef ref, UserSettings s) async {
    await ref.read(apiClientProvider).saveSettings(s);
    ref.invalidate(settingsProvider);
    ref.invalidate(onThisDayProvider);
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
              onChanged: (v) => _save(ref, s.copyWith(onThisDayEnabled: v)),
            ),
            SwitchListTile(
              title: const Text('Notifications'),
              subtitle: const Text('Get notified when a memory resurfaces'),
              value: s.notificationsEnabled,
              onChanged: (v) => _save(ref, s.copyWith(notificationsEnabled: v)),
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
                  if (v != null) _save(ref, s.copyWith(answerLanguage: v));
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
                onChangeEnd: (v) => _save(ref, s.copyWith(slideshowIntervalSec: v.round())),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
