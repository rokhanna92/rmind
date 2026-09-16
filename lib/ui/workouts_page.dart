import 'dart:async';

import 'package:flutter/material.dart';

import '../models/workout_session.dart';
import 'design.dart';
import 'format.dart';

/// Full month names, used only by the history group headers. format.dart keeps
/// the short forms for row dates, and a header reading "Sep" beside a row
/// reading "Mon 14 Sep" would look like a mistake rather than a heading.
const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Monday first, matching the week strip.
const List<String> _dayInitials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

/// A workout length in words, e.g. "45 min", "1 h 12 min", "3 h 05 min".
///
/// Minutes are padded once there is an hour so durations stack in a column,
/// which is the same reason the whole app uses tabular figures.
String _formatSpan(Duration d) {
  final minutes = d.inMinutes < 0 ? 0 : d.inMinutes;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  return '$h h ${two(m)} min';
}

/// The running clock, "12:34" under an hour and "1:12:34" past it.
String _formatClock(Duration d) {
  final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Rows arrive from the database, so the same session can be a different
/// object on either side of a reload. Identity alone would then show the live
/// session twice, once in the card and once in the history.
bool _sameSession(WorkoutSession a, WorkoutSession b) =>
    identical(a, b) || (a.id != null && a.id == b.id);

/// The Workouts tab: the live session, this week at a glance, then history.
///
/// The scaffold, mic bar and bottom nav come from the host page, this renders
/// the body only. [now] is passed in rather than read here so the caller owns
/// the clock and tests can pin it, with one exception: the running card ticks
/// itself, because a clock that only moves when its parent rebuilds is not a
/// clock.
class WorkoutsPage extends StatelessWidget {
  const WorkoutsPage({
    super.key,
    required this.sessions,
    required this.running,
    required this.now,
    required this.onEnd,
    required this.onTapSession,
    required this.onDeleteSession,
  });

  /// Newest first.
  final List<WorkoutSession> sessions;

  /// The live session, or null when none is running.
  final WorkoutSession? running;

  final DateTime now;
  final VoidCallback onEnd;
  final void Function(WorkoutSession) onTapSession;

  /// Swiping a history row away. The running card is deliberately not
  /// dismissible: ending a session is a different act from deleting it, and a
  /// stray swipe must not destroy a workout in progress.
  final Future<void> Function(WorkoutSession) onDeleteSession;

  @override
  Widget build(BuildContext context) {
    final running = this.running;
    if (sessions.isEmpty && running == null) return const _EmptyState();

    // The live session has its own card, so it is dropped from the history
    // whether or not the caller also listed it. A stale one stays: the caller
    // has stopped treating it as running, and it is history the user still
    // needs to see and fix.
    final history = running == null
        ? sessions
        : sessions.where((s) => !_sameSession(s, running)).toList();
    final week = _Week.of(sessions: sessions, running: running, now: now);

    final rows = <Widget>[];
    if (running != null) {
      rows.add(const SizedBox(height: 10));
      rows.add(_RunningCard(session: running, now: now, onEnd: onEnd));
    }
    rows.add(_WeekHeader(total: week.total));
    rows.add(_WeekStrip(week: week, today: now.weekday - 1));

    // Insertion order is the display order: the list is newest first, so the
    // groups come out newest first too.
    final groups = <String, List<WorkoutSession>>{};
    for (final session in history) {
      final label = _groupLabel(session.startedAt, now, week.start);
      groups.putIfAbsent(label, () => <WorkoutSession>[]).add(session);
    }
    for (final entry in groups.entries) {
      rows.add(_GroupHeader(label: entry.key, count: entry.value.length));
      for (var i = 0; i < entry.value.length; i++) {
        if (i > 0) rows.add(const SizedBox(height: 6));
        final session = entry.value[i];
        rows.add(
          _SessionRow(
            session: session,
            now: now,
            onTap: () => onTapSession(session),
            onDelete: () => onDeleteSession(session),
          ),
        );
      }
    }

    return ListView(
      // The bottom pad clears the mic bar so the last row is never trapped
      // under it.
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 120),
      children: rows,
    );
  }

  /// "This week", "Last week", then the month, with the year added once it
  /// stops being obvious so two Septembers cannot merge into one group.
  static String _groupLabel(DateTime when, DateTime now, DateTime weekStart) {
    if (!when.isBefore(weekStart)) return 'This week';
    final lastWeek = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day - 7,
    );
    if (!when.isBefore(lastWeek)) return 'Last week';
    final month = _monthNames[when.month - 1];
    return when.year == now.year ? month : '$month ${when.year}';
  }
}

