import 'local_store_io.dart' if (dart.library.js_interop) 'local_store_web.dart' as impl;

/// The handful of small strings the app must remember between launches: which
/// installation this is, which session it holds, and which theme to open in.
///
/// One indirection over two implementations, because the platforms disagree
/// about what "between launches" even means. Natively it is a file in the
/// application support directory. In a browser it is `localStorage`, and the
/// distinction is not cosmetic: `path_provider` has no web implementation, so
/// the file path throws there and the values fall back to memory — which lasts
/// exactly until the tab is refreshed. A web session that cannot outlive a
/// refresh is not a session, and an install id that changes on every reload
/// makes every reload look like a new device asking to take the account over.
///
/// Deliberately not `shared_preferences`, which would do this and more: another
/// plugin in the graph, another thing to pin, for three keys and no migration
/// story we want. The native half already existed and is unchanged.
///
/// Every method swallows its own failures and answers null rather than throwing.
/// Storage is unavailable in more ordinary situations than it looks — a private
/// window, a locked-down device, a full disk — and none of them are a reason for
/// the app not to open.
class LocalStore {
  LocalStore._();

  /// The stored value for [key], or null if there is none and if anything at
  /// all went wrong reading it.
  static Future<String?> read(String key) async {
    try {
      return await impl.read(key);
    } catch (_) {
      return null;
    }
  }

  /// Best effort. A value that fails to persist costs the next launch; throwing
  /// here would cost this one.
  static Future<void> write(String key, String value) async {
    try {
      await impl.write(key, value);
    } catch (_) {/* this run keeps it in memory; the next asks again */}
  }

  static Future<void> delete(String key) async {
    try {
      await impl.delete(key);
    } catch (_) {/* best effort */}
  }
}
