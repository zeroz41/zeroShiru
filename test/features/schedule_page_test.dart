import 'package:flutter_test/flutter_test.dart';
import 'package:zero/features/schedule/schedule_page.dart';

void main() {
  group('formatAiringCountdown', () {
    final now = DateTime.utc(2026, 8, 24, 12);

    test('formats days, hours, minutes, and imminent airings', () {
      expect(
        formatAiringCountdown(
          now.add(const Duration(days: 2, hours: 3, minutes: 4)),
          now,
        ),
        '2d 3h',
      );
      expect(
        formatAiringCountdown(
          now.add(const Duration(hours: 8, minutes: 2)),
          now,
        ),
        '8h 2m',
      );
      expect(
        formatAiringCountdown(now.add(const Duration(minutes: 42)), now),
        '42m',
      );
      expect(
        formatAiringCountdown(now.add(const Duration(seconds: 30)), now),
        '<1m',
      );
    });

    test('does not show a negative countdown', () {
      expect(formatAiringCountdown(now, now), 'Airing now');
      expect(
        formatAiringCountdown(now.subtract(const Duration(days: 1)), now),
        'Airing now',
      );
    });
  });
}
