import 'package:flutter/material.dart';

import '../models/note.dart';
import 'design.dart';
import 'format.dart';

/// Weekday names for the past week. format.dart names a weekday only inside the
/// coming week, because reminders look forward, and a note only ever looks back.
const List<String> _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// "Today", "Yesterday", the weekday inside the past week, then a short date.
String _groupLabel(DateTime when, DateTime now) {
  final diff = daysBetween(now, when);
  if (diff < -1 && diff > -7) return _weekdays[when.weekday - 1];
  return relativeDayLabel(when, now);
}

/// Opens the note editor and returns the trimmed text, or null if dismissed.
///
/// A note has no fields to fill in, so the sheet is the text and nothing else:
/// anything spoken without a time lands here exactly as it was said.
Future<String?> showNoteEditor(BuildContext context, {Note? existing}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: RM.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RM.rSheet)),
    ),
    builder: (context) => _NoteEditorSheet(existing: existing),
  );
}

/// The Notes tab: a search field, then the notes under day headers.
///
/// The scaffold, mic bar and bottom nav come from the host page, this renders
/// the body only. Stateful because the search field is this widget's own: the
/// filter runs here over [notes] rather than through a callback, so typing
/// never waits on a database round trip.
class NotesPage extends StatefulWidget {
  const NotesPage({
    super.key,
    required this.notes,
    required this.onEdit,
    required this.onDelete,
  });

  /// Newest first.
  final List<Note> notes;

  final Future<void> Function(Note) onEdit;
  final Future<void> Function(Note) onDelete;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Tracked rather than read straight off the controller in build, so moving
    // the caret does not rebuild the whole list.
    _search.addListener(() {
      if (_search.text != _query && mounted) {
        setState(() => _query = _search.text);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clear() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    // A search box over nothing is furniture, so an empty tab is only the
    // empty state.
    if (widget.notes.isEmpty) return const _EmptyState();

    final query = _query.trim();
    final visible = query.isEmpty
        ? widget.notes
        : widget.notes.where((n) => n.matches(query)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: _SearchField(
            controller: _search,
            // Keyed off the raw text, not the trimmed query: a field holding
            // only spaces still has something to clear.
            onClear: _query.isEmpty ? null : _clear,
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? _NoResults(query: query, onClear: _clear)
              : _NoteList(
                  notes: visible,
                  onEdit: widget.onEdit,
                  onDelete: widget.onDelete,
                ),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onClear});

  final TextEditingController controller;

  /// Null while there is nothing to clear, which is what hides the button.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final onClear = this.onClear;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: RM.field,
        borderRadius: BorderRadius.circular(RM.rChip),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Icon(Icons.search, size: 20, color: RM.inkSoft),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              style: RM.rowTitle,
              cursorColor: RM.accentLight,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: 'Search notes',
                hintStyle: RM.body,
              ),
            ),
          ),
          if (onClear == null)
            const SizedBox(width: 12)
          else
            // A 44 square keeps the tap target honest inside a 44 high field,
            // where an IconButton would force its own 48 and overflow.
            GestureDetector(
              onTap: onClear,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.close, size: 18, color: RM.inkSoft),
              ),
            ),
        ],
      ),
    );
  }
}

