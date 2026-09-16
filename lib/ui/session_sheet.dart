import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/workout_session.dart';
import 'design.dart';
import 'format.dart';

/// What the user chose to do with the session.
sealed class SessionOutcome {
  const SessionOutcome();
}

/// End the session at [when], which is never before it started and never in
/// the future.
class EndSessionAt extends SessionOutcome {
  const EndSessionAt(this.when);

  final DateTime when;
}

/// Throw the session away instead of inventing an end for it.
class DiscardSession extends SessionOutcome {
  const DiscardSession();
}

/// Write [session] back as corrected: its type, its start and its end. Only a
/// finished session produces this, so its end time is never null.
class UpdateSession extends SessionOutcome {
  const UpdateSession(this.session);

  final WorkoutSession session;
}

/// Opens the sheet for a session and returns null if the user dismissed it
/// without choosing.
///
/// A running session gets the "you never ended this" question: the app could
/// close it silently at some plausible hour, but a wrong length recorded
/// without being asked is worse than a question, since the user is the only one
/// who knows when they left. [medianDuration] is null until there is history to
/// draw on, and the sheet then says so rather than inventing an average.
///
/// A finished session gets the editor instead, because the only thing left to
/// decide about it is whether it is right.
///
/// [now] is resolved once here so the suggestion cannot drift between the
/// sentence and the button, and so tests can pin it.
Future<SessionOutcome?> showSessionSheet(
  BuildContext context, {
  required WorkoutSession session,
  Duration? medianDuration,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return showModalBottomSheet<SessionOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: RM.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RM.rSheet)),
    ),
    builder: (context) => session.isRunning
        ? _SessionSheet(
            session: session,
            medianDuration: medianDuration,
            now: at,
          )
        : _EditSheet(session: session, now: at),
  );
}

