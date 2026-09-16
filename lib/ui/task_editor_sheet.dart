import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/gemini_client.dart';
import 'design.dart';
import 'format.dart';

/// Lead time choices offered in the editor, in minutes.
///
/// Zero ("at the time") is not in the row by design, but a task already saved
/// with it still gets its chip, so opening the editor never silently moves an
/// existing reminder.
const List<int> _leadChoices = [5, 10, 15, 30, 60, 120, 1440];

/// Shows the add/edit sheet and returns the task to save, or null if dismissed.
///
/// The same sheet serves three jobs: confirming what Gemini heard, editing an
/// existing task, and adding one by hand. They differ only in what seeds the
/// fields, so they share one form rather than three that drift apart.
Future<Task?> showTaskEditor(
  BuildContext context, {
  Task? existing,
  ParsedTask? parsed,
}) {
  return showModalBottomSheet<Task>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: RM.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RM.rSheet)),
    ),
    builder: (context) => _TaskEditorSheet(existing: existing, parsed: parsed),
  );
}

class _TaskEditorSheet extends StatefulWidget {
  const _TaskEditorSheet({this.existing, this.parsed});

  final Task? existing;
  final ParsedTask? parsed;

  @override
  State<_TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends State<_TaskEditorSheet> {
  late final TextEditingController _title;
  late DateTime _dueAt;
  late int _lead;
  late bool _useAlarm;
  late Recurrence _recurrence;

  bool get _isConfirming => widget.parsed != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final parsed = widget.parsed;

    _title = TextEditingController(
      text: existing?.title ?? parsed?.title ?? '',
    );
    _dueAt = existing?.dueAt ??
        parsed?.dueAt ??
        _nextRoundHour(DateTime.now().add(const Duration(hours: 1)));
    _lead = existing?.reminderMinutesBefore ??
        parsed?.reminderMinutesBefore ??
        Task.defaultReminderMinutes;
    _useAlarm = existing?.useAlarm ?? parsed?.useAlarm ?? false;
    _recurrence =
        existing?.recurrence ?? parsed?.recurrence ?? Recurrence.none;

    _hasTitle = _title.text.trim().isNotEmpty;
    // Only rebuilds when the title crosses between empty and non empty, rather
    // than on every keystroke, since that flip is all the Save button cares
    // about.
    _title.addListener(() {
      final has = _title.text.trim().isNotEmpty;
      if (has != _hasTitle && mounted) setState(() => _hasTitle = has);
    });
  }

  late bool _hasTitle;

  static DateTime _nextRoundHour(DateTime t) =>
      DateTime(t.year, t.month, t.day, t.hour);

