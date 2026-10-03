import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The native half of [LocalStore]: one small file per key, in the application
/// support directory.
///
/// Application support rather than documents — these are the app's own
/// bookkeeping, not anything a user would want to see in a file browser, and on
/// iOS the documents directory can be exposed to one.
///
/// Errors are left to propagate; [LocalStore] is where they are turned into a
/// null and a shrug.

Future<File> _file(String key) async =>
    File('${(await getApplicationSupportDirectory()).path}/$key');

Future<String?> read(String key) async {
  final file = await _file(key);
  if (!await file.exists()) return null;
  final value = (await file.readAsString()).trim();
  return value.isEmpty ? null : value;
}

Future<void> write(String key, String value) async {
  final file = await _file(key);
  await file.create(recursive: true);
  await file.writeAsString(value, flush: true);
}

Future<void> delete(String key) async {
  final file = await _file(key);
  if (await file.exists()) await file.delete();
}
