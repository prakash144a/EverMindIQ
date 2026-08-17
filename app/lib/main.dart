import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'src/app.dart';
import 'src/core/device_identity.dart';
import 'src/data/error_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Capture failures so the user can attach them to a report. Both hooks keep
  // their default behaviour — this only records on the way past.
  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    ErrorLog.instance.add(
      source: 'flutter',
      message: details.exceptionAsString(),
      details: '${details.stack}',
    );
    presentError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorLog.instance.add(source: 'uncaught', message: '$error', details: '$stack');
    return false; // still reported to the platform
  };

  // Resolved before the first request so every call can read it synchronously.
  // Its own failures are already handled internally, so this cannot block boot.
  await DeviceIdentity.ensure();

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e, st) {
    ErrorLog.instance.add(source: 'firebase-init', message: '$e', details: '$st');
    rethrow;
  }

  runApp(
    ProviderScope(
      observers: [ErrorLoggingObserver()],
      child: const MemoriesIQApp(),
    ),
  );
}