/// This week's totals, one bucket per day, Monday first.
class _Week {
  const _Week({
    required this.start,
    required this.days,
    required this.runningDay,
  });

  factory _Week.of({
    required List<WorkoutSession> sessions,
    required WorkoutSession? running,
    required DateTime now,
  }) {
    // Built by calendar arithmetic rather than by subtracting a Duration, so
    // the week still starts at local midnight across a daylight saving change.
    final start = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final days = List<Duration>.filled(7, Duration.zero);
    int? runningDay;

    void add(WorkoutSession session, {required bool live}) {
      final index = daysBetween(start, session.startedAt);
      if (index < 0 || index > 6) return;
      // An open session the caller no longer calls live is one the app has
      // given up on, and nobody knows when it ended. Counting it up to now
      // would charge the week every hour since, so it is left out of the bars
      // and the total, the same refusal the history row makes.
      if (session.isRunning && !live) return;
      // A session counts on the day it started, which is also how it is
      // grouped below, so the strip and the history never disagree.
      days[index] += session.elapsed(now);
      if (live) runningDay = index;
    }

    for (final session in sessions) {
      add(session, live: running != null && _sameSession(session, running));
    }
    // Time already spent is time spent, so the live session is in the bars and
    // the total. Skipped when the caller also listed it, to avoid double
    // counting.
    if (running != null && !sessions.any((s) => _sameSession(s, running))) {
      add(running, live: true);
    }
    return _Week(start: start, days: days, runningDay: runningDay);
  }

  /// Local midnight on Monday.
  final DateTime start;

  /// Seven buckets, Monday first.
  final List<Duration> days;

  /// The bucket holding the live session, or null when none is running.
  final int? runningDay;

  Duration get total => days.fold(Duration.zero, (sum, d) => sum + d);

  Duration get longest => days.reduce((a, b) => a > b ? a : b);
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({required this.total});

  final Duration total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('This week', style: RM.dayLabel),
          Text(_formatSpan(total), softWrap: false, style: RM.rowMeta),
        ],
      ),
    );
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.week, required this.today});

  final _Week week;

  /// Index into [_Week.days], not a weekday number.
  final int today;

  @override
  Widget build(BuildContext context) {
    final longest = week.longest;
    final columns = <Widget>[];
    for (var i = 0; i < 7; i++) {
      if (i > 0) columns.add(const SizedBox(width: 6));
      columns.add(
        Expanded(
          child: _DayColumn(
            value: week.days[i],
            longest: longest,
            initial: _dayInitials[i],
            isToday: i == today,
            isRunning: i == week.runningDay,
          ),
        ),
      );
    }
    return SizedBox(
      height: 82,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: columns),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.value,
    required this.longest,
    required this.initial,
    required this.isToday,
    required this.isRunning,
  });

  final Duration value;
  final Duration longest;
  final String initial;
  final bool isToday;
  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    final empty = value <= Duration.zero;
    // An empty day is a stub rather than nothing, so the week still reads as
    // seven days and a rest day is visibly a rest day. Anything trained gets a
    // floor of 12 so a short session is never mistaken for one of those.
    final height = empty
        ? 4.0
        : (12 + 36 * (value.inSeconds / longest.inSeconds))
            .clamp(12, 48)
            .toDouble();

    final Color color;
    if (empty) {
      color = RM.field;
    } else if (isRunning) {
      // Still growing, so it is drawn unfinished. A solid bar would claim a
      // number the day has not earned yet.
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
          initial,
          textAlign: TextAlign.center,
          style: isToday
              ? RM.label.copyWith(
                  fontWeight: FontWeight.w800,
                  color: RM.accentBright,
                  letterSpacing: 0,
                )
              : RM.label.copyWith(letterSpacing: 0),
        ),
      ],
    );
  }
}

class _RunningCard extends StatefulWidget {
  const _RunningCard({
    required this.session,
    required this.now,
    required this.onEnd,
  });

  final WorkoutSession session;
  final DateTime now;
  final VoidCallback onEnd;

  @override
  State<_RunningCard> createState() => _RunningCardState();
}

