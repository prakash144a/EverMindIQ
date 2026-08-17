/// App configuration, overridable at build time via --dart-define.
///
/// Example:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 --dart-define=DEV_UID=alice
class AppConfig {
  /// The product name users see.
  ///
  /// The Dart package, the backend service, the `VOICEIQ_` env prefix and every
  /// GCP resource stay "VoiceIQ" on purpose — that is the internal name. This is
  /// the brand, and it is the only spelling that should ever reach a screen.
  static const String appName = 'MemoriesIQ';

  /// REST base URL. Android emulator reaches host localhost via 10.0.2.2.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  /// Dev-only user id used as the bearer token while Firebase Auth is wired up.
  /// In production this is replaced by a real Firebase ID token.
  static const String devUid = String.fromEnvironment(
    'DEV_UID',
    defaultValue: 'demo-user',
  );

  /// Build identifier attached to problem reports. Set in CI via
  /// `--dart-define=APP_VERSION=1.2.3+45`.
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: 'dev',
  );

  /// WebSocket URL for the `/live` chat channel, authenticated with [token]
  /// (a Firebase ID token; the backend verifies it in real mode).
  static Uri wsLiveUri(String token) {
    final base = Uri.parse(apiBaseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(scheme: scheme, path: '/live', queryParameters: {'token': token});
  }
}
