import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/device_identity.dart';
import '../core/session_store.dart';
import 'models.dart';

/// Supplies a bearer token (a Firebase ID token in production), or null.
typedef TokenProvider = Future<String?> Function();

/// Thin REST client for the VoiceIQ backend.
///
/// Auth: sends `Authorization: Bearer <token>`, where the token comes from
/// [tokenProvider] (a live Firebase ID token, fetched fresh per request so it
/// stays valid). Falls back to [AppConfig.devUid] when no provider is given
/// (local / mock-mode development).
class ApiClient {
  ApiClient({
    http.Client? client,
    String? baseUrl,
    TokenProvider? tokenProvider,
    this.onSessionEnded,
  })  : _client = client ?? http.Client(),
        _base = baseUrl ?? AppConfig.apiBaseUrl,
        _tokenProvider = tokenProvider;

  final http.Client _client;
  final String _base;
  final TokenProvider? _tokenProvider;

  /// Told whenever the server says this device no longer holds the account, so
  /// the app can return to the login screen from wherever it happens to be.
  /// Wired once, here, rather than by every caller remembering to catch it.
  final void Function(SessionEndedException)? onSessionEnded;

  Future<Map<String, String>> _headers({bool json = true}) async {
    final token = (await _tokenProvider?.call()) ?? AppConfig.devUid;
    final installId = DeviceIdentity.installId;
    final sessionId = SessionStore.sessionId;
    return {
      'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
      // Which sign-in this is. A token alone is not enough: an account is held
      // by one device at a time, and the server refuses anything else.
      if (sessionId.isNotEmpty) 'X-Session-Id': sessionId,
      // Ride along on requests we are making anyway. A dedicated heartbeat call
      // would cost a round trip on every launch, and attaching this to the
      // record payload instead would tell us nothing about people who open the
      // app and never record. The server throttles the resulting write.
      if (installId.isNotEmpty) 'X-Install-Id': installId,
      'X-Platform': DeviceIdentity.platform,
      'X-App-Version': AppConfig.appVersion,
    };
  }

  Uri _u(String path, [Map<String, dynamic>? q]) => Uri.parse('$_base$path').replace(
        queryParameters: q?.map((k, v) => MapEntry(k, '$v')),
      );

  /// Turn a failed response into the most specific exception we can.
  ///
  /// A 401 carrying a session code is not an ordinary failure: it is the app
  /// being told, mid-request, that it has been signed out. Recognising it here
  /// means every call gets that handling, including the ones written later.
  Never _fail(http.Response r) {
    if (r.statusCode == 401) {
      final detail = _detail(r);
      final code = asText(detail?['code']);
      if (code == 'session_replaced' || code == 'signed_out') {
        final ended = SessionEndedException(
          code: code,
          message: asText(detail?['message']),
          replacedBy: code == 'session_replaced'
              ? DeviceSessionInfo.fromJson(detail!.cast<String, dynamic>())
              : null,
        );
        onSessionEnded?.call(ended);
        throw ended;
      }
    }
    throw ApiException(r.statusCode, r.body);
  }

  /// The `detail` object of an error body, when there is one to read.
  static Map<String, dynamic>? _detail(http.Response r) {
    try {
      final body = jsonDecode(r.body);
      if (body is Map && body['detail'] is Map) {
        return (body['detail'] as Map).cast<String, dynamic>();
      }
    } catch (_) {
      // A non-JSON error body (a proxy's HTML, say) is simply not a session
      // message; fall through to the ordinary exception.
    }
    return null;
  }

  // -- upload + create ---------------------------------------------------

