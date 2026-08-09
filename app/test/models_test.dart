import 'package:flutter_test/flutter_test.dart';
import 'package:voiceiq/src/data/models.dart';

void main() {
  test('Recording.fromJson parses fields and defaults', () {
    final r = Recording.fromJson({
      'id': 'r1',
      'event_date': '2024-03-10',
      'status': 'indexed',
      'transcript': 'Hello world',
      'language': 'en',
      'title': 'A day',
      'people': ['Sarah'],
      'is_milestone': true,
    });
    expect(r.id, 'r1');
    expect(r.eventDateTime.month, 3);
    expect(r.people, ['Sarah']);
    expect(r.isMilestone, isTrue);
    expect(r.tags, isEmpty); // missing -> default
  });

  test('UserSettings round-trips through JSON', () {
    final s = UserSettings.fromJson({'answer_language': 'ta', 'on_this_day_enabled': false});
    expect(s.answerLanguage, 'ta');
    expect(s.onThisDayEnabled, isFalse);

    final back = s.copyWith(answerLanguage: 'en').toJson();
    expect(back['answer_language'], 'en');
    expect(back['on_this_day_enabled'], false);
  });

  test('ChatAnswer parses citations', () {
    final a = ChatAnswer.fromJson({
      'answer': 'Based on your memories: cake',
      'citations': [
        {'recording_id': 'r1', 'event_date': '2024-01-01', 'snippet': 'cake', 'score': 0.9}
      ],
    });
    expect(a.citations.single.recordingId, 'r1');
    expect(a.citations.single.score, closeTo(0.9, 1e-9));
  });
}
