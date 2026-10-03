import 'package:web/web.dart' as web;

/// The browser half of [LocalStore]: `localStorage`, which survives a refresh,
/// a closed tab, and a restarted browser.
///
/// Not `sessionStorage`, which is scoped to one tab and would hand a second tab
/// of the same app a login screen. Not cookies, which would ride along on every
/// request to the API for no reason.
///
/// Keys are prefixed because `localStorage` is shared by everything on the
/// origin — including, if the app and the marketing site ever share a host, a
/// script that has never heard of us.
const _prefix = 'memoriesiq.';

Future<String?> read(String key) async {
  final value = web.window.localStorage.getItem('$_prefix$key')?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

Future<void> write(String key, String value) async =>
    web.window.localStorage.setItem('$_prefix$key', value);

Future<void> delete(String key) async => web.window.localStorage.removeItem('$_prefix$key');
