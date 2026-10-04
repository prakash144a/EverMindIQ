import 'package:flutter/foundation.dart';

import 'models.dart';

/// A single turn in a conversation with the memory AI.
class AiMessage {
  AiMessage(
    this.text,
    this.fromUser, [
    this.citations = const [],
    this.journalId = '',
    this.journalName = '',
  ]);

  final String text;
  final bool fromUser;
  final List<Citation> citations;

  /// Set when the answer was drawn from a single journal — which may have been
  /// inferred from the question rather than chosen with the picker. An answer
  /// narrowed without saying so reads as an answer that missed things.
  final String journalId;
  final String journalName;

  bool get isScoped => !fromUser && journalId.isNotEmpty;
}

/// Asks one question and returns its answer. In the app this is
/// `ApiClient.chat`; a test hands in whatever it likes.
typedef Ask = Future<ChatAnswer> Function(String question, {String? journalId});

/// The typed conversation on the Recall screen: the turns so far, and whether
/// an answer is on its way.
///
/// Each question is one ordinary request to `/chat`. It used to ride the
/// `/live` WebSocket instead, and that had stopped working without anyone
/// noticing: the socket was opened without the session id every other call
/// carries, so the server refused the handshake, and a question typed into a
/// socket that never opened simply sat at "Recalling…" forever. A typed
/// question has no use for a socket anyway — the server answers each one on its
/// own, with nothing kept between them — and as a request it gets the session,
/// the sign-out handling and the error reporting that every other call already
/// has. It also means Recall can stay open beside the memories on a wide screen
/// without holding a connection open for as long as the tab is.
///
/// Spoken conversations are a different thing and keep their socket; see
/// `LiveVoiceSession`.
class AiConversation extends ChangeNotifier {
  AiConversation(this._ask);

  final Ask _ask;

  final List<AiMessage> messages = [];

  int _pending = 0;
  bool _disposed = false;

  /// An answer is on its way.
  bool get thinking => _pending > 0;

  /// Asks a question, optionally scoped to one journal.
  ///
  /// [journalId] is three-state, as on the server: null lets the question name
  /// its own journal, an empty string forces every memory, an id scopes to that
  /// journal. Empty text is ignored.
  ///
  /// A failure becomes a turn in the conversation rather than an exception:
  /// the question is on screen, and something has to answer it.
  Future<void> send(String text, {String? journalId}) async {
    final question = text.trim();
    if (question.isEmpty) return;
    messages.add(AiMessage(question, true));
    _pending++;
    _changed();
    try {
      final answer = await _ask(question, journalId: journalId);
      messages.add(AiMessage(
        answer.answer,
        false,
        answer.citations,
        answer.journalId,
        answer.journalName,
      ));
    } catch (_) {
      messages.add(AiMessage(
        'I could not reach your memories just now. Check your connection and ask again.',
        false,
      ));
    } finally {
      _pending--;
      _changed();
    }
  }

  void _changed() {
    // An answer can land after the screen that asked has gone.
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
