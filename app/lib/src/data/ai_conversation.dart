import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config.dart';

/// A single turn in a conversation with the memory AI.
class AiMessage {
  AiMessage(this.text, this.fromUser, [this.citations = const []]);

  final String text;
  final bool fromUser;
  final List<Map<String, dynamic>> citations;
}

/// Fetches a bearer token (a Firebase ID token in production).
typedef TokenFetch = Future<String?> Function();

/// Drives a conversation over the backend `/live` WebSocket (a Gemini Live
/// proxy in production; a text RAG stand-in in mock mode). Shared by the
/// voice-first Recall screen and the text Chat screen so the transport and
/// message state live in one place.
///
/// Voice I/O (mic streaming + spoken answers) rides on this same channel in a
/// later phase; today both screens send/receive text.
class AiConversation extends ChangeNotifier {
  AiConversation(this._tokenFetch);

  final TokenFetch _tokenFetch;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  final List<AiMessage> messages = [];
  bool connected = false;
  bool thinking = false;

  Future<void> connect() async {
    try {
      final token = await _tokenFetch() ?? AppConfig.devUid;
      final ch = WebSocketChannel.connect(AppConfig.wsLiveUri(token));
      _sub = ch.stream.listen(
        _onMessage,
        onDone: () {
          connected = false;
          notifyListeners();
        },
        onError: (_) {
          connected = false;
          notifyListeners();
        },
      );
      _channel = ch;
      connected = true;
      notifyListeners();
    } catch (_) {
      connected = false;
      notifyListeners();
    }
  }

  void _onMessage(dynamic data) {
    try {
      final j = jsonDecode(data as String) as Map<String, dynamic>;
      if (j.containsKey('error')) {
        thinking = false;
        notifyListeners();
        return;
      }
      messages.add(AiMessage(
        j['answer'] as String? ?? '',
        false,
        (j['citations'] as List? ?? const []).cast<Map<String, dynamic>>(),
      ));
      thinking = false;
      notifyListeners();
    } catch (_) {
      /* ignore malformed frame */
    }
  }

  /// Sends a question. No-op if empty or disconnected.
  void send(String text) {
    final t = text.trim();
    if (t.isEmpty || _channel == null) return;
    messages.add(AiMessage(t, true));
    thinking = true;
    _channel!.sink.add(jsonEncode({'question': t}));
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
