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

  /// File a memory into a journal (or unfile it with an empty id).
  ///
  /// Optimistic like the star: the picker closes onto a row that has already
  /// moved, and only rolls back if the server disagrees.
  Future<void> setJournal(String recordingId, String journalId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final index = current.indexWhere((r) => r.id == recordingId);
    if (index < 0) return;

    final previous = current[index].journalId;
    final optimistic = [...current]..[index] = current[index].copyWith(journalId: journalId);
    state = AsyncData(optimistic);

    try {
      final saved = await ref.read(apiClientProvider).setRecordingJournal(recordingId, journalId);
      final settled = [...state.valueOrNull ?? optimistic];
      final at = settled.indexWhere((r) => r.id == recordingId);
      if (at >= 0) {
        settled[at] = saved;
        state = AsyncData(settled);
      }
    } catch (e) {
      final rolledBack = [...state.valueOrNull ?? optimistic];
      final at = rolledBack.indexWhere((r) => r.id == recordingId);
      if (at >= 0) {
        rolledBack[at] = rolledBack[at].copyWith(journalId: previous);
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

/// The user's journals, newest state first-class: create/rename/delete update
/// the list in place rather than refetching, so the sheet closes onto a list
/// that already shows the change.
class JournalsNotifier extends AsyncNotifier<List<Journal>> {
  @override
  Future<List<Journal>> build() async {
    // Preserves the existing auth-change cascade.
    ref.watch(apiClientProvider);
    return ref.read(apiClientProvider).listJournals();
  }

  Future<Journal> create(String name) async {
    final created = await ref.read(apiClientProvider).createJournal(name);
    // Not optimistic: the server owns the ceiling and the duplicate-name check,
    // so a journal drawn before the response could have to be taken away again.
    state = AsyncData(_sorted([...?state.valueOrNull, created]));
    return created;
  }

  Future<void> rename(String id, String name) async {
    final current = state.valueOrNull ?? const [];
    final saved = await ref.read(apiClientProvider).updateJournal(id, name: name);
    state = AsyncData(_sorted([
      for (final j in current)
        if (j.id == id) saved else j,
    ]));
  }

  /// Delete a journal and return how many memories it unfiled.
  ///
  /// Invalidates recordings too: every memory that was filed here now reads as
  /// unfiled, and the lists behind this screen would otherwise keep claiming a
  /// journal that no longer exists.
  Future<int> remove(String id) async {
    final unfiled = await ref.read(apiClientProvider).deleteJournal(id);
    state = AsyncData([
      for (final j in state.valueOrNull ?? const <Journal>[])
        if (j.id != id) j,
    ]);
    ref.invalidate(recordingsProvider);
    return unfiled;
  }

  static List<Journal> _sorted(List<Journal> items) =>
      items..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

final journalsProvider = AsyncNotifierProvider<JournalsNotifier, List<Journal>>(
  JournalsNotifier.new,
  name: 'journals',
);

/// Which journal Recall is scoped to, as chosen by the picker.
///
/// Three-state, matching the API: null means nothing was chosen and the question
/// may name its own journal; `''` means the user explicitly asked across
/// everything; an id scopes to it.
final recallScopeProvider = StateProvider<String?>((ref) => null, name: 'recallScope');

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
