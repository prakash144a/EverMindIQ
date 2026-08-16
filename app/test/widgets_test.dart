import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voiceiq/src/core/theme.dart';
import 'package:voiceiq/src/data/models.dart';
import 'package:voiceiq/src/widgets/hero_action_button.dart';
import 'package:voiceiq/src/widgets/formatting.dart';

void main() {
  testWidgets('HeroActionButton renders its label and fires onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: HeroActionButton(
                  icon: const Icon(Icons.mic),
                  label: 'Record',
                  onTap: () => tapped = true,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Record'), findsOneWidget);
    await tester.tap(find.text('Record'));
    expect(tapped, isTrue);
  });

  test('prettyDate formats and tolerates bad input', () {
    expect(prettyDate('2025-08-15'), contains('2025'));
    expect(prettyDate('not-a-date'), 'not-a-date');
  });

  test('relativeTime reads like a social feed', () {
    DateTime ago(Duration d) => DateTime.now().subtract(d);
    expect(relativeTime(ago(const Duration(seconds: 5))), 'just now');
    expect(relativeTime(ago(const Duration(seconds: 59))), 'just now');
    expect(relativeTime(ago(const Duration(minutes: 5))), '5m ago');
    expect(relativeTime(ago(const Duration(minutes: 90))), '1h ago');
    expect(relativeTime(ago(const Duration(days: 2))), '2d ago');
    expect(relativeTime(ago(const Duration(days: 8))), '1wk ago');
    expect(relativeTime(ago(const Duration(days: 60))), '2mo ago');
    expect(relativeTime(ago(const Duration(days: 800))), '2y ago');
    // Clock skew must not produce "in the future" labels.
    expect(relativeTime(DateTime.now().add(const Duration(minutes: 5))), 'just now');
  });

  test('processing statuses share one in-progress label', () {
    expect(isProcessing('uploaded'), isTrue);
    expect(isProcessing('transcribing'), isTrue);
    expect(isProcessing('indexed'), isFalse);
    expect(isProcessing('failed'), isFalse);
    expect(statusLabel('uploaded'), 'AI is transcribing…');
    expect(statusLabel('transcribing'), 'AI is transcribing…');
    expect(statusLabel('failed'), 'Processing failed');
  });

  test('Recording.fromJson prefers recorded_at for the age label', () {
    final withTs = Recording.fromJson({
      'id': 'a',
      'event_date': '2025-08-15',
      'recorded_at': '2025-08-15T10:30:00Z',
      'status': 'indexed',
    });
    expect(withTs.recordedAt.toUtc().hour, 10);

    // Older payloads without recorded_at still parse, falling back to the date.
    final withoutTs = Recording.fromJson({
      'id': 'b',
      'event_date': '2025-08-15',
      'status': 'uploaded',
    });
    expect(withoutTs.recordedAt.year, 2025);
  });
}
