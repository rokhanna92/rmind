import 'package:flutter/material.dart';

import '../models/task.dart';
import '../models/workout_session.dart';
import 'design.dart';
import 'format.dart';

/// Monday first, matching every other week view in the app. format.dart keeps
/// its own copy private, and a row here reads "Wednesday" rather than "Wed",
/// so the two lists are not the same list.
const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// How far the rhythm chart looks back, in weeks, the current one included.
const int _weeksBack = 8;

/// Completed weeks of history needed before an average is called an average.
const int _minWeeksForAverage = 2;

/// Sessions needed before the weekday breakdown means anything. Under this a
/// single Tuesday reads as "you always train on Tuesday".
const int _minSessionsForWeekdays = 5;

/// Reminders needed before a completion rate is a rate. One missed reminder
/// out of two is not 50% of anything.
const int _minRemindersForRate = 5;

/// What a session contributes to a time total.
///
/// A running session the app has given up on has no known length, so it counts
/// as a session but adds no time. Charging the week every hour since it was
/// abandoned would invent a number nobody earned. The negative guard is for
/// rows that came back with an end before their start.
Duration _countedTime(WorkoutSession session, DateTime now) {
  if (session.isRunning && session.isStale(now)) return Duration.zero;
  final elapsed = session.elapsed(now);
  return elapsed.isNegative ? Duration.zero : elapsed;
}

/// The Insights tab: everything the app can already work out about itself.
///
/// Derived only, it stores nothing and asks for nothing. The scaffold, mic bar
/// and bottom nav come from the host page, this renders the body only, and
/// [now] is passed in so the caller owns the clock.
///
/// Thin data is the interesting case, so the page refuses to print a figure it
/// has not earned. The thresholds: an average needs [_minWeeksForAverage]
/// completed weeks since the first session, the weekday breakdown needs
/// [_minSessionsForWeekdays] sessions, and a completion rate needs
/// [_minRemindersForRate] reminders that are already due. Below those it says
/// so instead. Plain counts have no threshold, because a count of two is
/// simply two.
class InsightsPage extends StatelessWidget {
  const InsightsPage({
    super.key,
    required this.tasks,
    required this.sessions,
    required this.noteCount,
    required this.now,
  });

  /// All of them, done and pending alike.
  final List<Task> tasks;

  /// Newest first.
  final List<WorkoutSession> sessions;

  final int noteCount;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    // Notes alone do not make a page: none of the four sections can say
    // anything about them beyond the count.
    if (sessions.isEmpty && tasks.isEmpty) return const _EmptyState();

    final data = _Insights.of(
      tasks: tasks,
      sessions: sessions,
      noteCount: noteCount,
      now: now,
    );

    return ListView(
      // The bottom pad clears the mic bar so the last card is never trapped
      // under it.
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 120),
      children: [
        const _SectionHeader(label: 'At a glance', first: true),
        _Tiles(data: data),
        const _SectionHeader(label: 'Training rhythm', subtitle: 'Last 8 weeks'),
        _Rhythm(data: data),
        const _SectionHeader(label: 'When you train', subtitle: 'All history'),
        _Weekdays(data: data),
        const _SectionHeader(label: 'Reminders', subtitle: 'All time'),
        _Reminders(data: data),
      ],
    );
  }
}

/// Every number on the page, worked out once.
class _Insights {
  const _Insights({
    required this.weekSessions,
    required this.weekTime,
    required this.weekDone,
    required this.upcoming,
    required this.noteCount,
    required this.weeks,
    required this.weekDays,
    required this.windowSessions,
    required this.average,
    required this.longestGap,
    required this.weekdays,
    required this.totalSessions,
    required this.remindersDue,
    required this.remindersDone,
    required this.remindersMissed,
  });

  factory _Insights.of({
    required List<Task> tasks,
    required List<WorkoutSession> sessions,
    required int noteCount,
    required DateTime now,
  }) {
    // Built by calendar arithmetic rather than by subtracting a Duration, so
    // the week still starts at local midnight across a daylight saving change.
    final weekStart = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final windowStart = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day - 7 * (_weeksBack - 1),
    );

    final weeks = List<int>.filled(_weeksBack, 0);
    final weekdays = List<int>.filled(7, 0);

    // Day offsets from [windowStart] rather than instants: gaps are then plain
    // integer subtraction and cannot be bent by a clock change.
    final offsets = <int>[];

    var weekSessions = 0;
    var weekTime = Duration.zero;

