import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/config.dart';
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
  ApiClient({http.Client? client, String? baseUrl, TokenProvider? tokenProvider})
      : _client = client ?? http.Client(),
        _base = baseUrl ?? AppConfig.apiBaseUrl,
        _tokenProvider = tokenProvider;

  final http.Client _client;
  final String _base;
  final TokenProvider? _tokenProvider;

  Future<Map<String, String>> _headers({bool json = true}) async {
    final token = (await _tokenProvider?.call()) ?? AppConfig.devUid;
    return {
      'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  Uri _u(String path, [Map<String, dynamic>? q]) => Uri.parse('$_base$path').replace(
        queryParameters: q?.map((k, v) => MapEntry(k, '$v')),
      );

  Never _fail(http.Response r) =>
      throw ApiException(r.statusCode, r.body);

  // -- upload + create ---------------------------------------------------

  /// Full record flow: get signed URL, PUT bytes, register the recording.
  Future<Recording> uploadAndCreate({
    required Uint8List audioBytes,
    required String contentType,
    double durationSec = 0,
    DateTime? eventDate,
    String? title,
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
    };
    final rec = await _client.post(_u('/recordings'), headers: await _headers(), body: jsonEncode(body));
    if (rec.statusCode != 201) _fail(rec);
    return Recording.fromJson(jsonDecode(rec.body) as Map<String, dynamic>);
  }

  // -- reads -------------------------------------------------------------

  Future<List<Recording>> listRecordings({DateTime? from, DateTime? to}) async {
    final r = await _client.get(
      _u('/recordings', {
        if (from != null) 'date_from': _ymd(from),
        if (to != null) 'date_to': _ymd(to),
      }),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail(r);
    return (jsonDecode(r.body) as List)
        .map((e) => Recording.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Raw audio bytes for a recording, for in-app playback. Served behind auth by the backend.
  Future<Uint8List> fetchAudioBytes(String recordingId) async {
    final r = await _client.get(_u('/recordings/$recordingId/audio'),
        headers: await _headers(json: false));
    if (r.statusCode != 200) _fail(r);
    return r.bodyBytes;
  }

  Future<ChatAnswer> chat(String question, {String? answerLanguage}) async {
    final r = await _client.post(_u('/chat'),
        headers: await _headers(),
        body: jsonEncode({
          'question': question,
          if (answerLanguage != null) 'answer_language': answerLanguage,
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
    final r = await _client.put(_u('/settings'), headers: await _headers(), body: jsonEncode(s.toJson()));
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
