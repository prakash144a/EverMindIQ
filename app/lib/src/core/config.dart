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

  /// The agreement someone accepts by signing in, and the policy beside it.
  /// Both live on the marketing site, which is the one copy of each.
  static const String termsUrl = 'https://memoriesiq.nativemindsai.com/terms.html';
  static const String privacyUrl = 'https://memoriesiq.nativemindsai.com/privacy.html';

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
  /// The live-voice socket, carrying the same two credentials every REST call
  /// does: who you are, and which sign-in this is. A socket without the session
  /// is closed on connect, exactly like a request without it is refused.
  static Uri wsLiveUri(String token, {String sessionId = ''}) {
    final base = Uri.parse(apiBaseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(
      scheme: scheme,
      path: '/live',
      queryParameters: {
        'token': token,
        if (sessionId.isNotEmpty) 'session': sessionId,
      },
    );
  }
}