    for (final session in sessions) {
      // A session counts on the day it started, the same rule the workouts
      // history groups by, so the two screens never disagree.
      weekdays[session.startedAt.weekday - 1]++;

      final offset = daysBetween(windowStart, session.startedAt);
      if (offset >= 0 && offset < 7 * _weeksBack) {
        weeks[offset ~/ 7]++;
        offsets.add(offset);
      }

      final inWeek = daysBetween(weekStart, session.startedAt);
      if (inWeek >= 0 && inWeek < 7) {
        weekSessions++;
        weekTime += _countedTime(session, now);
      }
    }

    // The caller says newest first, but a gap is wrong rather than merely ugly
    // if that ever slips, so the order is established here.
    offsets.sort();
    int? longestGap;
    for (var i = 1; i < offsets.length; i++) {
      final gap = offsets[i] - offsets[i - 1];
      if (longestGap == null || gap > longestGap) longestGap = gap;
    }
    // The stretch since the last session is a gap the user is still living in,
    // and it is usually the one that matters. Counting only the gaps between
    // sessions lets the card read "Longest gap: 1 day" to someone who trained
    // three days running and then stopped seven weeks ago.
    if (offsets.isNotEmpty) {
      final since = daysBetween(windowStart, now) - offsets.last;
      if (longestGap == null || since > longestGap) longestGap = since;
    }

    // The current week is still being written, so it is left out of the
    // average: dividing by a week that is two days old drags it down for no
    // reason. History starts at the first week that actually has a session,
    // otherwise a user three weeks in is averaged over eight.
    const completed = _weeksBack - 1;
    var firstWeek = -1;
    for (var i = 0; i < completed; i++) {
      if (weeks[i] > 0) {
        firstWeek = i;
        break;
      }
    }
    double? average;
    if (firstWeek >= 0 && completed - firstWeek >= _minWeeksForAverage) {
      var total = 0;
      for (var i = firstWeek; i < completed; i++) {
        total += weeks[i];
      }
      average = total / (completed - firstWeek);
    }

    var weekDone = 0;
    var upcoming = 0;
    var remindersDue = 0;
    var remindersDone = 0;
    for (final task in tasks) {
      // There is no completion timestamp on a task, so "completed this week"
      // can only mean due this week and done. Said plainly on the tile.
      final inWeek = daysBetween(weekStart, task.dueAt);
      if (task.isDone && inWeek >= 0 && inWeek < 7) weekDone++;
      // What is actually waiting, which is the only figure on this page that
      // says anything on the day the app is installed. Everything else here
      // reports on the past, so without this a user with real reminders sees
      // nothing but zeroes and reasonably concludes the page is broken.
      if (task.isPending(now)) upcoming++;

      if (task.dueAt.isAfter(now)) continue;
      remindersDue++;
      if (task.isDone) remindersDone++;
    }

    final days = <int>[];
    for (var i = 0; i < _weeksBack; i++) {
      days.add(
        DateTime(
          windowStart.year,
          windowStart.month,
          windowStart.day + 7 * i,
        ).day,
      );
    }

    return _Insights(
      weekSessions: weekSessions,
      weekTime: weekTime,
      weekDone: weekDone,
      upcoming: upcoming,
      noteCount: noteCount,
      weeks: weeks,
      weekDays: days,
      windowSessions: offsets.length,
      average: average,
      longestGap: longestGap,
      weekdays: weekdays,
      totalSessions: sessions.length,
      remindersDue: remindersDue,
      remindersDone: remindersDone,
      remindersMissed: remindersDue - remindersDone,
    );
  }

  final int weekSessions;
  final Duration weekTime;
  final int weekDone;

  /// Reminders still waiting to fire.
  final int upcoming;
  final int noteCount;

  /// Sessions per week, oldest first, the last entry being the current week.
  final List<int> weeks;

  /// The day of the month each of those weeks starts on.
  final List<int> weekDays;

  final int windowSessions;

  /// Sessions per completed week since the first one, or null when there is
  /// not enough history to call it an average.
  final double? average;

  /// The longest run of days without a session inside the window, counting the
  /// run still open since the last one, or null when the window is empty.
  final int? longestGap;

  /// Sessions per weekday over all history, Monday first.
  final List<int> weekdays;

  final int totalSessions;

  /// Reminders whose due time has passed.
  final int remindersDue;
  final int remindersDone;
  final int remindersMissed;

  int get busiestWeek => weeks.reduce((a, b) => a > b ? a : b);

  int get busiestWeekday => weekdays.reduce((a, b) => a > b ? a : b);
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    this.subtitle,
    this.first = false,
  });

  final String label;
  final String? subtitle;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Padding(
      padding: EdgeInsets.fromLTRB(8, first ? 10 : 20, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          // Both flexible: a long label beside a long subtitle is wider than a
          // 360dp phone once the user scales text up, and a header is worth
          // clipping rather than overflowing.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RM.dayLabel,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RM.dayDate,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RM.surface,
        borderRadius: BorderRadius.circular(RM.rCard),
      ),
      child: child,
    );
  }
}

