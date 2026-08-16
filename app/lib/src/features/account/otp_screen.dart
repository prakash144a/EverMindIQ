import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/providers.dart';

/// Enter the six-digit code sent by email.
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.email, this.preferredName = ''});

  final String email;
  final String preferredName;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  static const _resendCooldown = Duration(seconds: 60);

  final _code = TextEditingController();
  Timer? _ticker;
  int _secondsLeft = _resendCooldown.inSeconds;
  bool _verifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _ticker?.cancel();
    setState(() => _secondsLeft = _resendCooldown.inSeconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) t.cancel();
    });
  }

  Future<void> _resend() async {
    try {
      await ref.read(apiClientProvider).requestOtp(widget.email);
      _startCooldown();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sent another code.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not resend: $e');
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Enter the code from your email.');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final result = await ref.read(apiClientProvider).verifyOtp(
            email: widget.email,
            code: code,
            preferredName: widget.preferredName,
          );

      // A restore moves the account onto this session server-side, so there's
      // nothing to re-authenticate — just re-read everything.
      ref.invalidate(profileProvider);
      ref.invalidate(recordingsProvider);
      ref.invalidate(onThisDayProvider);

      if (!mounted) return;
      // Back past the OTP and signup screens to whatever launched the flow.
      Navigator.of(context).popUntil((route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_successMessage(result.status, result.restoredRecordings))),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _verifying = false;
          _error = _friendly(e);
        });
      }
    }
  }

  String _successMessage(String status, int restored) {
    if (status != 'restored') return 'You\'re all set — your memories are safe.';
    return restored > 0
        ? 'Welcome back — $restored memor${restored == 1 ? 'y' : 'ies'} restored.'
        : 'Welcome back. Your account is linked again.';
  }

  /// The backend's messages are already written for users; surface them rather
  /// than a raw exception when we can.
  String _friendly(Object e) {
    final text = '$e';
    final match = RegExp(r'"detail":"(.*?)"').firstMatch(text);
    return match?.group(1) ?? 'Could not verify that code: $e';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Enter your code')),
      body: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'We emailed a six-digit code to '),
                TextSpan(
                  text: widget.email,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const TextSpan(text: '. It expires in 10 minutes.'),
              ],
            ),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Insets.xl),
          TextField(
            controller: _code,
            enabled: !_verifying,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, letterSpacing: 10, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: '••••••', border: OutlineInputBorder()),
            onSubmitted: (_) => _verify(),
          ),
          if (_error != null) ...[
            const SizedBox(height: Insets.md),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: Insets.xl),
          FilledButton.icon(
            onPressed: _verifying ? null : _verify,
            icon: _verifying
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: Text(_verifying ? 'Checking…' : 'Verify'),
          ),
          const SizedBox(height: Insets.md),
          TextButton(
            onPressed: (_secondsLeft > 0 || _verifying) ? null : _resend,
            child: Text(_secondsLeft > 0 ? 'Resend in ${_secondsLeft}s' : 'Send a new code'),
          ),
        ],
      ),
    );
  }
}
