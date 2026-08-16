import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/formatting.dart';
import 'api_client.dart';
import 'auth.dart';
import 'models.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  // Rebuild when auth state changes so dependent fetches re-run after sign-in.
  ref.watch(authStateProvider);
  final auth = ref.read(firebaseAuthProvider);
  return ApiClient(
    tokenProvider: () async {
      final user = auth.currentUser;
      if (user == null) return null;
      return user.getIdToken();
    },
  );
});

/// All recordings (newest first). Invalidate after a new recording is created.
///
/// Ingestion runs asynchronously on the backend, so a freshly created recording
/// arrives with no title and `status: uploaded`. While any recording is still
/// being processed this notifier re-fetches quietly every few seconds so the
/// row swaps "AI is transcribing…" for its real title on its own.
class RecordingsNotifier extends AsyncNotifier<List<Recording>> {
  static const _pollInterval = Duration(seconds: 5);
  static const _maxPolls = 24; // ~2 minutes, then give up until a manual refresh

  Timer? _poll;
  int _pollsLeft = _maxPolls;

  @override
  Future<List<Recording>> build() async {
    // Preserves the existing auth-change cascade.
    ref.watch(apiClientProvider);
    ref.onDispose(() => _poll?.cancel());
    _pollsLeft = _maxPolls;
    final recs = await ref.read(apiClientProvider).listRecordings();
    _schedule(recs);
    return recs;
  }

  void _schedule(List<Recording> recs) {
    _poll?.cancel();
    if (_pollsLeft <= 0) return;
    if (!recs.any((r) => isProcessing(r.status))) return;
    _poll = Timer(_pollInterval, _refreshQuietly);
  }

  /// Re-fetch without flipping to [AsyncLoading], so the list doesn't flash a
  /// skeleton every few seconds while a transcript is in flight.
  Future<void> _refreshQuietly() async {
    _pollsLeft--;
    try {
      final recs = await ref.read(apiClientProvider).listRecordings();
      state = AsyncData(recs);
      _schedule(recs);
    } catch (_) {
      // Transient failure: keep the last good list and try again.
      _schedule(state.valueOrNull ?? const []);
    }
  }

  /// Star or unstar a recording. The star is a direct-manipulation control, so
  /// the list flips immediately and only rolls back if the request fails.
  Future<void> toggleMilestone(String recordingId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final index = current.indexWhere((r) => r.id == recordingId);
    if (index < 0) return;

    final wanted = !current[index].isMilestone;
    final optimistic = [...current]..[index] = current[index].copyWith(isMilestone: wanted);
    state = AsyncData(optimistic);

    try {
      final saved = await ref.read(apiClientProvider).setMilestone(recordingId, wanted);
      final settled = [...state.valueOrNull ?? optimistic];
      final at = settled.indexWhere((r) => r.id == recordingId);
      if (at >= 0) {
        settled[at] = saved;
        state = AsyncData(settled);
      }
    } catch (e) {
      // Put the old value back rather than leaving the star lying about the server.
      final rolledBack = [...state.valueOrNull ?? optimistic];
      final at = rolledBack.indexWhere((r) => r.id == recordingId);
      if (at >= 0) {
        rolledBack[at] = rolledBack[at].copyWith(isMilestone: !wanted);
        state = AsyncData(rolledBack);
      }
      rethrow;
    }
  }
}

// Providers are named so a failure reads as "recordings" rather than an opaque
// runtime type in a problem report (see ErrorLoggingObserver).
final recordingsProvider = AsyncNotifierProvider<RecordingsNotifier, List<Recording>>(
  RecordingsNotifier.new,
  name: 'recordings',
);

/// The signed-in user's profile. Empty (`hasProfile: false`) until they verify
/// an email — which is also what makes the app offer signup again after a
/// reinstall, since a fresh install is a new uid and therefore a fresh profile.
final profileProvider = FutureProvider<UserProfile>((ref) async {
  return ref.watch(apiClientProvider).getProfile();
}, name: 'profile');

/// On-This-Day feed for the home slideshow.
final onThisDayProvider = FutureProvider<List<MemoryItem>>((ref) async {
  return ref.watch(apiClientProvider).onThisDay();
}, name: 'onThisDay');

/// User settings (controls slideshow, notifications, answer language).
final settingsProvider = FutureProvider<UserSettings>((ref) async {
  return ref.watch(apiClientProvider).getSettings();
}, name: 'settings');

/// Insight for a given range keyword (day|week|month|year|5y|lifetime).
final insightProvider = FutureProvider.family<Insight, String>((ref, range) async {
  return ref.watch(apiClientProvider).insight(range);
}, name: 'insight');