  /// The visible chips, plus the task's own lead time when it is off the menu.
  List<int> get _choices =>
      _leadChoices.contains(_lead) ? _leadChoices : [_lead, ..._leadChoices];

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      builder: (context, child) => Theme(data: RM.theme(), child: child!),
    );
    if (picked == null) return;
    setState(() {
      _dueAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _dueAt.hour,
        _dueAt.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueAt),
      builder: (context, child) => Theme(data: RM.theme(), child: child!),
    );
    if (picked == null) return;
    setState(() {
      _dueAt = DateTime(
        _dueAt.year,
        _dueAt.month,
        _dueAt.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  /// The task the sheet currently describes.
  ///
  /// Shared by the Save button and the countdown so the two can never disagree
  /// about when this next fires: the countdown asks the model for
  /// [Task.nextDueAt] rather than re-deriving the repeat rule in the UI.
  Task _draft() {
    final title = _title.text.trim();
    final existing = widget.existing;
    return existing == null
        ? Task(
            title: title,
            dueAt: _dueAt,
            reminderMinutesBefore: _lead,
            useAlarm: _useAlarm,
            recurrence: _recurrence,
            createdAt: DateTime.now(),
          )
        : existing.copyWith(
            title: title,
            dueAt: _dueAt,
            reminderMinutesBefore: _lead,
            useAlarm: _useAlarm,
            recurrence: _recurrence,
          );
  }

  void _save() {
    if (_title.text.trim().isEmpty) return;
    Navigator.of(context).pop(_draft());
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // A repeating task's first date is allowed to be behind us, so the header
    // counts down to the occurrence that will actually happen. For a one off
    // this is just _dueAt.
    final nextDue = _draft().nextDueAt(now);
    final remindAt = nextDue.subtract(Duration(minutes: _lead));
    // Only a one off can be too late to save. A weekly reminder first set last
    // month still fires next week, which is exactly what the user wants.
    final remindInPast = !_recurrence.repeats && remindAt.isBefore(now);
    final duePast = nextDue.isBefore(now);
    // A button that looks live but does nothing when tapped reads as a broken
    // app, so an empty title disables it visibly rather than silently.
    final canSave = !remindInPast && _hasTitle;

    return Padding(
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
            Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: RM.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isConfirming
                      ? 'HEARD AS'
                      : widget.existing == null
                          ? 'NEW REMINDER'
                          : 'REMINDER',
                  style: RM.label.copyWith(fontSize: 13),
                ),
                Text(
                  duePast ? 'in the past' : _countdown(nextDue.difference(now)),
                  style: RM.chip.copyWith(
                    color: duePast ? RM.alarm : RM.accentLight,
                  ),
                ),
              ],
            ),
            if (_isConfirming && widget.parsed!.needsClarification)
              const _NoticeRow(
                icon: Icons.help_outline,
                text: 'I had to guess part of this. Check the time.',
                color: RM.accentLight,
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  spacing: 10,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _title,
                        autofocus: !_isConfirming,
                        textCapitalization: TextCapitalization.sentences,
                        style: RM.sheetTitle,
                        cursorColor: RM.accentLight,
                        decoration: InputDecoration(
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          hintText: 'What should I remind you about?',
                          hintStyle: RM.sheetTitle.copyWith(color: RM.inkSoft),
                        ),
                        onSubmitted: canSave ? (_) => _save() : null,
                      ),
                    ),
                    const Icon(Icons.edit, size: 20, color: RM.inkSoft),
                  ],
                ),
                const SizedBox(height: 12),
                Container(height: 1, color: RM.line),
              ],
            ),
            Row(
              spacing: 10,
              children: [
                Expanded(
                  child: _PickerCard(
                    label: 'DATE',
                    value: formatDate(_dueAt),
                    style: RM.fieldValue,
                    onTap: _pickDate,
                  ),
                ),
                Expanded(
                  child: _PickerCard(
                    label: 'TIME',
                    value: formatTime(_dueAt),
                    style: RM.fieldValueBig,
                    onTap: _pickTime,
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 10,
              children: [
                Text(
                  'Remind me before',
                  style: RM.chip.copyWith(color: RM.inkSoft),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in _choices)
                      _ChoiceChip(
                        label: _leadLabel(m),
                        selected: _lead == m,
                        onTap: () => setState(() => _lead = m),
                      ),
                  ],
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 10,
              children: [
                Text('Repeats', style: RM.chip.copyWith(color: RM.inkSoft)),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in Recurrence.values)
                      _ChoiceChip(
                        label: r.label,
                        selected: _recurrence == r,
                        onTap: () => setState(() => _recurrence = r),
                      ),
                  ],
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                color: RM.field,
                borderRadius: BorderRadius.circular(RM.rField),
              ),
              child: Row(
                spacing: 14,
                children: [
                  const Icon(Icons.alarm, size: 24, color: RM.alarm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(
                          'Wake me with an alarm',
                          style: RM.dayLabel.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _useAlarm
                              ? 'Loud, and it ignores silent mode'
                              : 'Off: a quiet notification instead',
                          style: RM.dayDate,
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _useAlarm,
                    onChanged: (v) => setState(() => _useAlarm = v),
                    thumbColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? RM.accentBright
                          : RM.inkSoft,
                    ),
                    trackColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? RM.accentContainer
                          : Colors.transparent,
                    ),
                    trackOutlineColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? RM.accentContainer
                          : RM.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
            if (remindInPast)
              const _NoticeRow(
                icon: Icons.warning_amber,
                text: 'That reminder time has already passed, so nothing '
                    'will fire. Pick a later time.',
                color: RM.alarm,
              ),
            _SaveButton(onTap: canSave ? _save : null),
          ],
        ),
      ),
    );
  }
}

/// How far off the due moment is, e.g. "in 45 min", "in 23 h", "in 3 days".
String _countdown(Duration d) {
  if (d.inMinutes < 1) return 'in under a min';
  if (d.inMinutes < 60) return 'in ${d.inMinutes} min';
  if (d.inHours < 24) return 'in ${d.inHours} h';
  final days = d.inDays;
  return days == 1 ? 'in 1 day' : 'in $days days';
}

/// Chip labels are shorter than [formatLead]: the section heading already says
/// "before", so repeating it on seven chips is noise.
String _leadLabel(int minutes) {
  if (minutes <= 0) return 'At the time';
  if (minutes <= 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  // The remainder has to show: a task parsed with a 150 minute lead would
  // otherwise render a second chip reading "2 h", identical to the 120 one.
  return m == 0 ? '$h h' : '$h h $m min';
}

class _PickerCard extends StatelessWidget {
  const _PickerCard({
    required this.label,
    required this.value,
    required this.style,
    required this.onTap,
  });

  final String label;
  final String value;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rField);
    return Material(
      color: RM.field,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(label, style: RM.label),
              Text(value, style: style),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pill used by both chip rows, so the lead times and the repeat options
/// cannot drift apart visually.
class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rChip);
    return Material(
      color: selected ? RM.accentContainer : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: selected
            ? BorderSide.none
            : const BorderSide(color: RM.line, width: 1),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              if (selected)
                const Icon(Icons.check, size: 16, color: RM.accentBright),
              Text(
                label,
                style: selected
                    ? RM.chip.copyWith(
                        fontWeight: FontWeight.w700,
                        color: RM.accentBright,
                      )
                    : RM.chip,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onTap});

  /// Null while the reminder moment is in the past, which is what renders the
  /// button dead rather than letting it save something that will never fire.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final radius = BorderRadius.circular(28);
    return Material(
      color: enabled ? RM.accent : RM.field,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              Icon(
                Icons.check,
                size: 22,
                color: enabled ? Colors.white : RM.inkSoft,
              ),
              Text(
                'Save reminder',
                style: enabled
                    ? RM.button
                    : RM.button.copyWith(color: RM.inkSoft),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Icon(icon, size: 18, color: color),
        Expanded(
          child: Text(text, style: RM.chip.copyWith(color: color)),
        ),
      ],
    );
  }
}
