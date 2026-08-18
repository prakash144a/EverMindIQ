/// Data models mirroring the backend JSON payloads.
library;

/// Coerce a JSON value to text.
///
/// Several fields (title, summary, mood, …) originate in an LLM's JSON output,
/// which does not always honour the shape we asked for — a model may answer
/// `"mood": ["reflective", "warm"]` where a string was requested. A hard cast
/// there throws while parsing the list and takes down the whole screen, so one
/// odd recording hides every other one. Coerce instead.
String asText(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is List) return v.map(asText).where((s) => s.isNotEmpty).join(', ');
  return '$v';
}

/// Coerce a JSON value to a list of strings, tolerating a bare string.
List<String> asTextList(dynamic v) {
  if (v == null) return const [];
  if (v is List) return v.map(asText).where((s) => s.isNotEmpty).toList();
  final single = asText(v);
  return single.isEmpty ? const [] : [single];
}

int asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

class Recording {
  final String id;
  final String eventDate; // yyyy-mm-dd
  final DateTime recordedAt; // local time; drives the "2d ago" labels
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

  /// How the memory was captured: `voice` or `text`. A typed memory has no audio
  /// blob, so every playback affordance has to check [hasAudio] first.
  final String source;

  /// Which journal this memory is filed in; empty means unfiled. Filing is
  /// manual — nothing assigns this on the user's behalf.
  final String journalId;

  /// True once the user has starred/unstarred by hand; ingestion then leaves it alone.
  final bool isMilestoneManual;

  Recording({
    required this.id,
    required this.eventDate,
    required this.recordedAt,
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
    this.source = 'voice',
    this.journalId = '',
    this.isMilestoneManual = false,
  });

  bool get hasAudio => source != 'text';

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: asText(j['id']),
        eventDate: asText(j['event_date']),
        recordedAt: DateTime.tryParse(asText(j['recorded_at']))?.toLocal() ??
            DateTime.tryParse(asText(j['event_date'])) ??
            DateTime.now(),
        status: j['status'] == null ? 'uploaded' : asText(j['status']),
        durationSec: (j['duration_sec'] as num?)?.toDouble() ?? 0,
        transcript: asText(j['transcript']),
        language: asText(j['language']),
        title: asText(j['title']),
        summary: asText(j['summary']),
        tags: asTextList(j['tags']),
        people: asTextList(j['people']),
        places: asTextList(j['places']),
        mood: asText(j['mood']),
        isMilestone: j['is_milestone'] as bool? ?? false,
        // Every recording written before typed memories existed has no `source`,
        // and all of them were spoken.
        source: j['source'] == null ? 'voice' : asText(j['source']),
        journalId: asText(j['journal_id']),
        isMilestoneManual: j['is_milestone_manual'] as bool? ?? false,
      );

  /// Narrow copy for optimistic UI updates — the star and the journal, both of
  /// which are direct-manipulation controls that must move before the round trip.
  Recording copyWith({bool? isMilestone, String? journalId}) => Recording(
        id: id,
        eventDate: eventDate,
        recordedAt: recordedAt,
        status: status,
        durationSec: durationSec,
        transcript: transcript,
        language: language,
        title: title,
        summary: summary,
        tags: tags,
        people: people,
        places: places,
        mood: mood,
        isMilestone: isMilestone ?? this.isMilestone,
        source: source,
        journalId: journalId ?? this.journalId,
        isMilestoneManual: isMilestoneManual,
      );

  DateTime get eventDateTime => DateTime.parse(eventDate);
}

/// A named container the user files memories into.
///
/// One journal per memory, so this is a folder rather than a label — which is
/// what lets Recall be scoped to a single one and mean something.
class Journal {
  final String id;
  final String name;

  /// Index into the app's palette rather than a colour: the server has no
  /// business knowing the theme, and this stays right in dark mode.
  final int colorIndex;

  const Journal({required this.id, required this.name, this.colorIndex = 0});

  factory Journal.fromJson(Map<String, dynamic> j) => Journal(
        id: asText(j['id']),
        name: asText(j['name']),
        colorIndex: asInt(j['color_index']),
      );
}

/// Who the user is, once they've verified an email. Absent until then.
class UserProfile {
  final String preferredName;
  final String email;
  final bool emailVerified;
  final bool signupPromptDismissed;
  final bool hasProfile;

  /// `free` or `premium`. Server-owned — it lives in a collection no client can
  /// write — so this is a display value, never the gate. The gate is the API.
  final String tier;

  /// Longest typed memory this tier may save. The free default matters: the
  /// record screen has to be usable before the profile fetch lands.
  final int textMaxChars;

  /// How many journals this tier may keep. Same reasoning as [textMaxChars]:
  /// the journals screen must render a sane ceiling before the fetch lands.
  final int journalsMax;

