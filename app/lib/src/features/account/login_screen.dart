import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/tokens.dart';
import '../../data/api_client.dart';
import '../../data/auth.dart';
import '../../data/models.dart';
import '../../data/providers.dart';

/// The way in. Email, then the code that proves it is yours — and, the first
/// time only, what to call you.
///
/// The name is asked *after* the code because only then do we know whether to
/// ask at all: an address with a named account is simply let in, on any device,
/// and the name is changed from the profile rather than at the door.
///
/// There is no password and no "continue without an account": the memories
/// belong to an address, not to a phone, which is what lets someone open them
/// on a new device and hand this one to somebody else.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.notice});

  /// Why the last session ended, when it did not end by choice. Shown above the
  /// form — being signed out with no explanation reads as data loss.
  final SessionEndedException? notice;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

enum _Step { email, code, name }

class _LoginScreenState extends ConsumerState<LoginScreen> {
  static const _resendCooldown = Duration(seconds: 60);

  final _email = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();

  _Step _step = _Step.email;
  bool _busy = false;
  String? _error;

  bool _isNewAccount = false;

  /// The verified code, held while the name is asked for. Its ticket is good
  /// for a few minutes, which is plenty to type a name.
  VerifyResult? _verified;

  Timer? _ticker;
  int _secondsLeft = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    _email.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  ApiClient get _api => ref.read(apiClientProvider);