  /// Full record flow: get signed URL, PUT bytes, register the recording.
  Future<Recording> uploadAndCreate({
    required Uint8List audioBytes,
    required String contentType,
    double durationSec = 0,
    DateTime? eventDate,
    String? title,
    String? journalId,
  }) async {
    // 1) signed URL
    final up = await _client.post(_u('/uploads'),
        headers: await _headers(), body: jsonEncode({'content_type': contentType}));
    if (up.statusCode != 200) _fail(up);
    final upJson = jsonDecode(up.body) as Map<String, dynamic>;

    // 2) PUT audio directly to (signed) storage.
    // Real mode returns an absolute signed URL; mock mode returns a backend-relative path we
    // resolve against the API base.
    final rawUploadUrl = upJson['upload_url'] as String;
    final uploadUri = rawUploadUrl.startsWith('http')
        ? Uri.parse(rawUploadUrl)
        : Uri.parse('$_base$rawUploadUrl');
    final putResp = await _client.put(
      uploadUri,
      headers: (upJson['headers'] as Map).cast<String, String>(),
      body: audioBytes,
    );
    if (putResp.statusCode >= 400) _fail(putResp);

    // 3) register recording
    final body = <String, dynamic>{
      'audio_path': upJson['audio_path'],
      'duration_sec': durationSec,
      if (eventDate != null) 'event_date': _ymd(eventDate),
      if (title != null && title.isNotEmpty) 'title': title,
      if (journalId != null && journalId.isNotEmpty) 'journal_id': journalId,
    };
    final rec =
        await _client.post(_u('/recordings'), headers: await _headers(), body: jsonEncode(body));
    if (rec.statusCode != 201) _fail(rec);
    return Recording.fromJson(jsonDecode(rec.body) as Map<String, dynamic>);
  }

