import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/providers.dart';
import 'otp_screen.dart';

/// Asks for a name and email so the user's memories survive a reinstall.
///
/// Always skippable: the app works fully without an account, and pushing too
/// hard before the user has seen any value is worse than a lost recording.
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key, this.restoreOnly = false});

  /// Entry point for "I already have an account" — no name is asked for,
  /// since the stored one wins on restore.
  final bool restoreOnly;

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  late bool _restoring = widget.restoreOnly;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    if (!_restoring && _name.text.trim().isEmpty) {
      setState(() => _error = 'Please tell us what to call you.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).requestOtp(email);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OtpScreen(email: email, preferredName: _name.text.trim()),
        ),
      );
      setState(() => _sending = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = 'Could not send the code: $e';
        });
      }
    }
  }

  Future<void> _skip() async {
    // Remembered server-side, so the prompt doesn't reappear on every recording.
    try {
      await ref.read(apiClientProvider).patchProfile(signupPromptDismissed: true);
      ref.invalidate(profileProvider);
    } catch (_) {
      // Not worth blocking the user on; they'll just be asked again.
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // Short enough not to truncate next to the "Not now" action.
        title: Text(_restoring ? 'Restore' : 'Save memories'),
        actions: [
          TextButton(onPressed: _sending ? null : _skip, child: const Text('Not now')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: [
          Text(
            _restoring
                ? 'Enter the email you signed up with and we\'ll bring your memories back.'
                : 'Your memories live on this device\'s account. Add your email and they\'ll '
                    'still be here if you change phone or reinstall the app.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Insets.xl),
          if (!_restoring) ...[
            TextField(
              controller: _name,
              enabled: !_sending,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'What should we call you?',
                hintText: 'Prakash Annadurai',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Insets.md),
          ],
          TextField(
            controller: _email,
            enabled: !_sending,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'you@example.com',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Insets.md),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: Insets.xl),
          FilledButton.icon(
            onPressed: _sending ? null : _sendCode,
            icon: _sending
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.mail_outline),
            label: Text(_sending ? 'Sending…' : 'Email me a code'),
          ),
          const SizedBox(height: Insets.md),
          if (!widget.restoreOnly)
            TextButton(
              onPressed: _sending
                  ? null
                  : () => setState(() {
                        _restoring = !_restoring;
                        _error = null;
                      }),
              child: Text(
                _restoring
                    ? 'Create a new account instead'
                    : 'I already have an account — restore my memories',
              ),
            ),
          const SizedBox(height: Insets.sm),
          Text(
            'We only use your email to send the code and to find your memories again. '
            'No password to remember.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
