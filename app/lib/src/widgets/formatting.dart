import 'package:intl/intl.dart';

/// Shared date/label helpers, consolidated from the per-feature `_pretty`
/// copies that previously lived in home/insight/calendar screens.

/// Formats a `yyyy-mm-dd` string as e.g. "Aug 15, 2025"; returns the input
/// unchanged if it can't be parsed.
String prettyDate(String ymd) {
  try {
    return DateFormat.yMMMd().format(DateTime.parse(ymd));
  } catch (_) {
    return ymd;
  }
}

/// Formats a [DateTime] as e.g. "Aug 15, 2025".
String prettyDateTime(DateTime d) => DateFormat.yMMMd().format(d);

/// Social-feed style age label: "just now", "5m ago", "2d ago", "3wk ago".
String relativeTime(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.isNegative || d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  if (d.inDays < 30) return '${d.inDays ~/ 7}wk ago';
  if (d.inDays < 365) return '${d.inDays ~/ 30}mo ago';
  return '${d.inDays ~/ 365}y ago';
}

/// True while the ingestion pipeline still owes this recording a transcript.
bool isProcessing(String status) => status == 'uploaded' || status == 'transcribing';

/// Human label for a recording's processing status.
String statusLabel(String status) => switch (status) {
      'uploaded' || 'transcribing' => 'AI is transcribing…',
      'indexed' => 'Ready',
      'failed' => 'Processing failed',
      _ => status,
    };