  /// Save a typed memory.
  ///
  /// Deliberately not routed through [uploadAndCreate]: its first two steps
  /// exist only to produce an `audio_path`, and a typed memory has no audio.
  Future<Recording> createTextMemory({
    required String text,
    DateTime? eventDate,
    String? title,
    String? journalId,
  }) async {
    final body = <String, dynamic>{
      'text': text,
      if (eventDate != null) 'event_date': _ymd(eventDate),
      if (title != null && title.isNotEmpty) 'title': title,
      if (journalId != null && journalId.isNotEmpty) 'journal_id': journalId,
    };
    final r = await _client.post(_u('/recordings/text'),
        headers: await _headers(), body: jsonEncode(body));
    if (r.statusCode != 201) _fail(r);
    return Recording.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // -- reads -------------------------------------------------------------

  /// Every recording, or one journal's worth.
  ///
  /// [journalId] is three-state, mirroring the server: null filters nothing, an
  /// empty string selects only *unfiled* memories, and an id selects that
  /// journal. Collapsing the first two would make the Unfiled view impossible.
  Future<List<Recording>> listRecordings({
    DateTime? from,
    DateTime? to,
    String? journalId,
  }) async {
    final r = await _client.get(
      _u('/recordings', {
        if (from != null) 'date_from': _ymd(from),
        if (to != null) 'date_to': _ymd(to),
        if (journalId != null) 'journal_id': journalId,
      }),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail(r);
    return (jsonDecode(r.body) as List)
        .map((e) => Recording.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // -- account -----------------------------------------------------------

  Future<UserProfile> getProfile() async {
    final r = await _client.get(_u('/profile'), headers: await _headers());
    if (r.statusCode != 200) _fail(r);
    return UserProfile.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<UserProfile> patchProfile({String? preferredName, bool? signupPromptDismissed}) async {
    final r = await _client.patch(
      _u('/profile'),
      headers: await _headers(),
      body: jsonEncode({
        if (preferredName != null) 'preferred_name': preferredName,
        if (signupPromptDismissed != null) 'signup_prompt_dismissed': signupPromptDismissed,
      }),
    );
    if (r.statusCode != 200) _fail(r);
    return UserProfile.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Ask the backend to email a one-time code.
  Future<void> requestOtp(String email) async {
    final r = await _client.post(
      _u('/auth/otp/request'),
      headers: await _headers(),
      body: jsonEncode({'email': email}),
    );
    if (r.statusCode != 204) _fail(r);
  }

  /// Check the code. Returns a ticket, and whatever stands in the way of it.
  Future<VerifyResult> verifyOtp({
    required String email,
    required String code,
    String preferredName = '',
  }) async {
    final r = await _client.post(
      _u('/auth/otp/verify'),
      headers: await _headers(),
      body: jsonEncode({
        'email': email,
        'code': code,
        'preferred_name': preferredName,
      }),
    );
    if (r.statusCode != 200) _fail(r);
    return VerifyResult.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Spend a ticket for a session on this device.
  ///
  /// Throws [SessionInUseException] when the account is open elsewhere and
  /// [takeover] was not given — the caller is expected to ask the person, not
  /// to retry silently.
  Future<SignInResult> claimSession(String ticket, {bool takeover = false}) async {
    final r = await _client.post(
      _u('/auth/session'),
      headers: await _headers(),
      body: jsonEncode({'ticket': ticket, 'takeover': takeover}),
    );
    if (r.statusCode == 409) {
      final held = _detail(r)?['active_session'];
      if (held is Map) {
        throw SessionInUseException(
          DeviceSessionInfo.fromJson(held.cast<String, dynamic>()),
        );
      }
    }
    if (r.statusCode != 200) _fail(r);
    return SignInResult.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// End this device's hold on the account, so the next person gets their own.
  Future<void> logout() async {
    final r = await _client.post(_u('/auth/logout'), headers: await _headers());
    // 401 means the session was already gone — the outcome we wanted.
    if (r.statusCode != 204 && r.statusCode != 401) _fail(r);
  }

  /// Submit a problem report or suggestion. [diagnostics] carries captured error
  /// text the user chose to attach; it is optional so a report is never blocked
  /// on having any.
  Future<void> submitFeedback({
    required String kind,
    required String message,
    String diagnostics = '',
    String appVersion = '',
    String platform = '',
  }) async {
    final r = await _client.post(
      _u('/feedback'),
      headers: await _headers(),
      body: jsonEncode({
        'kind': kind,
        'message': message,
        'diagnostics': diagnostics,
        'app_version': appVersion,
        'platform': platform,
      }),
    );
    if (r.statusCode != 201) _fail(r);
  }

  /// Star or unstar a recording. The backend records that the choice was made by
  /// hand, so re-running ingestion won't overwrite it.
  Future<Recording> setMilestone(String recordingId, bool value) async {
    final r = await _client.patch(
      _u('/recordings/$recordingId'),
      headers: await _headers(),
      body: jsonEncode({'is_milestone': value}),
    );
    if (r.statusCode != 200) _fail(r);
    return Recording.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// File a memory into a journal, or unfile it with an empty string.
  Future<Recording> setRecordingJournal(String recordingId, String journalId) async {
    final r = await _client.patch(
      _u('/recordings/$recordingId'),
      headers: await _headers(),
      body: jsonEncode({'journal_id': journalId}),
    );
    if (r.statusCode != 200) _fail(r);
    return Recording.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // -- journals ----------------------------------------------------------

  Future<List<Journal>> listJournals() async {
    final r = await _client.get(_u('/journals'), headers: await _headers());
    if (r.statusCode != 200) _fail(r);
    return (jsonDecode(r.body) as List)
        .map((e) => Journal.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Create a journal. Throws [ApiException] with a 403 at the tier ceiling and
  /// a 409 on a duplicate name; the caller turns both into a sentence.
  Future<Journal> createJournal(String name, {int colorIndex = 0}) async {
    final r = await _client.post(_u('/journals'),
        headers: await _headers(), body: jsonEncode({'name': name, 'color_index': colorIndex}));
    if (r.statusCode != 201) _fail(r);
    return Journal.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<Journal> updateJournal(String id, {String? name, int? colorIndex}) async {
    final r = await _client.patch(_u('/journals/$id'),
        headers: await _headers(),
        body: jsonEncode({
          if (name != null) 'name': name,
          if (colorIndex != null) 'color_index': colorIndex,
        }));
    if (r.statusCode != 200) _fail(r);
    return Journal.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Delete a journal. Its memories are unfiled, never deleted; the returned
  /// count is how many moved, so the app can say so.
  Future<int> deleteJournal(String id) async {
    final r = await _client.delete(_u('/journals/$id'), headers: await _headers());
    if (r.statusCode != 200) _fail(r);
    return asInt((jsonDecode(r.body) as Map<String, dynamic>)['unfiled']);
  }

  /// Erase one memory: its metadata, its transcript, its search index entry and
  /// its audio object. Nothing is archived anywhere, so this cannot be undone.
  Future<void> deleteRecording(String id) async {
    final r = await _client.delete(_u('/recordings/$id'), headers: await _headers());
    // 404 is treated as success: the memory is gone, which is what was asked
    // for. Two devices deleting the same one must not leave the second holding
    // an error about a memory neither of them can see any more.
    if (r.statusCode != 204 && r.statusCode != 404) _fail(r);
  }

  /// Erase the whole account server-side: every memory, every audio file, the
  /// journals, the insights, the settings and the email link.
  ///
  /// Does **not** touch the Firebase identity — that is the caller's job, and it
  /// has to happen after this succeeds, since the token is what authorises it.
  Future<void> deleteAccount() async {
    final r = await _client.delete(_u('/account'), headers: await _headers());
    if (r.statusCode != 204) _fail(r);
  }

  /// Raw audio bytes for a recording, for in-app playback. Served behind auth by the backend.
  Future<Uint8List> fetchAudioBytes(String recordingId) async {
    final r = await _client.get(_u('/recordings/$recordingId/audio'),
        headers: await _headers(json: false));
    if (r.statusCode != 200) _fail(r);
    return r.bodyBytes;
  }

  /// Ask a question. [journalId] is three-state, as on the server: null lets the
  /// question name its own journal, `''` forces every memory, an id scopes.
  Future<ChatAnswer> chat(
    String question, {
    String? answerLanguage,
    String? journalId,
  }) async {
    final r = await _client.post(_u('/chat'),
        headers: await _headers(),
        body: jsonEncode({
          'question': question,
          if (answerLanguage != null) 'answer_language': answerLanguage,
          if (journalId != null) 'journal_id': journalId,
        }));
    if (r.statusCode != 200) _fail(r);
    return ChatAnswer.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<Insight> insight(String range, {DateTime? from, DateTime? to}) async {
    final r = await _client.post(_u('/insights'),
        headers: await _headers(),
        body: jsonEncode({
          'range': range,
          if (from != null) 'date_from': _ymd(from),
          if (to != null) 'date_to': _ymd(to),
        }));
    if (r.statusCode != 200) _fail(r);
    return Insight.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<List<MemoryItem>> onThisDay({DateTime? date}) async {
    final r = await _client.get(
      _u('/memories/on-this-day', {if (date != null) 'for_date': _ymd(date)}),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List? ?? const [])
        .map((e) => MemoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<UserSettings> getSettings() async {
    final r = await _client.get(_u('/settings'), headers: await _headers());
    if (r.statusCode != 200) _fail(r);
    return UserSettings.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<UserSettings> saveSettings(UserSettings s) async {
    final r =
        await _client.put(_u('/settings'), headers: await _headers(), body: jsonEncode(s.toJson()));
    if (r.statusCode != 200) _fail(r);
    return UserSettings.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class ApiException implements Exception {
  final int statusCode;
  final String body;
  ApiException(this.statusCode, this.body);
  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// This device is no longer the one signed in to the account.
///
/// Thrown from any call, because it can happen during any call: someone signed
/// in on another phone, or signed out here. The app drops its session and shows
/// [message] rather than surfacing an unexplained failure — being turned away
/// mid-request is the *only* moment we get to say why.
class SessionEndedException implements Exception {
  /// "session_replaced" | "signed_out"
  final String code;
  final String message;

  /// The device that took the account over, when that is what happened.
  final DeviceSessionInfo? replacedBy;

  SessionEndedException({
    required this.code,
    required this.message,
    this.replacedBy,
  });

  bool get wasReplaced => code == 'session_replaced';

  @override
  String toString() => 'SessionEndedException($code): $message';
}

/// The account is open on another device, and taking it over was not asked for.
///
/// A question rather than an error: the login screen shows [activeSession] and
/// calls back with `takeover: true` if the person says yes.
class SessionInUseException implements Exception {
  final DeviceSessionInfo activeSession;
  SessionInUseException(this.activeSession);
  @override
  String toString() => 'SessionInUseException(${activeSession.device})';
}
