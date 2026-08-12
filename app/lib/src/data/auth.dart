import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Firebase Auth instance.
final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

/// Emits the current signed-in user (null before sign-in completes).
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(firebaseAuthProvider).authStateChanges();
});

/// Ensures a signed-in user exists (anonymous auth for now) and returns it.
///
/// The backend runs in real mode and verifies a Firebase ID token on every
/// request, so we must have a user before the app makes any call. Anonymous
/// accounts can later be linked to Google/email without changing the uid, so
/// a user's recordings stay attached to the same identity.
final ensureSignedInProvider = FutureProvider<User>((ref) async {
  final auth = ref.watch(firebaseAuthProvider);
  final existing = auth.currentUser;
  if (existing != null) return existing;
  final cred = await auth.signInAnonymously();
  return cred.user!;
});
