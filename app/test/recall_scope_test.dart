import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voiceiq/src/data/ai_conversation.dart';
import 'package:voiceiq/src/data/api_client.dart';
import 'package:voiceiq/src/data/models.dart';

/// Scoping Recall to one journal.
///
/// The three states of `journal_id` are the whole contract, and two of them look
/// identical if you only glance: **omitted** lets the question name its own
/// journal, **empty** forbids that. Get them backwards and the "Ask all
/// memories" action silently re-narrows to the journal it was meant to escape.
void main() {
  late List<http.BaseRequest> sent;
  setUp(() => sent = []);

  ApiClient clientAnswering(Map<String, dynamic> answer) {
    final mock = MockClient((req) async {
      sent.add(req);
      return http.Response(jsonEncode(answer), 200);
    });
    return ApiClient(client: mock, baseUrl: 'http://test.invalid');
  }

  Map<String, dynamic> bodyOf(http.BaseRequest r) =>
      jsonDecode((r as http.Request).body) as Map<String, dynamic>;

  // -- what the client sends ---------------------------------------------------

  test('an omitted scope leaves journal_id off the request entirely', () async {
    await clientAnswering({'answer': 'ok'}).chat('what happened');
    // Absent, not null: the server reads "no scope chosen, you may infer one",
    // which is what lets a question name its own journal.
    expect(bodyOf(sent.single).containsKey('journal_id'), isFalse);
  });

  test('an explicit empty scope is sent, and is not the same as omitting it', () async {
    await clientAnswering({'answer': 'ok'}).chat('travel', journalId: '');
    expect(bodyOf(sent.single)['journal_id'], '');
  });

  test('a chosen journal is sent', () async {
    await clientAnswering({'answer': 'ok'}).chat('what happened', journalId: 'j1');
    expect(bodyOf(sent.single)['journal_id'], 'j1');
  });

  // -- what the client reads back ----------------------------------------------

  test('a scoped answer carries the journal it came from', () async {
    final answer = await clientAnswering({
      'answer': 'You drove up the coast.',
      'citations': [],
      'journal_id': 'j1',
      'journal_name': 'Travel',
    }).chat('travel');

    expect(answer.isScoped, isTrue);
    expect(answer.journalName, 'Travel');
  });

  test('an unscoped answer is not scoped', () async {
    final answer = await clientAnswering({'answer': 'ok', 'citations': []}).chat('x');
    expect(answer.isScoped, isFalse);
    expect(answer.journalName, isEmpty);
  });

  test('an answer from a server that predates journals still parses', () async {
    // The deployed image will not have these fields until it is redeployed, and
    // a missing key must not take down the Recall screen.
    final answer = ChatAnswer.fromJson({
      'answer': 'ok',
      'citations': [
        {'recording_id': 'a', 'event_date': '2025-08-16', 'snippet': 's', 'score': 0.5},
      ],
    });
    expect(answer.isScoped, isFalse);
    expect(answer.citations, hasLength(1));
  });

  // -- the conversation turn ---------------------------------------------------

  test('an AiMessage is only scoped when it is an answer', () {
    final answer = AiMessage('a', false, const [], 'j1', 'Travel');
    expect(answer.isScoped, isTrue);

    // A question the user typed while scoped is still the user's own words, not
    // something drawn from a journal — labelling it would be nonsense.
    final question = AiMessage('q', true, const [], 'j1', 'Travel');
    expect(question.isScoped, isFalse);
  });

  test('a turn with no scope defaults to unscoped', () {
    expect(AiMessage('a', false).isScoped, isFalse);
    expect(AiMessage('a', false).journalName, isEmpty);
  });

  // -- listing -----------------------------------------------------------------

  test('listRecordings distinguishes unfiled from unfiltered', () async {
    final client = MockClient((req) async {
      sent.add(req);
      return http.Response(jsonEncode([]), 200);
    });
    final api = ApiClient(client: client, baseUrl: 'http://test.invalid');

    await api.listRecordings();
    expect(sent.last.url.queryParameters.containsKey('journal_id'), isFalse);

    await api.listRecordings(journalId: '');
    expect(sent.last.url.queryParameters['journal_id'], '');

    await api.listRecordings(journalId: 'j1');
    expect(sent.last.url.queryParameters['journal_id'], 'j1');
  });

  // -- capture ------------------------------------------------------------------

  test('a typed memory carries its journal, and omits it when unfiled', () async {
    final client = MockClient((req) async {
      sent.add(req);
      return http.Response(jsonEncode({'id': 'a', 'event_date': '2025-08-16'}), 201);
    });
    final api = ApiClient(client: client, baseUrl: 'http://test.invalid');

    await api.createTextMemory(text: 'hello', journalId: 'j1');
    expect(bodyOf(sent.last)['journal_id'], 'j1');

    await api.createTextMemory(text: 'hello', journalId: '');
    expect(bodyOf(sent.last).containsKey('journal_id'), isFalse);
  });

  test('a recording parses its journal, defaulting to unfiled', () {
    expect(Recording.fromJson({'id': 'a', 'journal_id': 'j1'}).journalId, 'j1');
    // Every recording written before journals existed has no key at all.
    expect(Recording.fromJson({'id': 'a'}).journalId, isEmpty);
  });

  test('copyWith moves the journal without disturbing the star', () {
    final r = Recording.fromJson({'id': 'a', 'journal_id': 'j1', 'is_milestone': true});
    final moved = r.copyWith(journalId: 'j2');
    expect(moved.journalId, 'j2');
    expect(moved.isMilestone, isTrue);
    // And the star still moves without disturbing the journal.
    expect(r.copyWith(isMilestone: false).journalId, 'j1');
  });

  test('the journals ceiling falls back sanely before the profile lands', () {
    expect(const UserProfile().journalsMax, 2);
    expect(UserProfile.fromJson({'journals_max': 20}).journalsMax, 20);
    // A zero or missing ceiling would make the screen unusable, so it does not
    // trust the number blindly.
    expect(UserProfile.fromJson({}).journalsMax, 2);
    expect(UserProfile.fromJson({'journals_max': 0}).journalsMax, 2);
  });
}
