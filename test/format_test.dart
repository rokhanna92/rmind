import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/ui/format.dart';

void main() {
  group('formatTime', () {
    test('pads to a 24 hour clock', () {
      expect(formatTime(DateTime(2026, 9, 16, 9, 5)), '09:05');
      expect(formatTime(DateTime(2026, 9, 16, 15, 0)), '15:00');
      expect(formatTime(DateTime(2026, 9, 16, 0, 0)), '00:00');
      expect(formatTime(DateTime(2026, 9, 16, 23, 59)), '23:59');
    });
  });

  group('daysBetween', () {
    test('counts calendar days, not elapsed hours', () {
      final lateTonight = DateTime(2026, 9, 16, 23, 30);
      final earlyTomorrow = DateTime(2026, 9, 17, 0, 30);
      // One hour apart, but a different day, which is what the label cares
      // about.
      expect(daysBetween(lateTonight, earlyTomorrow), 1);
    });

    test('is zero within the same day and negative going back', () {
      expect(
        daysBetween(DateTime(2026, 9, 16, 1), DateTime(2026, 9, 16, 22)),
        0,
      );
      expect(
        daysBetween(DateTime(2026, 9, 16), DateTime(2026, 9, 15)),
        -1,
      );
    });

    test('survives a month boundary', () {
      expect(daysBetween(DateTime(2026, 9, 30), DateTime(2026, 10, 1)), 1);
    });
  });

  group('relativeDayLabel', () {
    final now = DateTime(2026, 9, 16, 12, 0); // a Wednesday

    test('names today, tomorrow and yesterday', () {
      expect(relativeDayLabel(DateTime(2026, 9, 16, 18), now), 'Today');
      expect(relativeDayLabel(DateTime(2026, 9, 17, 6), now), 'Tomorrow');
      expect(relativeDayLabel(DateTime(2026, 9, 15, 6), now), 'Yesterday');
    });

    test('uses the weekday name inside the coming week', () {
      // Sep 18 2026 is a Friday.
      expect(relativeDayLabel(DateTime(2026, 9, 18), now), 'Friday');
      // Sep 21 2026 is the following Monday.
      expect(relativeDayLabel(DateTime(2026, 9, 21), now), 'Monday');
    });

    test('falls back to a short date beyond a week', () {
      expect(relativeDayLabel(DateTime(2026, 9, 30), now), 'Wed 30 Sep');
      expect(relativeDayLabel(DateTime(2026, 12, 25), now), 'Fri 25 Dec');
    });

    test('does not use a weekday name for past dates', () {
      // Two days ago must not read as "Monday", which would look upcoming.
      expect(relativeDayLabel(DateTime(2026, 9, 14), now), 'Mon 14 Sep');
    });
  });

  group('formatLead', () {
    test('renders minutes, hours and the zero case', () {
      expect(formatLead(0), 'at the time');
      expect(formatLead(-5), 'at the time');
      expect(formatLead(30), '30 min before');
      expect(formatLead(60), '1 h before');
      expect(formatLead(90), '1 h 30 min before');
      expect(formatLead(120), '2 h before');
      expect(formatLead(1440), '24 h before');
    });
  });

  group('formatWhen', () {
    test('combines the day label and the clock time', () {
      final now = DateTime(2026, 9, 16, 12, 0);
      expect(
        formatWhen(DateTime(2026, 9, 17, 15, 0), now),
        'Tomorrow at 15:00',
      );
    });
  });
}
