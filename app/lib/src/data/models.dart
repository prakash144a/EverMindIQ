/// Data models mirroring the backend JSON payloads.

class Recording {
  final String id;
  final String eventDate; // yyyy-mm-dd
  final String status;
  final double durationSec;
  final String transcript;
  final String language;
  final String title;
  final String summary;
  final List<String> tags;
  final List<String> people;
  final List<String> places;
  final String mood;
  final bool isMilestone;

  Recording({
    required this.id,
    required this.eventDate,
    required this.status,
    required this.durationSec,
    required this.transcript,
    required this.language,
    required this.title,
    required this.summary,
    required this.tags,
    required this.people,
    required this.places,
    required this.mood,
    required this.isMilestone,
  });

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: j['id'] as String,
        eventDate: j['event_date'] as String,
        status: j['status'] as String? ?? 'uploaded',
        durationSec: (j['duration_sec'] as num?)?.toDouble() ?? 0,
        transcript: j['transcript'] as String? ?? '',
        language: j['language'] as String? ?? '',
        title: j['title'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
        tags: (j['tags'] as List?)?.cast<String>() ?? const [],
        people: (j['people'] as List?)?.cast<String>() ?? const [],
        places: (j['places'] as List?)?.cast<String>() ?? const [],
        mood: j['mood'] as String? ?? '',
        isMilestone: j['is_milestone'] as bool? ?? false,
      );

  DateTime get eventDateTime => DateTime.parse(eventDate);
}

class Citation {
  final String recordingId;
  final String eventDate;
  final String snippet;
  final double score;

  Citation({
    required this.recordingId,
    required this.eventDate,
    required this.snippet,
    required this.score,
  });

  factory Citation.fromJson(Map<String, dynamic> j) => Citation(
        recordingId: j['recording_id'] as String,
        eventDate: j['event_date'] as String,
        snippet: j['snippet'] as String? ?? '',
        score: (j['score'] as num?)?.toDouble() ?? 0,
      );
}

class ChatAnswer {
  final String answer;
  final List<Citation> citations;

  ChatAnswer({required this.answer, required this.citations});

  factory ChatAnswer.fromJson(Map<String, dynamic> j) => ChatAnswer(
        answer: j['answer'] as String? ?? '',
        citations: (j['citations'] as List? ?? const [])
            .map((c) => Citation.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

class Insight {
  final String range;
  final String dateFrom;
  final String dateTo;
  final String summary;
  final List<String> themes;
  final int recordingCount;

  Insight({
    required this.range,
    required this.dateFrom,
    required this.dateTo,
    required this.summary,
    required this.themes,
    required this.recordingCount,
  });

  factory Insight.fromJson(Map<String, dynamic> j) => Insight(
        range: j['range'] as String,
        dateFrom: j['date_from'] as String,
        dateTo: j['date_to'] as String,
        summary: j['summary'] as String? ?? '',
        themes: (j['themes'] as List?)?.cast<String>() ?? const [],
        recordingCount: j['recording_count'] as int? ?? 0,
      );
}

class MemoryItem {
  final String recordingId;
  final String eventDate;
  final String title;
  final String summary;
  final int yearsAgo;
  final String reason;

  MemoryItem({
    required this.recordingId,
    required this.eventDate,
    required this.title,
    required this.summary,
    required this.yearsAgo,
    required this.reason,
  });

  factory MemoryItem.fromJson(Map<String, dynamic> j) => MemoryItem(
        recordingId: j['recording_id'] as String,
        eventDate: j['event_date'] as String,
        title: j['title'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
        yearsAgo: j['years_ago'] as int? ?? 0,
        reason: j['reason'] as String? ?? '',
      );
}

class UserSettings {
  final bool onThisDayEnabled;
  final int slideshowIntervalSec;
  final bool notificationsEnabled;
  final String answerLanguage;
  final int retentionDays;

  UserSettings({
    required this.onThisDayEnabled,
    required this.slideshowIntervalSec,
    required this.notificationsEnabled,
    required this.answerLanguage,
    required this.retentionDays,
  });

  factory UserSettings.fromJson(Map<String, dynamic> j) => UserSettings(
        onThisDayEnabled: j['on_this_day_enabled'] as bool? ?? true,
        slideshowIntervalSec: j['slideshow_interval_sec'] as int? ?? 6,
        notificationsEnabled: j['notifications_enabled'] as bool? ?? true,
        answerLanguage: j['answer_language'] as String? ?? 'auto',
        retentionDays: j['retention_days'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'on_this_day_enabled': onThisDayEnabled,
        'slideshow_interval_sec': slideshowIntervalSec,
        'notifications_enabled': notificationsEnabled,
        'answer_language': answerLanguage,
        'retention_days': retentionDays,
      };

  UserSettings copyWith({
    bool? onThisDayEnabled,
    int? slideshowIntervalSec,
    bool? notificationsEnabled,
    String? answerLanguage,
    int? retentionDays,
  }) =>
      UserSettings(
        onThisDayEnabled: onThisDayEnabled ?? this.onThisDayEnabled,
        slideshowIntervalSec: slideshowIntervalSec ?? this.slideshowIntervalSec,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        answerLanguage: answerLanguage ?? this.answerLanguage,
        retentionDays: retentionDays ?? this.retentionDays,
      );
}
