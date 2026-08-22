import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session_store.dart';
import 'api_client.dart';
import 'models.dart';
import 'providers.dart';

/// The Firebase Auth instance.
final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

/// Emits the current signed-in user (null when signed out).
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(firebaseAuthProvider).authStateChanges();
});

/// Where the app is, in terms of having an account to show.
enum AuthStage { signedOut, signedIn }

/// Who is signed in on this device, if anyone.
///
/// Identity is the email, not the phone: the server issues one permanent
/// account id per address and mints a credential for it at login. So signing in
/// on a second device shows the same memories, and — because an account may be
/// held by one device at a time — signing in there ends the session here. The
/// [endedReason] is what the old device has to show for itself when that
/// happens; it is the only explanation its user will ever get.
class AuthState {
  final AuthStage stage;

  /// Why this device was signed out, when it was not the user's own doing.
  final SessionEndedException? endedReason;

  const AuthState(this.stage, {this.endedReason});

  bool get isSignedIn => stage == AuthStage.signedIn;
}

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Resolved by `main` before the first frame, so this is a read rather than
    // a race: a stored session plus a live Firebase user means signed in.
    try {
      final user = ref.read(firebaseAuthProvider).currentUser;
      return AuthState(
        user != null && SessionStore.isSignedIn ? AuthStage.signedIn : AuthStage.signedOut,
      );
    } catch (_) {
      // Firebase never came up. Signed out is the honest answer and the only
      // safe one — the alternative is an app that will not open at all.
      return const AuthState(AuthStage.signedOut);
    }
  }

  /// Take a claimed session and become that account on this device.
  Future<void> signIn(SignInResult result) async {
    // Order matters: the session id has to be stored before anything can make a
    // request with it, and the Firebase sign-in is what makes requests possible.
    await SessionStore.save(result.sessionId);
    await ref.read(firebaseAuthProvider).signInWithCustomToken(result.token);
    _resetAccountScopedState();
    state = const AuthState(AuthStage.signedIn);
  }

  /// Hand the device back: tell the server, then forget everything local.
  Future<void> signOut() async {
    try {
      await ref.read(apiClientProvider).logout();
    } catch (_) {
      // Offline, or the session was already gone. Either way this device is
      // done with the account, and refusing to sign out because the network is
      // down would leave someone else's memories on the screen.
    }
    await _forget();
    state = const AuthState(AuthStage.signedOut);
  }

  /// Signed out from elsewhere: another device took the account over.
  Future<void> endedRemotely(SessionEndedException reason) async {
    if (state.stage == AuthStage.signedOut) return;
    await _forget();
    state = AuthState(AuthStage.signedOut, endedReason: reason);
  }

  /// Dismiss the explanation, leaving the plain login screen.
  void acknowledgeEnded() {
    if (state.endedReason != null) state = const AuthState(AuthStage.signedOut);
  }

  Future<void> _forget() async {
    await SessionStore.clear();
    try {
      await ref.read(firebaseAuthProvider).signOut();
    } catch (_) {/* best effort; the session id is already gone */}
    _resetAccountScopedState();
  }

  /// Drop every cached answer that belonged to the previous account.
  ///
  /// One phone, several people: the next person must not see a flash of
  /// someone else's memories while their own load.
  void _resetAccountScopedState() {
    ref.invalidate(profileProvider);
    ref.invalidate(recordingsProvider);
    ref.invalidate(onThisDayProvider);
    ref.invalidate(journalsProvider);
    ref.invalidate(settingsProvider);
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);