class _NoteList extends StatelessWidget {
  const _NoteList({
    required this.notes,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Note> notes;
  final Future<void> Function(Note) onEdit;
  final Future<void> Function(Note) onDelete;

  @override
  Widget build(BuildContext context) {
    // Read once so every header on this build agrees about what day it is.
    // The host owns the clock for the other tabs, but grouping is the only
    // thing here that needs one, so it is not worth a constructor argument.
    final now = DateTime.now();

    // Grouped by the day itself rather than by the label, so two notes a year
    // apart cannot land in one group because their short dates read the same.
    final groups = <_DayGroup>[];
    for (final note in notes) {
      final when = note.createdAt;
      final day = DateTime(when.year, when.month, when.day);
      if (groups.isEmpty || groups.last.day != day) {
        groups.add(_DayGroup(day: day, label: _groupLabel(when, now)));
      }
      groups.last.notes.add(note);
    }

    final rows = <Widget>[];
    for (final group in groups) {
      rows.add(
        _DayHeader(
          label: group.label,
          count: group.notes.length,
          first: rows.isEmpty,
        ),
      );
      for (var i = 0; i < group.notes.length; i++) {
        if (i > 0) rows.add(const SizedBox(height: 6));
        final note = group.notes[i];
        rows.add(
          _NoteRow(
            note: note,
            onTap: () => onEdit(note),
            onDelete: () => onDelete(note),
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
}

/// One day's notes, in the order they were listed.
class _DayGroup {
  _DayGroup({required this.day, required this.label});

  /// Local midnight, the identity of the group.
  final DateTime day;

  final String label;
  final List<Note> notes = [];
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.label,
    required this.count,
    required this.first,
  });

  final String label;
  final int count;
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, first ? 4 : 14, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label, style: RM.dayLabel),
          const SizedBox(width: 8),
          Text(count == 1 ? '1 note' : '$count notes', style: RM.dayDate),
        ],
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.onTap,
    required this.onDelete,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rRow);

    return Dismissible(
      key: ValueKey(note.id),
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
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Three lines, not one: a dictated note is often a sentence or
                // two, and the whole point is to read it without opening it.
                Text(
                  note.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: RM.rowTitle,
                ),
                const SizedBox(height: 6),
                Text(formatTime(note.createdAt), style: RM.rowMeta),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Notes tab before there is anything to show.
///
/// Teaches the shape of a note rather than inventing data to fill the screen.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return _CenteredBody(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.sticky_note_2, size: 56, color: RM.line),
          const SizedBox(height: 28),
          Column(
            children: [
              Text(
                'Nothing noted yet',
                textAlign: TextAlign.center,
                style: RM.sheetTitle,
              ),
              const SizedBox(height: 8),
              Text(
                'Anything you say without a time lands here, word for word.',
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
                label: 'TRY SAYING',
                phrase: '“The wifi password is hunter2”',
              ),
              SizedBox(height: 10),
              _ExampleCard(
                label: 'OR',
                phrase: '“Marko’s new number is 091 555 1234”',
              ),
            ],
          ),
        ],
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

/// A search that found nothing.
///
/// Deliberately quieter than the empty state and with no examples in it: "you
/// have no notes" and "this search found nothing" are different facts, and
/// teaching the mic again to someone who is looking for a note they already
/// took would be answering a question nobody asked.
class _NoResults extends StatelessWidget {
  const _NoResults({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return _CenteredBody(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 32, color: RM.line),
          const SizedBox(height: 14),
          Text(
            'No notes match “$query”',
            textAlign: TextAlign.center,
            style: RM.body,
          ),
          const SizedBox(height: 16),
          Material(
            color: RM.field,
            borderRadius: BorderRadius.circular(RM.rChip),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onClear,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Text('Clear search', style: RM.chip),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Centres a short body, and scrolls it once the page is squeezed by the
/// keyboard or by the header banner, so neither state can overflow on a 360dp
/// phone. The bottom pad clears the floating mic bar.
class _CenteredBody extends StatelessWidget {
  const _CenteredBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(36, 24, 36, 120),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - 144).clamp(0, double.infinity),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _NoteEditorSheet extends StatefulWidget {
  const _NoteEditorSheet({this.existing});

  final Note? existing;

  @override
  State<_NoteEditorSheet> createState() => _NoteEditorSheetState();
}

class _NoteEditorSheetState extends State<_NoteEditorSheet> {
  late final TextEditingController _text;
  late bool _hasText;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.existing?.text ?? '');
    _hasText = _text.text.trim().isNotEmpty;
    // Only rebuilds when the text crosses between empty and non empty, rather
    // than on every keystroke, since that flip is all the Save button cares
    // about.
    _text.addListener(() {
      final has = _text.text.trim().isNotEmpty;
      if (has != _hasText && mounted) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
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
          spacing: 16,
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
            Text(
              widget.existing == null ? 'NEW NOTE' : 'NOTE',
              style: RM.label.copyWith(fontSize: 13),
            ),
            // Plain text on the sheet, with no box drawn around it. A note is
            // the whole document here, not one field of a form.
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 4,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: RM.rowTitle.copyWith(fontSize: 17),
              cursorColor: RM.accentLight,
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            _SaveButton(onTap: _hasText ? _save : null),
          ],
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onTap});

  /// Null while the note is empty. A button that looks live but does nothing
  /// when tapped reads as a broken app, so it is drawn dead as well as being
  /// dead.
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
          child: Center(
            child: Text(
              'Save',
              style: enabled ? RM.button : RM.button.copyWith(color: RM.inkSoft),
            ),
          ),
        ),
      ),
    );
  }
}
