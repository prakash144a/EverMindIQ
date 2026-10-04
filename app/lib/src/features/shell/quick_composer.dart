import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/draft_store.dart';
import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/attach_placeholder.dart';
import '../record/record_screen.dart';
import 'app_shell.dart';

/// Writing a memory without leaving the page, for the wide layout.
///
/// On a phone, capturing is a screen of its own, and that is right for a phone.
/// On a wide screen the same thing is a full-window takeover for what is often
/// one sentence — so the common case is done here, in place: type, save, and
/// the memory appears in the feed underneath.
///
/// It is the quick path, not a second implementation of the full one. A memory
/// that needs a different date, a journal, or a voice opens [RecordScreen],
/// which is still where those live. The two share one draft, so what was typed
/// here is already there when it opens, and what was written there is here
/// when it closes.
class QuickComposer extends ConsumerStatefulWidget {
  const QuickComposer({super.key});

  @override
  ConsumerState<QuickComposer> createState() => _QuickComposerState();
}

class _QuickComposerState extends ConsumerState<QuickComposer> {
  final _text = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onChanged);
    _restore();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _onChanged() {
    DraftStore.save(_text.text);
    setState(() {});
  }

  Future<void> _restore() async {
    final draft = await DraftStore.load();
    if (!mounted || draft.isEmpty || _text.text.isNotEmpty) return;
    _show(draft);
  }

  void _show(String value) {
    _text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).createTextMemory(text: text);
      // Only now: a save that failed leaves the draft exactly where it was.
      unawaited(DraftStore.clear());
      _show('');
      ref.invalidate(recordingsProvider);
      ref.invalidate(onThisDayProvider);
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Memory saved.')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = saveErrorMessage(e);
      });
    }
  }

  /// The full capture screen, for what this one does not do.
  Future<void> _openFull({bool voice = false}) async {
    await openRecordScreen(context, ref, voice: voice);
    // Whatever happened in there — more typing, or a save that cleared it —
    // this field should now say the same thing the draft does.
    if (mounted) _show(DraftStore.current);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxChars = ref.watch(profileProvider).maybeWhen(
          data: (p) => p.textMaxChars,
          orElse: () => const UserProfile().textMaxChars,
        );
    final hasText = _text.text.trim().isNotEmpty;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.sm, Insets.sm),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _text,
              enabled: !_saving,
              minLines: 1,
              maxLines: 8,
              maxLength: maxChars,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 16, height: 1.45),
              decoration: const InputDecoration(
                hintText: 'What happened? Write it in any language.',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                // Said in the footer instead, beside the draft note.
                counterText: '',
                contentPadding: EdgeInsets.symmetric(vertical: Insets.md),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: Text(_error!, style: TextStyle(color: scheme.error, fontSize: 13)),
              ),
            Row(
              children: [
                const AttachPlaceholderButton(),
                IconButton(
                  tooltip: 'Speak a memory',
                  onPressed: _saving ? null : () => _openFull(voice: true),
                  icon: const Icon(Icons.mic_none_rounded),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : _openFull,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('Date & journal'),
                ),
                Expanded(
                  child: hasText
                      ? Text(
                          '${_text.text.length} / $maxChars · Draft kept on this device',
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: Insets.md),
                FilledButton(
                  onPressed: hasText && !_saving ? _save : null,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
