import 'package:flutter/foundation.dart';

import 'local_store.dart';

/// The memory someone is in the middle of typing, kept until it is saved.
///
/// A typed memory used to exist only in the text field: closing the screen, a
/// refreshed tab, a phone call, or the app being put away by the system all
/// took it with them. For something written once, about a moment that will not
/// come again, that is the one loss the app cannot shrug at. So every change is
/// written here, and the screen picks it back up when it opens.
///
/// One draft, not one per memory: there is one place to write, and what was in
/// it is what comes back. It is cleared when the memory is saved, and when the
/// device is signed out — a shared phone must not hand the next person the last
/// person's unfinished sentence.
///
/// Kept in memory as well as in [LocalStore], so that where storage is
/// unavailable (a private window, a locked-down device) the draft still
/// survives leaving the screen and coming back, if not a restart.
class DraftStore {
  DraftStore._();

  static const _key = 'memory_draft';

  static String? _text;
  static bool _dirty = false;
  static Future<void>? _inFlight;

  /// The stored draft, or an empty string when there is none.
  static Future<String> load() async => _text ??= await LocalStore.read(_key) ?? '';

  /// Remember [text] as the draft. Returns at once; the write follows.
  ///
  /// Called on every keystroke, so writes are coalesced rather than queued: a
  /// write in flight is allowed to finish and then the *latest* text is written,
  /// however many changes arrived meanwhile. That keeps two file writes from
  /// racing and landing out of order, without a timer that could be cut off by
  /// the very thing a draft is there to survive.
  static void save(String text) {
    if (text == _text) return;
    _text = text;
    _dirty = true;
    _inFlight ??= _flush().whenComplete(() => _inFlight = null);
  }

  static Future<void> _flush() async {
    while (_dirty) {
      _dirty = false;
      final text = _text ?? '';
      if (text.trim().isEmpty) {
        await LocalStore.delete(_key);
      } else {
        await LocalStore.write(_key, text);
      }
    }
  }

  /// Forget the draft: the memory was saved, or the device was signed out.
  ///
  /// Goes through the same writer as [save] rather than deleting directly, so a
  /// write still in flight cannot land after the delete and bring back a draft
  /// of a memory that has already been saved.
  static Future<void> clear() async {
    _text = '';
    _dirty = true;
    await (_inFlight ??= _flush().whenComplete(() => _inFlight = null));
  }

  /// Test seam. Null means "not loaded yet".
  @visibleForTesting
  static void setForTesting(String? text) {
    _text = text;
    _dirty = false;
  }

  /// The draft as it stands, without a read: empty until [load] has run or
  /// something has been typed. For a field that needs to catch up after the
  /// draft was edited, or saved and cleared, somewhere else.
  static String get current => _text ?? '';
}
