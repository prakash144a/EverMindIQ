import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/config.dart';
import '../../data/auth.dart';

/// Talk to AI about your past memories.
///
/// Connects to the backend `/live` WebSocket (a Gemini Live proxy in production; a text RAG
/// stand-in in mock mode). Voice capture/streaming is layered on top of this same channel in a
/// later phase — the transport is already in place.
class TalkScreen extends ConsumerStatefulWidget {
  const TalkScreen({super.key});

  @override
  ConsumerState<TalkScreen> createState() => _TalkScreenState();
}

class _Msg {
  final String text;
  final bool fromUser;
  final List<Map<String, dynamic>> citations;
  _Msg(this.text, this.fromUser, [this.citations = const []]);
}

class _TalkScreenState extends ConsumerState<TalkScreen> {
  WebSocketChannel? _channel;
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [];
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final token =
          await ref.read(firebaseAuthProvider).currentUser?.getIdToken() ??
              AppConfig.devUid;
      final ch = WebSocketChannel.connect(AppConfig.wsLiveUri(token));
      ch.stream.listen(
        _onMessage,
        onDone: () => setState(() => _connected = false),
        onError: (_) => setState(() => _connected = false),
      );
      setState(() {
        _channel = ch;
        _connected = true;
      });
    } catch (_) {
      setState(() => _connected = false);
    }
  }

  void _onMessage(dynamic data) {
    try {
      final j = jsonDecode(data as String) as Map<String, dynamic>;
      if (j.containsKey('error')) return;
      setState(() {
        _messages.add(_Msg(
          j['answer'] as String? ?? '',
          false,
          (j['citations'] as List? ?? const []).cast<Map<String, dynamic>>(),
        ));
      });
      _scrollToBottom();
    } catch (_) {/* ignore malformed frame */}
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || _channel == null) return;
    setState(() => _messages.add(_Msg(text, true)));
    _channel!.sink.add(jsonEncode({'question': text}));
    _controller.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!_connected)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                const Icon(Icons.cloud_off, size: 16),
                const SizedBox(width: 8),
                const Expanded(child: Text('Disconnected from AI')),
                TextButton(onPressed: _connect, child: const Text('Reconnect')),
              ]),
            ),
          ),
        Expanded(
          child: _messages.isEmpty
              ? const _TalkIntro()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _Bubble(_messages[i]),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Ask anything about your memories…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.msg);
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final align = msg.fromUser ? Alignment.centerRight : Alignment.centerLeft;
    final color = msg.fromUser ? scheme.primary : scheme.surfaceContainerHighest;
    final textColor = msg.fromUser ? scheme.onPrimary : scheme.onSurface;
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(msg.text, style: TextStyle(color: textColor)),
            if (msg.citations.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: msg.citations
                    .map((c) => Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text('${c['event_date']}', style: const TextStyle(fontSize: 11)),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TalkIntro extends StatelessWidget {
  const _TalkIntro();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 56),
            const SizedBox(height: 12),
            Text('Ask about your past', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'e.g. "What was I worried about last spring?" · "Summarize my trips this year."',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
