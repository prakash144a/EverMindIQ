import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/auth.dart';
import '../../data/models.dart';
import '../../data/providers.dart';

/// Closing the account for good.
///
/// A whole screen rather than a dialog, and deliberately so. This is the only
/// irreversible action in the app that takes *everything* — years of recordings
/// that exist nowhere else — and a confirm sheet that can be dismissed by a
/// mis-tap outside it is the wrong shape for that. The screen states what goes,
/// counts it, and then asks the user to type the word, so the last action before
/// the data is destroyed is one nobody performs by accident.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

/// What has to be typed. Uppercase and unlocalised on purpose: it is a
/// deliberate speed bump, not a phrase to be read fluently.
const _confirmWord = 'DELETE';

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _confirmCtl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _confirmCtl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _confirmCtl.dispose();
    super.dispose();
  }

  bool get _typedIt => _confirmCtl.text.trim().toUpperCase() == _confirmWord;

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The server first, while the token that authorises it is still valid.
      await ref.read(apiClientProvider).deleteAccount();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not delete your account: $e';
      });
      return;
    }

    // Past this point the data is already gone, so nothing below may fail the
    // flow — it can only leave a stale sign-in, which the next step fixes.
    await _releaseIdentity();
    if (!mounted) return;

    // Back to a signed-out app, which the auth gate answers by creating a fresh
    // anonymous account. Everything downstream re-fetches against that new uid
    // and finds, correctly, nothing.
    ref.invalidate(ensureSignedInProvider);
    ref.invalidate(recordingsProvider);
    ref.invalidate(journalsProvider);
    ref.invalidate(profileProvider);
    ref.invalidate(settingsProvider);
    ref.invalidate(onThisDayProvider);
    ref.invalidate(insightProvider);

    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((route) => route.isFirst);
    messenger.showSnackBar(
      const SnackBar(content: Text('Your account and everything in it has been deleted.')),
    );
  }

  /// Drop the Firebase identity the deleted data was attached to.
  ///
  /// Deleting the user is what we want — it leaves nothing behind — but it can
  /// be refused for an identity that has not signed in recently. Signing out is
  /// the fallback: the uid is orphaned either way, since the account it pointed
  /// at no longer exists on our side.
  ///
  /// Nothing in here may throw. It runs *after* the data is gone, so a failure
  /// escaping would strand the user on this screen with no confirmation and no
  /// account — the worst possible moment to surface an error they cannot act on.
  /// That includes resolving the auth instance itself, which is why the whole
  /// body sits inside the guard rather than just the calls.
  Future<void> _releaseIdentity() async {
    try {
      final auth = ref.read(firebaseAuthProvider);
      try {
        await auth.currentUser?.delete();
      } catch (_) {
        await auth.signOut();
      }
    } catch (_) {
      // Nothing worked. The next launch signs in as the same uid and finds an
      // empty account, which is the same outcome, one step later.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider).valueOrNull ?? const UserProfile();
    final memories = ref.watch(recordingsProvider).valueOrNull;
    final journals = ref.watch(journalsProvider).valueOrNull;

    return PopScope(
      // Leaving mid-delete would skip the sign-out and the refetch below, so the
      // app would sit there signed in as a uid whose account no longer exists.
      // The request is already in flight and cannot be called off, so the only
      // honest thing is to hold the screen until it lands. `AbsorbPointer` does
      // the same for taps; this covers the back gesture, which it does not.
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Delete account')),
        body: AbsorbPointer(
          absorbing: _busy,
          child: ListView(
            padding: const EdgeInsets.all(Insets.lg),
            children: [
              Icon(Icons.warning_amber_rounded, size: 44, color: scheme.error),
              const SizedBox(height: Insets.md),
              Text(
                'This deletes everything, permanently',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: Insets.sm),
              Text(
                profile.email.isEmpty
                    ? 'Everything recorded on this install goes with it.'
                    : 'Everything kept under ${profile.email} goes with it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: Insets.xl),

              // Counted, not just described. "Your memories" is abstract; "47
              // memories" is the number someone actually weighs before deciding.
              _WhatGoes(
                lines: [
                  _countLine(memories?.length, 'memory', 'memories'),
                  if (memories != null && memories.any((r) => r.hasAudio))
                    _countLine(
                      memories.where((r) => r.hasAudio).length,
                      'audio recording',
                      'audio recordings',
                    ),
                  _countLine(journals?.length, 'journal', 'journals'),
                  'Every transcript, summary, person, place and tag',
                  'Your insights, settings and problem reports',
                  if (profile.email.isNotEmpty) 'The link between this account and your email',
                ],
              ),

              const SizedBox(height: Insets.lg),
              Container(
                padding: const EdgeInsets.all(Insets.md),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.block, size: 18, color: scheme.onErrorContainer),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: Text(
                        'There is no recovery. We do not keep a copy, an archive or a '
                        'backup you can ask for — once this is done, nobody, including us, '
                        'can bring any of it back.',
                        style: TextStyle(
                          color: scheme.onErrorContainer,
                          fontSize: 13,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: Insets.xl),
              Text(
                'If you want to keep a copy, close this and use Export & backup first.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
              ),

              const SizedBox(height: Insets.xl),
              const Text(
                'Type $_confirmWord to confirm',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: Insets.sm),
              TextField(
                controller: _confirmCtl,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                // Blocks the one shortcut that would defeat the point of asking.
                inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
                decoration: InputDecoration(
                  hintText: _confirmWord,
                  border: const OutlineInputBorder(),
                  suffixIcon: _typedIt ? Icon(Icons.check, color: scheme.error) : null,
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: Insets.md),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],

              const SizedBox(height: Insets.lg),
              FilledButton.icon(
                // Disabled rather than hidden, so the gate is visible: it explains
                // why nothing happened when the word is not typed yet.
                onPressed: _typedIt && !_busy ? _delete : null,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Icon(Icons.delete_forever),
                label: Text(_busy ? 'Deleting…' : 'Delete my account'),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  padding: const EdgeInsets.symmetric(vertical: Insets.md),
                ),
              ),
              const SizedBox(height: Insets.sm),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
                child: const Text('Keep my account'),
              ),
              const SizedBox(height: Insets.xxl),
            ],
          ),
        ),
      ),
    );
  }

  /// "47 memories", or the plain noun while the count is still loading — never a
  /// zero we are not sure about.
  static String _countLine(int? count, String one, String many) {
    if (count == null) return 'Your $many';
    return '$count ${count == 1 ? one : many}';
  }
}

class _WhatGoes extends StatelessWidget {
  const _WhatGoes({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.delete_outline, size: 16, color: scheme.error),
                  const SizedBox(width: Insets.md),
                  Expanded(child: Text(line, style: const TextStyle(fontSize: 14))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