class _RunningCardState extends State<_RunningCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
    lowerBound: 0.3,
    upperBound: 1,
    value: 1,
  );
  Timer? _tick;

  /// The clock runs forward from the caller's [WorkoutsPage.now] instead of
  /// reading DateTime.now() on every tick. A pinned now therefore stays the
  /// card's own zero, and the card can never disagree with the week strip
  /// beside it about what time it is.
  final Stopwatch _since = Stopwatch()..start();

  DateTime get _now => widget.now.add(_since.elapsed);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _RunningCard old) {
    super.didUpdateWidget(old);
    if (widget.now != old.now) _since.reset();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A live dot is decoration, so it stops entirely when the platform asks
    // for reduced motion rather than slowing down.
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: RM.session,
        borderRadius: BorderRadius.circular(RM.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FadeTransition(
                opacity: _pulse,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: RM.accentLight,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'RUNNING',
                style: RM.label.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: RM.accentLight,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Two lines, because the clock beside it claims its width
                    // first and a common name like "Bicep and shoulder" does
                    // not survive one line on a 360dp phone. The name is what
                    // identifies the session, so it wraps rather than clips.
                    Text(
                      session.type,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: RM.fieldValue.copyWith(color: RM.accentBright),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Started ${formatTime(session.startedAt)}',
                      softWrap: false,
                      style: RM.rowMeta.copyWith(
                        fontSize: 13,
                        color: RM.accentLight,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 40px digits are the widest thing on this screen, so the clock
              // is allowed to shrink rather than push the row off a 360dp
              // phone once it reaches hours or the user scales text up.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatClock(session.elapsed(_now)),
                    softWrap: false,
                    style: RM.timer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _EndButton(onEnd: widget.onEnd),
        ],
      ),
    );
  }
}

class _EndButton extends StatelessWidget {
  const _EndButton({required this.onEnd});

  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RM.accentLight.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEnd,
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.stop_circle, size: 20, color: RM.accentBright),
              const SizedBox(width: 8),
              Text(
                'End session',
                style: RM.dayLabel.copyWith(
                  fontSize: 14,
                  color: RM.accentBright,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label, style: RM.dayLabel),
          const SizedBox(width: 8),
          Text(
            count == 1 ? '1 session' : '$count sessions',
            style: RM.dayDate,
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.now,
    required this.onTap,
    required this.onDelete,
  });

  final WorkoutSession session;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // A session still running down here is one the app has given up on, and it
    // is called out. Nobody knows when it ended, so neither the length nor the
    // end time is rendered: a plausible looking number would be a lie the user
    // cannot spot.
    final stale = session.isStale(now);
    final duration = session.duration;
    final radius = BorderRadius.circular(RM.rRow);

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: RM.field, borderRadius: radius),
        child: const Icon(Icons.delete_outline, color: RM.alarm),
      ),
      onDismissed: (_) => onDelete(),
      child: Material(
        color: RM.surface,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        duration == null ? '-' : _formatSpan(duration),
                        softWrap: false,
                        style: stale
                            ? RM.rowTime.copyWith(color: RM.alarm)
                            : RM.rowTime,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        session.type,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RM.rowTitle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatDate(session.startedAt),
                      softWrap: false,
                      style: RM.rowMeta.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: RM.inkMid,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _Span(session: session, stale: stale),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "18:05 - 19:17", or "18:05 - -" when the end time was never recorded. The
/// separator is a plain hyphen on purpose.
class _Span extends StatelessWidget {
  const _Span({required this.session, required this.stale});

  final WorkoutSession session;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final start = '${formatTime(session.startedAt)} - ';
    if (!stale) {
      final ended = session.endedAt;
      return Text(
        '$start${ended == null ? '-' : formatTime(ended)}',
        softWrap: false,
        style: RM.rowMeta,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: start),
          TextSpan(
            text: '-',
            style: RM.rowMeta.copyWith(
              color: RM.alarm,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      softWrap: false,
      style: RM.rowMeta,
    );
  }
}

/// The Workouts tab before there is anything to show.
///
/// Teaches the two phrases the feature listens for rather than inventing data
/// to fill the screen.
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.fitness_center, size: 56, color: RM.line),
                const SizedBox(height: 28),
                Column(
                  children: [
                    Text(
                      'No sessions yet',
                      textAlign: TextAlign.center,
                      style: RM.sheetTitle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Same mic as reminders. Just tell it where you are.',
                      textAlign: TextAlign.center,
                      style: RM.body,
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ExampleCard(
                      label: 'TO START',
                      phrase: '“I’m at the gym, today is leg day”',
                    ),
                    SizedBox(height: 10),
                    _ExampleCard(
                      label: 'TO END',
                      phrase: '“Ok, done with the workout”',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExampleCard extends StatelessWidget {
  const _ExampleCard({required this.label, required this.phrase});

  final String label;
  final String phrase;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: RM.surface,
        borderRadius: BorderRadius.circular(RM.rRow),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: RM.label.copyWith(
              fontWeight: FontWeight.w700,
              color: RM.accentLight,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(phrase, style: RM.rowTitle),
        ],
      ),
    );
  }
}
