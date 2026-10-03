import 'package:flutter/material.dart';

import 'local_store.dart';

/// The chosen light/dark mode, cached on the device.
///
/// The account owns this setting so a second phone inherits it, but the server
/// copy needs a signed-in user and a round trip — far too late for the first
/// frame. Loading a local copy before `runApp` means the app opens in the right
/// mode instead of flashing the OS default and correcting itself a moment
/// later. The server's copy is a slower second opinion, applied when it lands.
///
/// Follows [DeviceIdentity]: one small value in [LocalStore], resolved once at
/// startup, read synchronously afterwards.
class ThemeModeStore {
  ThemeModeStore._();

  static const _key = 'theme_mode';

  static ThemeMode _cached = ThemeMode.system;

  /// What to paint with. Correct from the first frame because [load] runs
  /// before `runApp`; `system` before that, which is also the default.
  static ThemeMode get cached => _cached;

  /// Unreadable storage leaves `system`, which is a reasonable answer and the
  /// default anyway — never a reason to hold up startup.
  static Future<ThemeMode> load() async {
    final stored = await LocalStore.read(_key);
    return _cached = stored == null ? _cached : decode(stored);
  }

  /// Remember the choice for the next launch. Applying it is the caller's job;
  /// this deliberately does not throw, because a theme that fails to persist is
  /// worth less than a crash.
  static Future<void> save(ThemeMode mode) async {
    _cached = mode;
    // Best effort, as everywhere in [LocalStore]: the in-memory value still
    // applies for this session, only the next launch loses it, and the server
    // copy usually restores it anyway.
    await LocalStore.write(_key, encode(mode));
  }

  static String encode(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  /// Anything unrecognised — a corrupt file, a value from a newer build — means
  /// `system`, so a bad string can never leave the app unreadable.
  static ThemeMode decode(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// Test seam.
  @visibleForTesting
  static void setForTesting(ThemeMode mode) => _cached = mode;
}
