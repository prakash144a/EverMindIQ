import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voiceiq/src/app.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/core/theme_mode_store.dart';
import 'package:voiceiq/src/core/tokens.dart';
import 'package:voiceiq/src/data/theme_mode_provider.dart';

void main() {
  group('ThemeModeStore', () {
    test('encodes and decodes every mode', () {
      for (final mode in ThemeMode.values) {
        expect(ThemeModeStore.decode(ThemeModeStore.encode(mode)), mode);
      }
    });

    test('falls back to system for anything unrecognised', () {
      // A corrupt file or a value written by a newer build must never leave the
      // app painting something undefined.
      expect(ThemeModeStore.decode('sepia'), ThemeMode.system);
      expect(ThemeModeStore.decode(null), ThemeMode.system);
      expect(ThemeModeStore.decode(''), ThemeMode.system);
    });
  });

  group('theme mode wiring', () {
    testWidgets('MaterialApp follows the device by default', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: MemoriesIQApp()));
      await tester.pump();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.system);
    });

    testWidgets('choosing a mode repaints without touching the network',
        (tester) async {
      // No apiClient override: setLocal is the whole local path, which is what
      // keeps the app root free of anything that can hang or fail.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MemoriesIQApp(),
        ),
      );
      await tester.pump();

      container.read(themeModeProvider.notifier).setLocal(ThemeMode.dark);
      await tester.pump();

      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
    });
  });

  group('palette', () {
    test('brand colours land on the right side of the light/dark split', () {
      expect(AppTheme.light().colorScheme.primary, AppColors.sage);
      expect(AppTheme.dark().colorScheme.primary, AppColors.sageLight);
      expect(AppTheme.light().colorScheme.tertiary, AppColors.gold);
      expect(AppTheme.dark().colorScheme.tertiary, AppColors.goldLight);
    });

    test('text on brand fills is ink where white would fail contrast', () {
      // White on sageLight is 2.1:1 and on gold 3.0:1 — both below AA. These
      // are not derived from the seed, so nothing else would catch a slip.
      expect(AppTheme.dark().colorScheme.onPrimary, AppColors.ink);
      expect(AppTheme.light().colorScheme.onTertiary, AppColors.ink);
      expect(AppTheme.dark().colorScheme.onTertiary, AppColors.ink);
    });

    test('light keeps white on sage, which does clear AA', () {
      expect(AppTheme.light().colorScheme.onPrimary, Colors.white);
    });
  });
}
