import 'local_store.dart';

/// Stands in for Firebase when the app is pointed at the **mock backend**.
///
/// Turned on with `--dart-define=MOCK_AUTH=true` and off in every build that
/// does not say so, which is every build that ships.
///
/// It exists because mock mode has no Firebase at all: the "custom token" a
/// mock login returns is the uid itself (`services/identity.mint_token`), and
/// the mock API reads a bearer token as the uid to match. Handing that string
/// to `signInWithCustomToken` asks the *real* Firebase project to verify a
/// credential it never issued, which fails — so running the app against a local
/// backend meant never getting past the login screen. This keeps the mock token
/// and presents it as the bearer, leaving the rest of the flow — the emailed
/// code, the ticket, the session, the takeover question — exactly as it is in
/// production, because those are the parts worth exercising locally.
///
/// Persisted like the session it belongs to, so a reload does not sign a
/// developer out on every change.
class DevAuth {
  DevAuth._();

  /// Compile-time, so a release build has no branch to reach: the tree shaker
  /// removes the alternative outright.
  static const bool enabled = bool.fromEnvironment('MOCK_AUTH');

  static const _key = 'dev_token';

  static String _token = '';

  /// The mock credential, or empty when nobody is signed in.
  static String get token => _token;

  static bool get isSignedIn => enabled && _token.isNotEmpty;

  /// Read at startup beside the session id, for the same reason: the first
  /// request must not race ahead of the credential it needs.
  static Future<void> load() async {
    if (!enabled) return;
    _token = await LocalStore.read(_key) ?? '';
  }

  static Future<void> save(String token) async {
    if (!enabled) return;
    _token = token.trim();
    await LocalStore.write(_key, _token);
  }

  static Future<void> clear() async {
    if (!enabled) return;
    _token = '';
    await LocalStore.delete(_key);
  }
}
