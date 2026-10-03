import 'package:flutter/foundation.dart';

import 'local_store.dart';

/// This device's hold on an account, remembered across launches.
///
/// The account id no longer comes from the phone, so something has to say which
/// *sign-in* the app is running under: the server issues one session per login
/// and refuses any request that does not carry a live one. An account holds one
/// session per surface — one phone, one browser — so the phone and the tab can
/// each be holding their own, and neither reads the other's.
///
/// Deliberately not stored with [DeviceIdentity]'s install id, which answers a
/// different question. The install id says which device this is and survives
/// signing out; this says who is signed in on it, and must not.
class SessionStore {
  SessionStore._();

  static const _key = 'session_id';

  static String _sessionId = '';

  /// The live session id, or an empty string when nobody is signed in.
  static String get sessionId => _sessionId;

  static bool get isSignedIn => _sessionId.isNotEmpty;

  /// Read the stored session, if this device is still holding one.
  ///
  /// Resolved at startup alongside the install id, so the first request cannot
  /// race ahead of it and be refused for carrying no session. Unreadable
  /// storage reads as signed out: asking someone to log in again is a far
  /// better failure than locking them out of a working app.
  static Future<String> load() async => _sessionId = await LocalStore.read(_key) ?? '';

  static Future<void> save(String id) async {
    _sessionId = id.trim();
    await LocalStore.write(_key, _sessionId);
  }

  /// Forget the session — signing out, or being signed out from elsewhere.
  static Future<void> clear() async {
    _sessionId = '';
    await LocalStore.delete(_key);
  }

  /// Test seam.
  @visibleForTesting
  static void setForTesting(String value) => _sessionId = value;
}