  void _startCooldown() {
    _ticker?.cancel();
    setState(() => _secondsLeft = _resendCooldown.inSeconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) t.cancel();
    });
  }

  Future<void> _send({bool resending = false}) async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.requestOtp(email);
      // Dismiss the old explanation: they are on their way back in, and it has
      // said what it had to say.
      ref.read(authControllerProvider.notifier).acknowledgeEnded();
      if (!mounted) return;
      setState(() {
        _step = _Step.code;
        _busy = false;
      });
      _startCooldown();
      if (resending) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Sent another code.')));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e, 'Could not send a code');
        });
      }
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Enter the code from your email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verified = await _api.verifyOtp(email: _email.text.trim(), code: code);
      _isNewAccount = verified.isNewAccount;
      _verified = verified;

      // An account nobody has named yet: ask, then come back through [_enter].
      if (verified.needsName) {
        if (mounted) {
          setState(() {
            _step = _Step.name;
            _busy = false;
          });
        }
        return;
      }
      await _enter(verified);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e, 'Could not verify that code');
        });
      }
    }
  }

  /// From the name step: carry on in, with whatever was typed. An empty name is
  /// allowed — the question comes back next sign-in, and the profile has it too.
  Future<void> _submitName() async {
    final verified = _verified;
    if (verified == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _enter(verified);
  }

  /// Spend a verified code for a session, asking first if that signs another
  /// device out.
  Future<void> _enter(VerifyResult verified) async {
    try {
      // Nothing in the way: straight in. Something in the way: ask, because
      // signing someone else's phone out is their decision, not ours.
      if (verified.needsTakeover) {
        final goAhead = await _askToTakeOver(verified.activeSession!);
        if (!goAhead) {
          if (mounted) setState(() => _busy = false);
          return;
        }
      }
      await _claim(verified.ticket, takeover: verified.needsTakeover);
    } on SessionInUseException catch (e) {
      // The other device signed in between the question and the answer.
      if (await _askToTakeOver(e.activeSession)) {
        await _claim(_lastTicket ?? '', takeover: true);
      } else if (mounted) {
        setState(() => _busy = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e, 'Could not sign you in');
        });
      }
    }
  }

  String? _lastTicket;

  Future<void> _claim(String ticket, {required bool takeover}) async {
    _lastTicket = ticket;
    final session = await _api.claimSession(
      ticket,
      takeover: takeover,
      preferredName: _name.text.trim(),
    );
    await ref.read(authControllerProvider.notifier).signIn(session);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isNewAccount
              ? 'Welcome to ${AppConfig.appName} — your memories are safe here.'
              : 'Welcome back${session.profile.preferredName.isEmpty ? '' : ', '
                  '${session.profile.preferredName}'}.',
        ),
      ),
    );
  }

  /// The confirmation the second device asks for before signing the first out.
  Future<bool> _askToTakeOver(DeviceSessionInfo held) async {
    final when = held.signedInAt;
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Already signed in somewhere'),
        content: Text(
          'Your account is open on ${held.device}'
          '${when == null ? '' : ', signed in ${_when(when)}'}.\n\n'
          'Continuing here will sign that device out. Your memories stay safe '
          'either way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue here'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  static String _when(DateTime at) {
    final ago = DateTime.now().difference(at);
    if (ago.inMinutes < 1) return 'just now';
    if (ago.inMinutes < 60) return '${ago.inMinutes} minutes ago';
    if (ago.inHours < 24) return '${ago.inHours} hour${ago.inHours == 1 ? '' : 's'} ago';
    if (ago.inDays == 1) return 'yesterday';
    return '${ago.inDays} days ago';
  }

  /// The backend's messages are written for users; surface them when we can.
  String _friendly(Object e, String fallback) {
    final text = '$e';
    final match = RegExp(r'"detail":"(.*?)"').firstMatch(text);
    return match?.group(1) ?? '$fallback: $e';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Insets.xl),
          children: [
            const SizedBox(height: Insets.xxl),
            if (widget.notice != null) ...[
              _SignedOutNotice(notice: widget.notice!),
              const SizedBox(height: Insets.xl),
            ],
            Text(
              AppConfig.appName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              switch (_step) {
                _Step.email => 'Sign in with your email. No password to remember.',
                _Step.code => 'We emailed a six-digit code to ${_email.text.trim()}.',
                _Step.name => 'You are in. One last thing before your memories.',
              },
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.xxl),
            ...switch (_step) {
              _Step.email => _emailStep(scheme),
              _Step.code => _codeStep(scheme),
              _Step.name => _nameStep(scheme),
            },
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: Insets.xl),
            Text(
              'We only use your email to send the code and to find your memories '
              'again — one account, on your phone and in your browser.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _emailStep(ColorScheme scheme) => [
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _send(),
        ),
        const SizedBox(height: Insets.xl),
        FilledButton.icon(
          onPressed: _busy ? null : () => _send(),
          icon: _busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.mail_outline),
          label: Text(_busy ? 'Sending…' : 'Email me a code'),
        ),
      ];

  List<Widget> _nameStep(ColorScheme scheme) => [
        TextField(
          controller: _name,
          enabled: !_busy,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          inputFormatters: [LengthLimitingTextInputFormatter(80)],
          decoration: const InputDecoration(
            labelText: 'What should we call you?',
            helperText: 'You can change this any time from your profile.',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submitName(),
        ),
        const SizedBox(height: Insets.xl),
        FilledButton.icon(
          onPressed: _busy ? null : _submitName,
          icon: _busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.arrow_forward),
          label: Text(_busy ? 'Signing in…' : 'Continue'),
        ),
        const SizedBox(height: Insets.sm),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  _name.clear();
                  _submitName();
                },
          child: const Text('Skip for now'),
        ),
      ];

  List<Widget> _codeStep(ColorScheme scheme) => [
        TextField(
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 28, letterSpacing: 10, fontWeight: FontWeight.w600),
          decoration: const InputDecoration(hintText: '••••••', border: OutlineInputBorder()),
          onSubmitted: (_) => _verify(),
        ),
        const SizedBox(height: Insets.xl),
        FilledButton.icon(
          onPressed: _busy ? null : _verify,
          icon: _busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check),
          label: Text(_busy ? 'Checking…' : 'Sign in'),
        ),
        const SizedBox(height: Insets.sm),
        TextButton(
          onPressed: (_secondsLeft > 0 || _busy) ? null : () => _send(resending: true),
          child: Text(_secondsLeft > 0 ? 'Resend in ${_secondsLeft}s' : 'Send a new code'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _step = _Step.email;
                    _error = null;
                    _code.clear();
                    _name.clear();
                    _verified = null;
                  }),
          child: const Text('Use a different email'),
        ),
      ];
}

/// Why the last session ended. Deliberately prominent: someone opening the app
/// to find themselves logged out deserves to know it was not a fault.
class _SignedOutNotice extends StatelessWidget {
  const _SignedOutNotice({required this.notice});

  final SessionEndedException notice;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final replaced = notice.replacedBy;
    final when = replaced?.signedInAt;
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.logout_rounded, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: Insets.sm),
              Text(
                'You were signed out',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            notice.wasReplaced && replaced != null
                ? 'Your account was opened on ${replaced.device}'
                    '${when == null ? '' : ' on ${_stamp(when)}'}. '
                    'One phone and one browser can be signed in at a time — sign '
                    'in again here to bring it back.'
                : 'Sign in to open your memories again.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            'Nothing was lost. Your memories live with your account.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    return '${at.day} ${months[at.month - 1]} at $hour:$minute ${at.hour < 12 ? 'AM' : 'PM'}';
  }
}
