// Firebase configuration for VoiceIQ (Android).
//
// Generated from the Firebase Android app registered for project
// `voiceiq-505205` (package com.example.voiceiq). Mirrors what
// `flutterfire configure` would produce. Firebase Android API keys are client
// identifiers restricted by API-key/security rules, not secrets.
//
// Only Android is configured today; add other platforms with the FlutterFire
// CLI (or by extending this file) when needed.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'DefaultFirebaseOptions are not configured for web - '
        'reconfigure with the FlutterFire CLI.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for $defaultTargetPlatform - '
          'only Android is set up.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyASsp7--_Lu2pw2oXZuuaLJZGeUGct4leo',
    appId: '1:126206789375:android:7f6767a62e8fe1de62aeca',
    messagingSenderId: '126206789375',
    projectId: 'voiceiq-505205',
    storageBucket: 'voiceiq-505205.firebasestorage.app',
  );
}