/// The one confirmation both delete paths go through. Deleting a session cannot
/// be undone, so it costs one tap to be sure.
Future<bool> _confirmDiscard(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: RM.sheet,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RM.rCard),
      ),
      title: Text(
        'Discard this session?',
        style: RM.sheetTitle.copyWith(fontSize: 18),
      ),
      content: Text(
        'It will be deleted for good, and it will not count towards your '
        'history. There is no undo.',
        style: RM.body,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Keep it', style: RM.chip.copyWith(fontSize: 14)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            'Discard',
            style: RM.chip.copyWith(fontSize: 14, color: RM.alarm),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _SessionSheet extends StatelessWidget {
  const _SessionSheet({
    required this.session,
    required this.medianDuration,
    required this.now,
  });

  final WorkoutSession session;
  final Duration? medianDuration;
  final DateTime now;

  /// The suggested end: a typical session after the start, but never in the
  /// future, since a session cannot have ended after now. Null without history.
  DateTime? get _guess {
    final median = medianDuration;
    if (median == null) return null;
    final end = session.startedAt.add(median);
    final capped = end.isAfter(now) ? now : end;
    // A clock that has gone backwards, or a nonsense median, would otherwise
    // suggest an end before the start.
    return capped.isBefore(session.startedAt) ? session.startedAt : capped;
  }

  /// Places a picked time of day on the right calendar day. A session left open
  /// overnight usually ended the day after it started, so a time earlier on the
  /// clock than the start belongs to the next day, unless that day has not
  /// happened yet. Days are stepped by calendar date rather than by adding 24
  /// hours so a daylight saving change does not shift the result by an hour.
  DateTime _resolveDay(TimeOfDay picked) {
    final start = session.startedAt;
    final sameDay =
        DateTime(start.year, start.month, start.day, picked.hour, picked.minute);
    if (!sameDay.isBefore(start)) return sameDay;
    final nextDay = DateTime(
      start.year,
      start.month,
      start.day + 1,
      picked.hour,
      picked.minute,
    );
    return nextDay.isAfter(now) ? sameDay : nextDay;
  }

  Future<void> _pickAnotherTime(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_guess ?? session.startedAt),
      builder: (context, child) => Theme(data: RM.theme(), child: child!),
    );
    if (picked == null) return;

    final when = _resolveDay(picked);
    if (when.isBefore(session.startedAt)) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'That is before the session started at '
            '${formatTime(session.startedAt)}. Pick a later time.',
          ),
        ),
      );
      return;
    }
    // The same rule the suggestion follows: a session that has already ended
    // cannot have ended at a time that has not arrived yet. A pick later today
    // than the start lands here, e.g. 21:00 on a session started at 08:00.
    if (when.isAfter(now)) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'That has not happened yet. Pick a time up to '
            '${formatTime(now)}.',
          ),
        ),
      );
      return;
    }
    navigator.pop(EndSessionAt(when));
  }

  Future<void> _discard(BuildContext context) async {
    final navigator = Navigator.of(context);
    if (!await _confirmDiscard(context)) return;
    navigator.pop(const DiscardSession());
  }

  @override
  Widget build(BuildContext context) {
    final guess = _guess;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            const _GrabHandle(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(
                  formatDate(session.startedAt),
                  style: RM.label.copyWith(fontSize: 13, letterSpacing: 0),
                ),
                Text(session.type, style: RM.sheetTitle.copyWith(fontSize: 24)),
              ],
            ),
            // Intrinsic height so the hollow card matches the filled one even if
            // one of them ever wraps to a second line.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  Expanded(
                    child: _FactCard(
                      label: 'STARTED',
                      value: formatTime(session.startedAt),
                    ),
                  ),
                  Expanded(
                    child: _FactCard(
                      label: 'ENDED',
                      value: '-',
                      missing: true,
                    ),
                  ),
                ],
              ),
            ),
            _Explanation(median: medianDuration, guess: guess),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: [
                // Nothing to suggest without history, so nothing to press.
                if (guess != null)
                  _ActionButton(
                    height: 56,
                    fill: RM.accent,
                    onTap: () =>
                        Navigator.of(context).pop(EndSessionAt(guess)),
                    child: Text('End at ${formatTime(guess)}',
                        style: RM.button),
                  ),
                _ActionButton(
                  height: 52,
                  border: const BorderSide(color: RM.line, width: 1),
                  onTap: () => _pickAnotherTime(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [
                      const Icon(Icons.schedule, size: 20, color: RM.inkMid),
                      Text(
                        'Pick another time',
                        style: RM.dayLabel.copyWith(
                          fontWeight: FontWeight.w600,
                          color: RM.inkMid,
                        ),
                      ),
                    ],
                  ),
                ),
                _ActionButton(
                  height: 48,
                  onTap: () => _discard(context),
                  child: Text(
                    'Discard session',
                    style: RM.chip.copyWith(fontSize: 14, color: RM.alarm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The editor for a session that is already finished.
///
/// Every session here was recorded by voice, so a misheard type and an end time
/// taken at the wrong moment are both routine, and until now neither could be
/// corrected. Deleting lives here too, behind the same confirmation the discard
/// path uses.
class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.session, required this.now});

  final WorkoutSession session;
  final DateTime now;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _type;
  late DateTime _start;
  late DateTime _end;

  @override
  void initState() {
    super.initState();
    _type = TextEditingController(text: widget.session.type);
    _start = widget.session.startedAt;
    // Only a finished session is routed to this sheet, so it has an end time.
    _end = widget.session.endedAt!;
  }

  @override
  void dispose() {
    _type.dispose();
    super.dispose();
  }

  /// Why this cannot be saved, or null when it can.
  ///
  /// The times are refused rather than quietly clamped: a session ending before
  /// it starts is a negative duration, and one of those poisons the median that
  /// every later overnight guess is built on.
  /// Nothing anyone trains for is longer than this. The ceiling exists because
  /// the day-resolution rule below can roll an end onto the following day, and
  /// without an upper bound a mistyped end silently became a fifteen or twenty
  /// five hour workout that then skewed the median for every later guess.
  static const Duration _maxSpan = Duration(hours: 12);

  String? get _problem {
    if (_end.isBefore(_start)) {
      return 'This would end before it started at ${formatTime(_start)}. '
          'Pick a later end.';
    }
    if (_start.isAfter(widget.now)) {
      return 'That start has not happened yet. Pick a time up to '
          '${formatTime(widget.now)}.';
    }
    if (_end.isAfter(widget.now)) {
      return 'That end has not happened yet. Pick a time up to '
          '${formatTime(widget.now)}.';
    }
    if (_end.difference(_start) > _maxSpan) {
      return 'That is ${formatDuration(_end.difference(_start))} long. '
          'Check the times, a session cannot run past '
          '${_maxSpan.inHours} hours.';
    }
    return null;
  }

  Future<TimeOfDay?> _pickTime(DateTime initial) => showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initial),
        builder: (context, child) => Theme(data: RM.theme(), child: child!),
      );

  /// The start keeps its calendar day. A time picker answers when, not which
  /// day, and a session dragged onto another date is a different session.
  Future<void> _pickStart() async {
    final picked = await _pickTime(_start);
    if (picked == null) return;
    setState(() {
      _start = DateTime(
        _start.year,
        _start.month,
        _start.day,
        picked.hour,
        picked.minute,
      );
      // The end's calendar day was resolved against the OLD start, so moving
      // the start can strand it a day away and produce a multi-day span that
      // no single-field check would catch. Re-resolve it from its clock time.
      _end = _resolveEnd(TimeOfDay.fromDateTime(_end));
    });
  }

  Future<void> _pickEnd() async {
    final picked = await _pickTime(_end);
    if (picked == null) return;
    setState(() => _end = _resolveEnd(picked));
  }

  /// Places a picked end time on the right calendar day, by the same rule the
  /// overnight flow uses: a time earlier on the clock than the start belongs to
  /// the day after it, unless that day has not happened yet, in which case it
  /// stays on the start's day and [_problem] explains the refusal. Days are
  /// stepped by calendar date rather than by adding 24 hours so a daylight
  /// saving change does not shift the result by an hour.
  DateTime _resolveEnd(TimeOfDay picked) {
    final sameDay = DateTime(
      _start.year,
      _start.month,
      _start.day,
      picked.hour,
      picked.minute,
    );
    if (!sameDay.isBefore(_start)) return sameDay;
    final nextDay = DateTime(
      _start.year,
      _start.month,
      _start.day + 1,
      picked.hour,
      picked.minute,
    );
    // Roll over only when the result is both in the past and a believable
    // length. Without the span test, picking an early morning end on a session
    // that started the previous evening produced a session of half a day or
    // more, and every check passed it.
    final rollable =
        !nextDay.isAfter(widget.now) && nextDay.difference(_start) <= _maxSpan;
    return rollable ? nextDay : sameDay;
  }

  void _save() {
    final type = _type.text.trim();
    Navigator.of(context).pop(
      UpdateSession(
        widget.session.copyWith(
          // An unnamed session is a shape the app already knows, so an emptied
          // field falls back to it instead of blocking the save.
          type: type.isEmpty ? WorkoutSession.unnamed : type,
          startedAt: _start,
          endedAt: _end,
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final navigator = Navigator.of(context);
    if (!await _confirmDiscard(context)) return;
    navigator.pop(const DiscardSession());
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    final span = _end.difference(_start);
    // Named on the card, because "07:15" under a session that started at 22:00
    // otherwise reads as a mistake rather than as the morning after.
    final overnight = daysBetween(_start, _end) > 0;
    final canSave = problem == null;

    return Padding(
      // The type field brings the keyboard up, which would otherwise sit over
      // the buttons underneath it.
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            const _GrabHandle(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(
                  formatDate(_start),
                  style: RM.label.copyWith(fontSize: 13, letterSpacing: 0),
                ),
                // The type is a spoken word the model transcribed, so it is the
                // likeliest thing on this sheet to be wrong. It stays looking
                // like the title it replaces rather than becoming a boxed form
                // field.
                Row(
                  spacing: 10,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _type,
                        textCapitalization: TextCapitalization.sentences,
                        style: RM.sheetTitle.copyWith(fontSize: 24),
                        cursorColor: RM.accentLight,
                        decoration: InputDecoration(
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          hintText: WorkoutSession.unnamed,
                          hintStyle: RM.sheetTitle.copyWith(
                            fontSize: 24,
                            color: RM.inkSoft,
                          ),
                        ),
                        onSubmitted: canSave ? (_) => _save() : null,
                      ),
                    ),
                    const Icon(Icons.edit, size: 20, color: RM.inkSoft),
                  ],
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: [
                // Intrinsic height so the cards match even if a label wraps.
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 10,
                    children: [
                      Expanded(
                        child: _FactCard(
                          label: 'STARTED',
                          value: formatTime(_start),
                          onTap: _pickStart,
                        ),
                      ),
                      Expanded(
                        child: _FactCard(
                          label: overnight ? 'ENDED NEXT DAY' : 'ENDED',
                          value: formatTime(_end),
                          onTap: _pickEnd,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!span.isNegative)
                  Text(_durationText(span), style: RM.rowMeta),
                if (problem != null)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      const Icon(
                        Icons.warning_amber,
                        size: 18,
                        color: RM.alarm,
                      ),
                      Expanded(
                        child: Text(
                          problem,
                          style: RM.chip.copyWith(color: RM.alarm),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: [
                _ActionButton(
                  height: 56,
                  fill: canSave ? RM.accent : RM.field,
                  onTap: canSave ? _save : null,
                  child: Text(
                    'Save changes',
                    style: canSave
                        ? RM.button
                        : RM.button.copyWith(color: RM.inkSoft),
                  ),
                ),
                _ActionButton(
                  height: 48,
                  onTap: _delete,
                  child: Text(
                    'Delete session',
                    style: RM.chip.copyWith(fontSize: 14, color: RM.alarm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar at the top of the sheet that says it can be dragged away.
class _GrabHandle extends StatelessWidget {
  const _GrabHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: RM.line,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// "1 h 10 min", the shape [formatLead] uses without its trailing "before".
String _durationText(Duration d) {
  final minutes = d.inMinutes;
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// Why the sheet is asking, and where its suggestion came from.
class _Explanation extends StatelessWidget {
  const _Explanation({required this.median, required this.guess});

  final Duration? median;
  final DateTime? guess;

  @override
  Widget build(BuildContext context) {
    final median = this.median;
    final guess = this.guess;
    final strong = RM.body.copyWith(color: RM.ink, fontWeight: FontWeight.w700);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: RM.field,
        borderRadius: BorderRadius.circular(RM.rField),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          const Icon(Icons.bedtime, size: 22, color: RM.alarm),
          Expanded(
            child: median == null || guess == null
                ? Text(
                    'This session was never ended, and there is no history '
                    'yet to guess from. Pick when you left.',
                    style: RM.body,
                  )
                : Text.rich(
                    TextSpan(
                      style: RM.body,
                      children: [
                        const TextSpan(
                          text: 'This session was never ended. Your sessions '
                              'usually run about ',
                        ),
                        TextSpan(text: _durationText(median), style: strong),
                        const TextSpan(text: ', so '),
                        TextSpan(text: formatTime(guess), style: strong),
                        const TextSpan(text: ' is a fair guess.'),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One of the two small cards. [missing] draws the card hollow, with a dashed
/// outline in the alarm colour: the absent end time is the whole point of the
/// overnight sheet, so it reads as a gap rather than as a value that happens to
/// be blank. [onTap] opens a picker for it, which only the editor does.
class _FactCard extends StatelessWidget {
  const _FactCard({
    required this.label,
    required this.value,
    this.missing = false,
    this.onTap,
  });

  final String label;
  final String value;
  final bool missing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            label,
            style: missing ? RM.label.copyWith(color: RM.alarm) : RM.label,
          ),
          Text(
            value,
            style: missing
                ? RM.fieldValueBig.copyWith(color: RM.alarm)
                : RM.fieldValueBig,
          ),
        ],
      ),
    );

    if (!missing) {
      final radius = BorderRadius.circular(RM.rField);
      return Material(
        color: RM.field,
        borderRadius: radius,
        child: InkWell(borderRadius: radius, onTap: onTap, child: content),
      );
    }
    return CustomPaint(
      painter: const _DashedBorderPainter(color: RM.alarm, radius: RM.rField),
      child: content,
    );
  }
}

/// Flutter has no dashed [BoxBorder], so the outline is stroked by hand: the
/// rounded rectangle is walked with [Path.computeMetrics] and drawn in pieces,
/// which keeps the dashes even around the corners.
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  static const double strokeWidth = 1.5;
  static const double dash = 6;
  static const double gap = 4;

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // A stroke straddles its path, so the path is inset by half of it to keep
    // the whole outline inside the card's box.
    final inset = strokeWidth / 2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            inset,
            inset,
            size.width - strokeWidth,
            size.height - strokeWidth,
          ),
          Radius.circular(math.max(0, radius - inset)),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    for (final metric in path.computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = math.min(start + dash, metric.length);
        canvas.drawPath(metric.extractPath(start, end), paint);
        start = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

/// The sheet actions differ only in height, fill and border, and every one of
/// them is a pill, which is where the radius comes from. A null [onTap] leaves
/// the button dead, which is how the editor refuses to save impossible times
/// while still showing what it would save.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.height,
    required this.onTap,
    required this.child,
    this.fill = Colors.transparent,
    this.border,
  });

  final double height;
  final VoidCallback? onTap;
  final Widget child;
  final Color fill;
  final BorderSide? border;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(height / 2);
    return Material(
      color: fill,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: border ?? BorderSide.none,
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Center(child: child),
        ),
      ),
    );
  }
}
