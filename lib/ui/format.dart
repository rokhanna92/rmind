/// Small date and time formatting helpers.
///
/// Deliberately hand rolled rather than pulling in intl. The app only ever
/// renders 24 hour clock times and short English day labels, which is not
/// worth a dependency and a locale database.
library;

const List<String> _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String two(int n) => n.toString().padLeft(2, '0');

/// 24 hour clock, e.g. "09:05".
String formatTime(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

/// "Wed 16 Sep".
String formatDate(DateTime d) =>
    '${_weekdays[d.weekday - 1].substring(0, 3)} ${d.day} ${_months[d.month - 1]}';

/// Calendar days between two instants, ignoring the time of day. Comparing
/// dates rather than subtracting durations avoids daylight saving errors,
/// where "tomorrow" can be 23 or 25 hours away.
int daysBetween(DateTime from, DateTime to) {
  final a = DateTime(from.year, from.month, from.day);
  final b = DateTime(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// A human day label relative to [now]: "Today", "Tomorrow", "Yesterday",
/// a weekday name within the coming week, otherwise a short date.
String relativeDayLabel(DateTime when, DateTime now) {
  final diff = daysBetween(now, when);
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _weekdays[when.weekday - 1];
  return formatDate(when);
}

/// "Today at 15:00", used in list rows and the confirm sheet.
String formatWhen(DateTime when, DateTime now) =>
    '${relativeDayLabel(when, now)} at ${formatTime(when)}';

/// An elapsed workout length: "47 min", "1 h 12 min", "2 h".
///
/// Rounds down to the minute. A session is measured in minutes, so showing
/// seconds here would imply a precision the input never had.
String formatDuration(Duration d) {
  final total = d.inMinutes;
  if (total < 60) return '$total min';
  final h = total ~/ 60;
  final m = total % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// Renders a reminder lead time compactly: "30 min before", "1 h before",
/// "1 h 30 min before", "at the time".
String formatLead(int minutes) {
  if (minutes <= 0) return 'at the time';
  if (minutes < 60) return '$minutes min before';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return '$h h before';
  return '$h h $m min before';
}
