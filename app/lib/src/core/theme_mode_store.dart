import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// The chosen light/dark mode, cached on the device.
///
/// The account owns this setting so a second phone inherits it, but the server
/// copy needs a signed-in user and a round trip — far too late for the first
/// frame. Loading a local copy before `runApp` means the app opens in the right
/// mode instead of flashing the OS default and correcting itself a moment
/// later. The server's copy is a slower second opinion, applied when it lands.
///
/// Follows [DeviceIdentity]: a plain file via `path_provider`, resolved once at
/// startup, read synchronously afterwards.
class ThemeModeStore {
  ThemeModeStore._();

  static const _fileName = 'theme_mode';

  static ThemeMode _cached = ThemeMode.system;

  /// What to paint with. Correct from the first frame because [load] runs
  /// before `runApp`; `system` before that, which is also the default.
  static ThemeMode get cached => _cached;

  static Future<ThemeMode> load() async {
    try {
      final file = File('${(await getApplicationSupportDirectory()).path}/$_fileName');
      if (await file.exists()) {
        return _cached = decode((await file.readAsString()).trim());
      }
    } catch (_) {
      // No readable storage. `system` is a reasonable answer, and it is the
      // default anyway — never a reason to hold up startup.
    }
    return _cached;
  }

  /// Remember the choice for the next launch. Applying it is the caller's job;
  /// this deliberately does not throw, because a theme that fails to persist is
  /// worth less than a crash.
  static Future<void> save(ThemeMode mode) async {
    _cached = mode;
    try {
      final file = File('${(await getApplicationSupportDirectory()).path}/$_fileName');
      await file.create(recursive: true);
      await file.writeAsString(encode(mode), flush: true);
    } catch (_) {
      // The in-memory value still applies for this session; only the next
      // launch loses it, and the server copy usually restores it anyway.
    }
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
