import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// This device's hold on an account, remembered across launches.
///
/// The account id no longer comes from the phone, so something has to say which
/// *sign-in* the app is running under: the server issues one session per login
/// and refuses any request that does not carry the live one.
///
/// Deliberately not stored with [DeviceIdentity]'s install id, which answers a
/// different question. The install id says which phone this is and survives
/// signing out; this says who is signed in on it, and must not.
class SessionStore {
  SessionStore._();

  static const _fileName = 'session_id';

  static String _sessionId = '';

  /// The live session id, or an empty string when nobody is signed in.
  static String get sessionId => _sessionId;

  static bool get isSignedIn => _sessionId.isNotEmpty;

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/$_fileName');

  /// Read the stored session, if this device is still holding one.
  ///
  /// Resolved at startup alongside the install id, so the first request cannot
  /// race ahead of it and be refused for carrying no session.
  static Future<String> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        _sessionId = (await file.readAsString()).trim();
      }
    } catch (_) {
      // No readable storage: treat it as signed out. Asking someone to log in
      // again is a far better failure than locking them out of a working app.
      _sessionId = '';
    }
    return _sessionId;
  }

  static Future<void> save(String id) async {
    _sessionId = id.trim();
    try {
      final file = await _file();
      await file.create(recursive: true);
      await file.writeAsString(_sessionId, flush: true);
    } catch (_) {
      // Held in memory for this run; the next launch asks for a code again.
    }
  }

  /// Forget the session — signing out, or being signed out from elsewhere.
  static Future<void> clear() async {
    _sessionId = '';
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {/* best effort */}
  }

  /// Test seam.
  @visibleForTesting
  static void setForTesting(String value) => _sessionId = value;
}
