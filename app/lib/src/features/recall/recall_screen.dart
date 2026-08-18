import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/tokens.dart';
import '../../data/ai_conversation.dart';
import '../../data/auth.dart';
import '../../data/providers.dart';
import '../../widgets/immersive_chrome.dart';
import '../../widgets/journal_picker.dart';
import '../../widgets/ai_orb.dart';
import '../../widgets/audio_play_button.dart';
import '../memory/memory_detail_screen.dart';
import 'voice_mode_screen.dart';

/// Recall — talk to your memories. A back-and-forth thread you can type into,
/// plus a mic button that opens hands-free **voice mode** (an immersive,
/// streaming-style listening splash). Retrieval rides the `/live` channel.
class RecallScreen extends ConsumerStatefulWidget {
  const RecallScreen({super.key});

  @override
  ConsumerState<RecallScreen> createState() => _RecallScreenState();
}

class _RecallScreenState extends ConsumerState<RecallScreen> {
  late final AiConversation _ai;
  final _controller = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final auth = ref.read(firebaseAuthProvider);
    _ai = AiConversation(() async => await auth.currentUser?.getIdToken() ?? AppConfig.devUid);
    _ai.addListener(_onUpdate);
    _ai.connect();
  }

  @override
  void dispose() {
    _ai.removeListener(_onUpdate);
    _ai.dispose();
    _controller.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.fast, curve: Curves.easeOut);
      }
    });
  }

  void _send() {
    final t = _controller.text.trim();
    if (t.isEmpty) return;
    _ai.send(t, journalId: ref.read(recallScopeProvider));
    _controller.clear();
  }

  Future<void> _pickScope() async {
    final choice = await pickJournal(
      context,
      selectedId: ref.read(recallScopeProvider),
      title: 'Ask about',
      unfiledLabel: 'Memories with no journal',
    );
    if (choice != null) ref.read(recallScopeProvider.notifier).state = choice.journalId;
  }

  /// Re-ask the last question across everything.
  ///
  /// Sends an explicit empty scope rather than clearing it: the question named a
  /// journal, so leaving the scope unset would let detection narrow it straight
  /// back and the action would look broken.
  void _askEverything() {
    final lastQuestion = _ai.messages.lastWhere(
      (m) => m.fromUser,
      orElse: () => AiMessage('', true),
    );
    if (lastQuestion.text.isEmpty) return;
    ref.read(recallScopeProvider.notifier).state = '';
    _ai.send(lastQuestion.text, journalId: '');
  }

  void _openVoiceMode() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VoiceModeScreen(), fullscreenDialog: true),
    );
  }

  /// What the scope chip says.
  ///
  /// "All memories" is the honest label for the unset state too: nothing is
  /// filtered until a question happens to name a journal, and the answer says so
  /// when that happens.
  String get _scopeLabel {
    final scope = ref.watch(recallScopeProvider);
    if (scope == null || scope.isEmpty) return 'All memories';
    return journalNameFor(ref, scope) ?? 'One journal';
  }

  @override
  Widget build(BuildContext context) {
    final messages = _ai.messages;
    return ImmersiveChrome(
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.7),
              radius: 1.2,
              colors: [AppColors.immersiveTop, AppColors.immersiveBottom],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const Text('Recall',
                        style: TextStyle(
                            color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (!_ai.connected)
                      TextButton(onPressed: _ai.connect, child: const Text('Reconnect')),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: Insets.sm, bottom: Insets.md),
                  child: Column(
                    children: [
                      AiOrb(size: 76, active: _ai.thinking || messages.isEmpty),
                      const SizedBox(height: Insets.sm),
                      Text(
                        _ai.thinking
                            ? 'Recalling…'
                            : (messages.isEmpty ? 'Ask about your past' : 'Tap the mic to talk'),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: messages.isEmpty
                      ? const _RecallHint()
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.sm),
                          itemCount: messages.length + (_ai.thinking ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i == messages.length) return const _ThinkingRow();
                            return _Bubble(messages[i], onAskEverything: _askEverything);
                          },
                        ),
                ),
                _ScopeChip(
                  label: _scopeLabel,
                  onTap: _pickScope,
                ),
                _InputBar(
                  controller: _controller,
                  focusNode: _inputFocus,
                  onMicTap: _openVoiceMode,
                  onSend: _send,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.msg, {required this.onAskEverything});
  final AiMessage msg;

  /// Offered under a scoped answer so a narrowing the user did not ask for is
  /// always one tap from being undone.
  final VoidCallback onAskEverything;

  @override
  Widget build(BuildContext context) {
    final isUser = msg.fromUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: Insets.xs),
        padding: const EdgeInsets.all(Insets.md),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: isUser ? AppColors.sage : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(Radii.md),
            topRight: const Radius.circular(Radii.md),
            bottomLeft: Radius.circular(isUser ? Radii.md : 4.0),
            bottomRight: Radius.circular(isUser ? 4.0 : Radii.md),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(msg.text, style: const TextStyle(color: Colors.white, height: 1.35, fontSize: 14)),
            if (msg.isScoped) _ScopeFooter(msg.journalName, onAskEverything: onAskEverything),
            if (!isUser)
              for (final c in msg.citations) ...[
                const SizedBox(height: Insets.sm),
                _CitationCard(c),
              ],
          ],
        ),
      ),
    );
  }
}