/// The line shown where a number would mislead.
class _Honest extends StatelessWidget {
  const _Honest(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: RM.body.copyWith(color: RM.inkSoft));
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.data});

  final _Insights data;

  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _Tile(
        value: '${data.upcoming}',
        label: data.upcoming == 1 ? 'reminder upcoming' : 'reminders upcoming',
      ),
      _Tile(
        value: '${data.weekSessions}',
        label: data.weekSessions == 1 ? 'session this week' : 'sessions this week',
      ),
      _Tile(value: formatDuration(data.weekTime), label: 'time this week'),
      // "Due this week and done" is the honest reading: a task carries no
      // completion time, so the tile says due rather than implying one.
      _Tile(value: '${data.weekDone}', label: 'reminders done, due this week'),
      _Tile(
        value: '${data.noteCount}',
        label: data.noteCount == 1 ? 'note kept' : 'notes kept',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Four across only where there is room for four. A 360dp phone gets
        // two, which is why this is rows of tiles rather than one Row.
        final columns = constraints.maxWidth >= 520 ? 4 : 2;
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += columns) {
          if (rows.isNotEmpty) rows.add(const SizedBox(height: _gap));
          final cells = <Widget>[];
          for (var c = 0; c < columns; c++) {
            if (c > 0) cells.add(const SizedBox(width: _gap));
            final index = i + c;
            cells.add(
              Expanded(
                child: index < tiles.length ? tiles[index] : const SizedBox(),
              ),
            );
          }
          // Labels run to one or two lines depending on the phone and the
          // user's text size, and tiles of different heights in the same row
          // read as a mistake, so the row squares them off.
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: cells,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RM.surface,
        borderRadius: BorderRadius.circular(RM.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // "1 h 12 min" is a far wider value than "3", so it shrinks rather
          // than overflowing a half width tile.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              softWrap: false,
              style: RM.rowTime.copyWith(fontSize: 26),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, style: RM.rowMeta),
        ],
      ),
    );
  }
}

class _Rhythm extends StatelessWidget {
  const _Rhythm({required this.data});

  final _Insights data;

  @override
  Widget build(BuildContext context) {
    if (data.windowSessions == 0) {
      return const _Card(child: _Honest('No sessions in the last 8 weeks.'));
    }

    final average = data.average;
    final gap = data.longestGap;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Fact(
                    label: 'Sessions a week',
                    value: average?.toStringAsFixed(1),
                    missing: 'Not enough history yet',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Fact(
                    label: 'Longest gap',
                    value: gap == null
                        ? null
                        : (gap == 1 ? '1 day' : '$gap days'),
                    missing: 'Needs a session',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _WeekBars(data: data),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, required this.missing});

  final String label;

  /// Null when the figure would mislead, which shows [missing] instead.
  final String? value;
  final String missing;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: RM.rowMeta),
        const SizedBox(height: 4),
        if (value == null)
          _Honest(missing)
        else
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, softWrap: false, style: RM.fieldValue),
          ),
      ],
    );
  }
}

class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.data});

  final _Insights data;

  @override
  Widget build(BuildContext context) {
    final tallest = data.busiestWeek;
    final columns = <Widget>[];
    for (var i = 0; i < _weeksBack; i++) {
      if (i > 0) columns.add(const SizedBox(width: 6));
      columns.add(
        Expanded(
          child: _WeekBar(
            count: data.weeks[i],
            tallest: tallest,
            day: data.weekDays[i],
            // The last bucket is the week the user is still in.
            current: i == _weeksBack - 1,
          ),
        ),
      );
    }
    // No fixed height: the row takes the tallest column, so the day labels
    // still line up when the user scales text right up.
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: columns);
  }
}

class _WeekBar extends StatelessWidget {
  const _WeekBar({
    required this.count,
    required this.tallest,
    required this.day,
    required this.current,
  });

  final int count;
  final int tallest;
  final int day;
  final bool current;

