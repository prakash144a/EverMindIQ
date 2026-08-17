// Firebase configuration for MemoriesIQ (Android + web).
//
// Values pulled from the apps registered on project `voiceiq-505205`:
//   Android  com.memoriesiq.app
//   Web      used by the admin console
//
// Written by hand rather than by `flutterfire configure`, which crashes on this
// project: the web app has no `measurementId` (no Google Analytics), and the
// CLI version resolvable here casts that field to a non-nullable String. The
// values are identical to what it would have produced.
//
// Firebase API keys are client identifiers, restricted by API-key restrictions
// and security rules — not secrets. They are meant to ship in the client.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for $defaultTargetPlatform - '
          'only Android and web are set up.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyASsp7--_Lu2pw2oXZuuaLJZGeUGct4leo',
    appId: '1:126206789375:android:065a8d14780e295d62aeca',
    messagingSenderId: '126206789375',
    projectId: 'voiceiq-505205',
    storageBucket: 'voiceiq-505205.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCMe7PBM8qxQc1jGZFBtte8rLOYdVZ5xnE',
    appId: '1:126206789375:web:d54fd08d95fd694362aeca',
    messagingSenderId: '126206789375',
    projectId: 'voiceiq-505205',
    authDomain: 'voiceiq-505205.firebaseapp.com',
    storageBucket: 'voiceiq-505205.firebasestorage.app',
  );
}