/// Names the journal an answer came from, and offers to widen.
class _ScopeFooter extends StatelessWidget {
  const _ScopeFooter(this.journalName, {required this.onAskEverything});
  final String journalName;
  final VoidCallback onAskEverything;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.sm,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.book_outlined, size: 13, color: Colors.white54),
              const SizedBox(width: 5),
              Text('From your $journalName journal',
                  style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
            ],
          ),
          InkWell(
            onTap: onAskEverything,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Text('Ask all memories',
                  style: TextStyle(
                      color: AppColors.sageLight, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Recall scope control: which journal the next question goes to.
class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.xs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.pill),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.pill),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.book_outlined, size: 14, color: Colors.white70),
                  const SizedBox(width: 6),
                  Text('Asking: $label',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white70),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow();
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: Insets.xs),
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
        ),
      ),
    );
  }
}

class _RecallHint extends StatelessWidget {
  const _RecallHint();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: Insets.xxl),
        child: Text(
          'Tap the mic to talk out loud, or type below.\n“What did I say about the garden last spring?”',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
        ),
      ),
    );
  }
}

class _CitationCard extends StatelessWidget {
  const _CitationCard(this.citation);
  final Map<String, dynamic> citation;

  @override
  Widget build(BuildContext context) {
    final id = citation['recording_id'] as String?;
    final date = '${citation['event_date'] ?? ''}';
    final snippet = '${citation['snippet'] ?? ''}';
    // Absent on citations written before typed memories existed, and on those
    // the memory was always spoken.
    final hasAudio = (citation['source'] ?? 'voice') != 'text';
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        // The citation says "this memory answered you" — opening it is the
        // obvious next question, and the snippet is only two lines.
        onTap: id == null ? null : () => openMemoryDetail(context, id),
        child: Container(
          padding: const EdgeInsets.all(Insets.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              if (id != null && hasAudio)
                AudioPlayButton(
                  key: ValueKey(id),
                  recordingId: id,
                  onColor: Colors.white,
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                )
              else if (id != null)
                TextMemoryGlyph(
                  onColor: Colors.white,
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                ),
              if (id != null) const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(date,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
                    if (snippet.isNotEmpty)
                      Text(snippet,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60, fontSize: 11)),
                  ],
                ),
              ),
              if (id != null)
                Icon(Icons.chevron_right, size: 18, color: Colors.white.withValues(alpha: 0.45)),
            ],
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onMicTap,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onMicTap;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, Insets.md),
      child: Row(
        children: [
          Tooltip(
            message: 'Voice mode',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onMicTap,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppColors.heroWash,
                  ),
                  child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 22),
                ),
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: 'Ask anything about your memories…',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          IconButton.filled(onPressed: onSend, icon: const Icon(Icons.send)),
        ],
      ),
    );
  }
}
