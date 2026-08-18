import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme_mode_store.dart';
import 'models.dart';
import 'providers.dart';

/// What the app paints in.
///
/// Seeded synchronously from the on-device cache so the first frame is already
/// right, then reconciled with the account's copy once it arrives. Deliberately
/// does *not* watch [settingsProvider]: that would put a network call above
/// `MaterialApp`, where a slow or failing request would hold up the whole UI.
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier(this._ref) : super(ThemeModeStore.cached);

  final Ref _ref;

  /// Apply and remember, without touching the network.
  void setLocal(ThemeMode mode) {
    if (mode == state) return;
    state = mode;
    // Fire-and-forget: failing to write only costs us the next launch.
    ThemeModeStore.save(mode);
  }

  /// The account's copy arrived. Adopt it, but never write it back — a device
  /// that just changed the mode has already pushed its own value.
  void adoptFromServer(ThemeMode mode) => setLocal(mode);

  /// The user picked a mode. Repaint first, then tell the server, so the
  /// control never waits on a round trip.
  Future<void> set(ThemeMode mode, UserSettings current) async {
    setLocal(mode);
    try {
      await _ref
          .read(apiClientProvider)
          .saveSettings(current.copyWith(themeMode: ThemeModeStore.encode(mode)));
    } catch (_) {
      // The local choice still stands for this session and survives a restart;
      // it just won't reach the user's other devices until the next save.
    } finally {
      _ref.invalidate(settingsProvider);
    }
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
  name: 'themeMode',
);