  const UserProfile({
    this.preferredName = '',
    this.email = '',
    this.emailVerified = false,
    this.signupPromptDismissed = false,
    this.hasProfile = false,
    this.tier = 'free',
    this.textMaxChars = 1000,
    this.journalsMax = 2,
  });

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        preferredName: asText(j['preferred_name']),
        email: asText(j['email']),
        emailVerified: j['email_verified'] as bool? ?? false,
        signupPromptDismissed: j['signup_prompt_dismissed'] as bool? ?? false,
        hasProfile: j['has_profile'] as bool? ?? false,
        tier: j['tier'] == null ? 'free' : asText(j['tier']),
        // A zero or missing cap would silently make the field unusable, so fall
        // back to the free limit rather than trusting the number blindly.
        textMaxChars: asInt(j['text_max_chars']) > 0 ? asInt(j['text_max_chars']) : 1000,
        journalsMax: asInt(j['journals_max']) > 0 ? asInt(j['journals_max']) : 2,
      );

  bool get isPremium => tier == 'premium';

  /// Two letters for the avatar: first letter of the first and last words
  /// ("Prakash Annadurai" → "PA"), or the first two letters of a single name
  /// ("Dhivya" → "DH"). Empty when there's no usable name, so the caller can
  /// fall back to an icon.
  String get initials => initialsFor(preferredName);
}

/// See [UserProfile.initials]. Free function so it can be unit-tested directly.
String initialsFor(String name) {
  final words = name
      .split(RegExp(r'\s+'))
      .map((w) => w.replaceAll(RegExp(r'[^A-Za-z]'), ''))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';
  if (words.length == 1) {
    final only = words.first;
    return (only.length == 1 ? only : only.substring(0, 2)).toUpperCase();
  }
  return (words.first[0] + words.last[0]).toUpperCase();
}

/// Outcome of verifying a one-time code.
///
/// A restore moves the account onto the current session rather than switching
/// sessions, so there is no token to exchange and nothing to re-authenticate.
class VerifyResult {
  /// "signed_up" | "verified" | "restored"
  final String status;
  final UserProfile profile;

  /// For "restored": how many recordings came back.
  final int restoredRecordings;

  const VerifyResult({
    required this.status,
    required this.profile,
    this.restoredRecordings = 0,
  });

  bool get isRestore => status == 'restored';

  factory VerifyResult.fromJson(Map<String, dynamic> j) => VerifyResult(
        status: asText(j['status']),
        profile: UserProfile.fromJson((j['profile'] as Map?)?.cast<String, dynamic>() ?? {}),
        restoredRecordings: asInt((j['merged'] as Map?)?['recordings']),
      );
}

class Citation {
  final String recordingId;
  final String eventDate;
  final String snippet;
  final double score;
  final String source;

  Citation({
    required this.recordingId,
    required this.eventDate,
    required this.snippet,
    required this.score,
    this.source = 'voice',
  });

  bool get hasAudio => source != 'text';

  factory Citation.fromJson(Map<String, dynamic> j) => Citation(
        recordingId: asText(j['recording_id']),
        eventDate: asText(j['event_date']),
        snippet: asText(j['snippet']),
        score: (j['score'] as num?)?.toDouble() ?? 0,
        source: j['source'] == null ? 'voice' : asText(j['source']),
      );
}

class ChatAnswer {
  final String answer;
  final List<Citation> citations;

  /// Which journal this answer drew on; empty when it drew on everything. The
  /// scope may have been inferred from the question's wording, so an answer that
  /// was narrowed has to be able to say so — otherwise it just looks incomplete.
  final String journalId;
  final String journalName;

  ChatAnswer({
    required this.answer,
    required this.citations,
    this.journalId = '',
    this.journalName = '',
  });

  bool get isScoped => journalId.isNotEmpty;

  factory ChatAnswer.fromJson(Map<String, dynamic> j) => ChatAnswer(
        answer: j['answer'] as String? ?? '',
        citations: (j['citations'] as List? ?? const [])
            .map((c) => Citation.fromJson(c as Map<String, dynamic>))
            .toList(),
        journalId: asText(j['journal_id']),
        journalName: asText(j['journal_name']),
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
        range: asText(j['range']),
        dateFrom: asText(j['date_from']),
        dateTo: asText(j['date_to']),
        summary: asText(j['summary']),
        themes: asTextList(j['themes']),
        recordingCount: asInt(j['recording_count']),
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
        recordingId: asText(j['recording_id']),
        eventDate: asText(j['event_date']),
        title: asText(j['title']),
        summary: asText(j['summary']),
        yearsAgo: asInt(j['years_ago']),
        reason: asText(j['reason']),
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
