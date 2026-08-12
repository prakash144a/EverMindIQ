import 'package:flutter_riverpod/flutter_riverpod.dart';

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
final recordingsProvider = FutureProvider<List<Recording>>((ref) async {
  return ref.watch(apiClientProvider).listRecordings();
});

/// On-This-Day feed for the home slideshow.
final onThisDayProvider = FutureProvider<List<MemoryItem>>((ref) async {
  return ref.watch(apiClientProvider).onThisDay();
});

/// User settings (controls slideshow, notifications, answer language).
final settingsProvider = FutureProvider<UserSettings>((ref) async {
  return ref.watch(apiClientProvider).getSettings();
});

/// Insight for a given range keyword (day|week|month|year|5y|lifetime).
final insightProvider = FutureProvider.family<Insight, String>((ref, range) async {
  return ref.watch(apiClientProvider).insight(range);
});
