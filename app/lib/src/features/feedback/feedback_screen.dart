import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/tokens.dart';
import '../../data/error_log.dart';
import '../../data/providers.dart';
import '../../widgets/formatting.dart';

/// Report a problem or send a suggestion.
///
/// Whatever the app has recently failed at is captured by [ErrorLog] and offered
/// as an attachment, so the user doesn't have to describe a stack trace.
class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({super.key, this.prefillMessage});

  /// Seeded when the user taps "Report" on an error card.
  final String? prefillMessage;

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  late final TextEditingController _message =
      TextEditingController(text: widget.prefillMessage ?? '');
  String _kind = 'problem';
  bool _attachDiagnostics = true;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  String get _platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  String _diagnostics() {
    final entries = ErrorLog.instance.entries;
    if (entries.isEmpty) return '';
    // Newest first, capped — enough to debug without shipping the whole session.
    return entries.take(5).map((e) => e.toReport()).join('\n\n---\n\n');
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Please describe what happened.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).submitFeedback(
            kind: _kind,
            message: text,
            diagnostics: _attachDiagnostics ? _diagnostics() : '',
            appVersion: AppConfig.appVersion,
            platform: _platform,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks — your report was sent.')),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = 'Could not send: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final errors = ErrorLog.instance.entries;

    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: [
          Text('What kind of feedback is this?',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            children: [
              for (final option in const [
                ('problem', 'Something broke'),
                ('idea', 'An idea'),
                ('other', 'Something else'),
              ])
                ChoiceChip(
                  label: Text(option.$2),
                  selected: _kind == option.$1,
                  onSelected: _sending ? null : (_) => setState(() => _kind = option.$1),
                ),
            ],
          ),
          const SizedBox(height: Insets.xl),
          Text('What happened?', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Insets.sm),
          TextField(
            controller: _message,
            enabled: !_sending,
            maxLines: 6,
            maxLength: 5000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Tell us what you were doing and what went wrong.',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          if (errors.isNotEmpty) ...[
            const SizedBox(height: Insets.md),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile(
                    value: _attachDiagnostics,
                    onChanged: _sending ? null : (v) => setState(() => _attachDiagnostics = v),
                    title: const Text('Attach technical details'),
                    subtitle: Text(
                      '${errors.length} recent error${errors.length == 1 ? '' : 's'} '
                      'the app recorded. Helps us find the cause.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (_attachDiagnostics)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          Insets.lg, 0, Insets.lg, Insets.md),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('Preview', style: TextStyle(fontSize: 13)),
                          children: [
                            for (final e in errors.take(5))
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  e.message,
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${e.source} · ${relativeTime(e.at)}',
                                  style: TextStyle(
                                      fontSize: 11, color: scheme.onSurfaceVariant),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: Insets.md),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: Insets.xl),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_outlined),
            label: Text(_sending ? 'Sending…' : 'Send report'),
          ),
          const SizedBox(height: Insets.md),
          Text(
            'Sent with your app version and device type so we can reproduce it. '
            'Your recordings and transcripts are never included.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