  @override
  Widget build(BuildContext context) {
    // A week with nothing in it is a stub rather than nothing, so eight weeks
    // still read as eight and a blank week is visibly blank. Anything trained
    // gets a floor of 12 so one session is never mistaken for none.
    final height = count == 0
        ? 4.0
        : (12 + 36 * (count / tallest)).clamp(12, 48).toDouble();

    final Color color;
    if (count == 0) {
      color = RM.field;
    } else if (current) {
      // Still being added to, so it is drawn unfinished. A solid bar would
      // claim a number the week has not finished earning.
      color = RM.accentLight.withValues(alpha: 0.45);
    } else {
      color = RM.accentLight;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$day',
          textAlign: TextAlign.center,
          softWrap: false,
          style: current
              ? RM.rowMeta.copyWith(
                  fontWeight: FontWeight.w800,
                  color: RM.accentBright,
                )
              : RM.rowMeta,
        ),
      ],
    );
  }
}

class _Weekdays extends StatelessWidget {
  const _Weekdays({required this.data});

  final _Insights data;

  @override
  Widget build(BuildContext context) {
    if (data.totalSessions < _minSessionsForWeekdays) {
      return const _Card(
        child: _Honest(
          'Not enough sessions yet to show which days you train.',
        ),
      );
    }

    final busiest = data.busiestWeekday;
    final rows = <Widget>[];
    for (var i = 0; i < 7; i++) {
      if (i > 0) rows.add(const SizedBox(height: 10));
      rows.add(
        _WeekdayRow(
          name: _weekdayNames[i],
          count: data.weekdays[i],
          busiest: busiest,
        ),
      );
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow({
    required this.name,
    required this.count,
    required this.busiest,
  });

  final String name;
  final int count;
  final int busiest;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RM.rowTitle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: _Bar(fraction: count / busiest, height: 10)),
        const SizedBox(width: 10),
        SizedBox(
          width: 26,
          child: Text(
            '$count',
            textAlign: TextAlign.right,
            softWrap: false,
            style: count == 0 ? RM.rowMeta : RM.rowMeta.copyWith(color: RM.ink),
          ),
        ),
      ],
    );
  }
}

/// A track in [RM.field] with an [RM.accentLight] fill. [fraction] is clamped,
/// so a caller can hand it anything without tearing the layout.
class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.height});

  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    final filled = fraction.clamp(0.0, 1.0);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: RM.field,
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: filled == 0
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: filled,
                child: Container(
                  decoration: BoxDecoration(
                    color: RM.accentLight,
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                ),
              ),
            ),
    );
  }
}

class _Reminders extends StatelessWidget {
  const _Reminders({required this.data});

  final _Insights data;

  @override
  Widget build(BuildContext context) {
    if (data.remindersDue == 0) {
      return const _Card(
        child: _Honest('Nothing has come due yet, so there is nothing to score.'),
      );
    }

    final due = data.remindersDue;
    final done = data.remindersDone;
    // Rounded down and held at 99 until every one is done, so a single missed
    // reminder can never be rounded away into a perfect score.
    final percent = done == due ? 100 : (100 * done / due).floor().clamp(0, 99);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (due < _minRemindersForRate)
            const _Honest('Not enough reminders yet to call it a rate.')
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: Text('Completed', style: RM.rowTitle)),
                const SizedBox(width: 10),
                Text('$percent%', softWrap: false, style: RM.fieldValue),
              ],
            ),
            const SizedBox(height: 10),
            _Bar(fraction: done / due, height: 8),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text('$done completed', style: RM.rowMeta),
              ),
              const SizedBox(width: 10),
              Text(
                '${data.remindersMissed} missed',
                softWrap: false,
                style: RM.rowMeta,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The Insights tab before there is anything to derive.
///
/// No skeleton charts full of zeroes: an empty chart is a claim that the user
/// trained nothing, which is not the same as the app knowing nothing.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    // The mic bar floats over the bottom of this area, and the body shrinks
    // again whenever the header carries the parse error banner, so the content
    // scrolls and reserves room for the bar rather than overflowing.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(36, 24, 36, 120),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - 144).clamp(0, double.infinity),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.insights, size: 56, color: RM.line),
                const SizedBox(height: 28),
                Text(
                  'Nothing to show yet',
                  textAlign: TextAlign.center,
                  style: RM.sheetTitle,
                ),
                const SizedBox(height: 8),
                Text(
                  'Insights appear once there is a week or two of history '
                  'behind them.',
                  textAlign: TextAlign.center,
                  style: RM.body,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
