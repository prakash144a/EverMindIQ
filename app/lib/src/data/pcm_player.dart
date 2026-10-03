/// A speaker for the raw PCM that Gemini Live answers in, on whichever platform
/// the app is running.
///
/// Two implementations, chosen at compile time by the export below, because the
/// plugin that does this natively — `flutter_pcm_sound` — declares Android, iOS
/// and macOS and nothing else. In a browser its method channel simply is not
/// there, so a spoken recall would connect, transcribe, think, and then fail on
/// the first chunk of the answer. The web implementation is Web Audio directly.
///
/// Both expose the same class, `PcmPlayer`, with the same contract:
///
/// * [setup] opens the speaker for mono 16-bit PCM at a sample rate, and takes
///   the threshold — in frames of already-queued audio — below which more is
///   wanted.
/// * [onNeedsMore] registers the callback that asks for it. It is handed the
///   number of frames still queued, and **zero means the speaker has run dry**,
///   which is how a caller knows a spoken turn has finished playing rather than
///   merely finished arriving.
/// * [feed] hands over one chunk. Chunks play back to back, in order.
/// * [release] closes the speaker and drops anything unplayed.
///
/// Neither can flush audio it has already accepted, which is what bounds how
/// far ahead a caller should feed: on a barge-in, everything already handed
/// over is audio the listener is going to hear.
///
/// There is no shared interface type to implement — a conditional export gives
/// the analyzer exactly one `PcmPlayer` and the two would have nothing to share
/// but the name. The contract above is the contract; changing one side means
/// changing the other.
library;

export 'pcm_player_io.dart' if (dart.library.js_interop) 'pcm_player_web.dart';
