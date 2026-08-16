import 'package:flutter_test/flutter_test.dart';
import 'package:voiceiq/src/data/models.dart';

/// Gemini is asked for strings but sometimes answers with arrays, and the
/// backend stored that verbatim. A hard cast then threw
/// `type 'List<dynamic>' is not a subtype of type 'String?'` while parsing the
/// list, so one odd recording hid every other one behind an error card.
void main() {
  test('a recording whose text fields came back as lists still parses', () {
    final rec = Recording.fromJson({
      'id': 'a',
      'event_date': '2026-08-16',
      'recorded_at': '2026-08-16T10:30:00Z',
      'status': 'indexed',
      'title': ['Fishing trip', 'with Dad'],
      'summary': ['I drove up to the lake.', 'We fished all morning.'],
      'mood': ['reflective', 'warm'],
      'language': ['ta', 'en'],
    });

    expect(rec.title, 'Fishing trip, with Dad');
    expect(rec.summary, 'I drove up to the lake., We fished all morning.');
    expect(rec.mood, 'reflective, warm');
    expect(rec.language, 'ta, en');
  });

  test('list fields tolerate a bare string', () {
    final rec = Recording.fromJson({
      'id': 'a',
      'event_date': '2026-08-16',
      'status': 'indexed',
      'tags': 'fishing',
      'people': null,
      'places': ['Lake Ontario'],
    });

    expect(rec.tags, ['fishing']);
    expect(rec.people, isEmpty);
    expect(rec.places, ['Lake Ontario']);
  });

  test('missing and empty fields fall back rather than throwing', () {
    final rec = Recording.fromJson({'id': 'a', 'event_date': '2026-08-16'});
    expect(rec.status, 'uploaded');
    expect(rec.title, isEmpty);
    expect(rec.mood, isEmpty);
    expect(rec.tags, isEmpty);
  });

  test('the other LLM-fed models tolerate the same shapes', () {
    final item = MemoryItem.fromJson({
      'recording_id': 'a',
      'event_date': '2026-08-16',
      'title': ['One', 'Two'],
      'years_ago': '3',
    });
    expect(item.title, 'One, Two');
    expect(item.yearsAgo, 3);

    final insight = Insight.fromJson({
      'range': 'week',
      'date_from': '2026-08-10',
      'date_to': '2026-08-16',
      'summary': ['a', 'b'],
      'themes': 'solo-theme',
      'recording_count': 2.0,
    });
    expect(insight.summary, 'a, b');
    expect(insight.themes, ['solo-theme']);
    expect(insight.recordingCount, 2);
  });
}
