import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/note.dart';
import '../models/task.dart';
import '../models/workout_session.dart';
import '../services/gemini_client.dart';
import '../services/update_service.dart';
import 'design.dart';
import 'format.dart';
import 'api_key_page.dart';
import 'insights_page.dart';
import 'notes_page.dart';
import 'onboarding_page.dart';
import 'session_sheet.dart';
import 'task_editor_sheet.dart';
import 'voice_capture_sheet.dart';
import 'workouts_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.services});

  final AppServices services;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Task> _tasks = const [];
  List<WorkoutSession> _sessions = const [];
  List<Note> _notes = const [];
  WorkoutSession? _running;
  bool _loading = true;
  bool _showDone = false;
  int _tab = 0;

  /// Guards the stale session prompt so it is asked once per launch, not once
  /// per rebuild.
  bool _askedAboutStale = false;

  AppServices get _s => widget.services;

  @override
  void initState() {
    super.initState();
    _load();
    // Runs after the first frame so the onboarding page has a mounted
    // Navigator to push onto.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPermissions());
  }

  Future<void> _load() async {
    final tasks = await _s.repository.all();
    final sessions = await _s.workouts.all();
    final running = await _s.workouts.running();
    final notes = await _s.notes.all();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _sessions = sessions;
      _running = running;
      _notes = notes;
      _loading = false;
    });
    await _offerToCloseStaleSession();
  }

  /// A session still open from yesterday means the user left the gym without
  /// saying so. The app asks rather than inventing an end time, since a made up
  /// duration would quietly poison every average it computes later.
  Future<void> _offerToCloseStaleSession() async {
    if (_askedAboutStale) return;
    final stale = _running;
    if (stale == null || !stale.isStale(DateTime.now())) return;
    _askedAboutStale = true;

    final median = await _s.workouts.medianDuration();
    if (!mounted) return;
    final outcome = await showSessionSheet(
      context,
      session: stale,
      medianDuration: median,
    );
    if (outcome == null || !mounted) return;
    await _applyOutcome(stale, outcome);
  }

  Future<void> _applyOutcome(
    WorkoutSession session,
    SessionOutcome outcome,
  ) async {
    switch (outcome) {
      // Destructured as endAt because "when" is reserved in pattern syntax.
      case EndSessionAt(when: final endAt):
        await _s.workouts.end(session.id!, endAt);
      case DiscardSession():
        await _s.workouts.delete(session.id!);
      case UpdateSession(:final session):
        await _s.workouts.update(session);
    }
    await _load();
  }

  Future<void> _endRunningSession() async {
    final running = _running;
    if (running == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ended = await _s.workouts.end(running.id!, DateTime.now());
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${ended.type} logged, ${formatDuration(ended.duration!)}',
        ),
      ),
    );
  }

  /// Opening a past session is only useful when it was never closed properly,
  /// so a finished one does nothing rather than offering a sheet with no
  /// decision in it.
  Future<void> _openSession(WorkoutSession session) async {
    final median = await _s.workouts.medianDuration();
    if (!mounted) return;
    final outcome = await showSessionSheet(
      context,
      session: session,
      medianDuration: median,
    );
    if (outcome == null || !mounted) return;
    await _applyOutcome(session, outcome);
  }

  Future<void> _checkPermissions() async {
    final report = await _s.permissions.checkAll();
    if (mounted && !report.allCritical) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OnboardingPage(permissions: _s.permissions),
        ),
      );
    }
    // Asked after permissions, not before: the key screen is meaningless until
    // the app can actually hear anything.
    if (!mounted) return;
    if (!await _s.apiKeys.hasKey()) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ApiKeyPage(store: _s.apiKeys, isFirstRun: true),
        ),
      );
      await _s.refreshGemini();
      if (mounted) setState(() {});
    }
  }

  // Voice capture, parse, confirm, save.
  Future<void> _captureByVoice() async {
    final messenger = ScaffoldMessenger.of(context);

    // Permission first: requesting it is also what initialises the recogniser,
    // so availability cannot be judged before this returns.
    if (!await _s.permissions.requestMicrophone()) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Microphone permission is required')),
      );
      return;
    }
    if (!_s.speech.isAvailable && !await _s.speech.init()) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Speech recognition is not available on this device'),
        ),
      );
      return;
    }

    if (!mounted) return;
    final transcript = await showVoiceCapture(context, _s.speech);
    if (transcript == null || !mounted) return;

    final gemini = _s.gemini;
    if (gemini == null) {
      // No API key, so fall back to the manual editor seeded with the raw
      // words rather than dropping what the user just said on the floor.
      await _openEditor(
        parsed: ParsedTask(
          title: transcript,
          dueAt: DateTime.now().add(const Duration(hours: 1)),
          reminderMinutesBefore: Task.defaultReminderMinutes,
          useAlarm: false,
          needsClarification: true,
        ),
      );
      return;
    }

    _setBusy(true);
    ParsedIntent intent;
    try {
      intent = await gemini.interpret(transcript);
    } on GeminiException catch (e) {
      if (!mounted) return;
      _setBusy(false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.message),
          action: SnackBarAction(
            label: 'Type it',
            onPressed: () => _openEditor(),
          ),
        ),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      _setBusy(false);
      messenger.showSnackBar(SnackBar(content: Text('Could not parse: $e')));
      return;
    }
    if (!mounted) return;
    _setBusy(false);

    // One microphone, three meanings. The model classified it, so the app just
    // routes rather than guessing from the words a second time.
    switch (intent) {
      case ReminderIntent(:final task):
        await _openEditor(parsed: task);
      case WorkoutStartIntent(:final type):
        await _startSession(type);
      case WorkoutEndIntent():
        await _endSessionByVoice();
      case NoteIntent(:final text):
        await _saveNote(text);
    }
  }

  Future<void> _saveNote(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final note = await _s.notes.add(text);
    await _load();
    if (!mounted) return;
    setState(() => _tab = 2);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Noted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _s.notes.delete(note.id!);
            await _load();
          },
        ),
      ),
    );
  }

  Future<void> _addNoteManually() async {
    final text = await showNoteEditor(context);
    if (text == null || !mounted) return;
    await _s.notes.add(text);
    await _load();
  }

  Future<void> _editNote(Note note) async {
    final text = await showNoteEditor(context, existing: note);
    if (text == null || !mounted) return;
    await _s.notes.update(note.copyWith(text: text));
    await _load();
  }

  /// Deleting matches the reminder list: gone immediately, undoable for as long
  /// as the snackbar is up. Re-adding mints a new id, which is fine, the old
  /// row is gone.
  Future<void> _deleteNote(Note note) async {
    final messenger = ScaffoldMessenger.of(context);
    await _s.notes.delete(note.id!);
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('Deleted "${note.preview}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _s.notes.add(note.text, at: note.createdAt);
            await _load();
          },
        ),
      ),
    );
  }

  Future<void> _deleteSession(WorkoutSession session) async {
    final messenger = ScaffoldMessenger.of(context);
    await _s.workouts.delete(session.id!);
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('Deleted "${session.type}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            // Restored through update on a fresh row rather than start(), which
            // would auto-close anything currently running.
            final restored = await _s.workouts.start(
              session.type,
              at: session.startedAt,
            );
            final end = session.endedAt;
            if (end != null) await _s.workouts.end(restored.id!, end);
            await _load();
          },
        ),
      ),
    );
  }

  Future<void> _startSession(String type) async {
    final messenger = ScaffoldMessenger.of(context);
    final previous = _running;
    await _s.workouts.start(type);
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          previous == null
              ? '$type started'
              // Starting a second session closes the first, so say so rather
              // than letting a session vanish silently.
              : '$type started, ${previous.type} closed',
        ),
      ),
    );
    setState(() => _tab = 1);
  }

  Future<void> _endSessionByVoice() async {
    if (_running == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No workout is running')),
      );
      return;
    }
    await _endRunningSession();
    if (!mounted) return;
    setState(() => _tab = 1);
  }

  void _setBusy(bool busy) {
    if (busy) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    } else {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _openEditor({Task? existing, ParsedTask? parsed}) async {
    final task = await showTaskEditor(
      context,
      existing: existing,
      parsed: parsed,
    );
    if (task == null || !mounted) return;
    await _persist(task);
  }

  Future<void> _persist(Task task) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved =
        task.id == null ? await _s.repository.add(task) : task;
    if (task.id != null) await _s.repository.update(task);
    await _s.scheduler.schedule(saved);
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved.isDone
              ? 'Saved'
              : 'Reminder set for ${formatWhen(saved.remindAt, DateTime.now())}',
        ),
      ),
    );
  }

  Future<void> _toggleDone(Task task) async {
    final updated = task.copyWith(isDone: !task.isDone);
    await _s.repository.update(updated);
    if (updated.isDone) {
      await _s.scheduler.cancel(updated.id!);
    } else {
      await _s.scheduler.schedule(updated);
    }
    await _load();
  }

  Future<void> _delete(Task task) async {
    final messenger = ScaffoldMessenger.of(context);
    await _s.repository.delete(task.id!);
    await _s.scheduler.cancel(task.id!);
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('Deleted "${task.title}"'),
        action: SnackBarAction(
          label: 'Undo',
          // Rebuilt without an id rather than copied: copyWith cannot clear a
          // field, so a copy would keep the dead row id and _persist would
          // update a row that no longer exists. Re-inserting mints a new id,
          // which is fine, the old one is gone from both the database and the
          // OS alarm table.
          onPressed: () => _persist(
            Task(
              title: task.title,
              dueAt: task.dueAt,
              reminderMinutesBefore: task.reminderMinutesBefore,
              useAlarm: task.useAlarm,
              isDone: task.isDone,
              createdAt: task.createdAt,
            ),
          ),
        ),
      ),
    );
  }

  static const List<String> _titles = [
    'Reminders',
    'Workouts',
    'Notes',
    'Insights',
  ];

  Widget _body(DateTime now, List<Task> visible) {
    switch (_tab) {
      case 0:
        return visible.isEmpty
            ? const _EmptyState()
            : _TaskList(
                tasks: visible,
                now: now,
                onTap: (t) => _openEditor(existing: t),
                onToggle: _toggleDone,
                onDelete: _delete,
              );
      case 1:
        return WorkoutsPage(
          sessions: _sessions,
          running: _running,
          now: now,
          onEnd: _endRunningSession,
          onTapSession: _openSession,
          onDeleteSession: _deleteSession,
        );
      case 2:
        return NotesPage(
          notes: _notes,
          onEdit: _editNote,
          onDelete: _deleteNote,
        );
      default:
        return InsightsPage(
          tasks: _tasks,
          sessions: _sessions,
          noteCount: _notes.length,
          now: now,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final visible = _tasks.where((t) => _showDone || !t.isDone).toList();
    final upcoming =
        _tasks.where((t) => !t.isDone && t.dueAt.isAfter(now)).length;

    return Scaffold(
      backgroundColor: RM.bg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: _titles[_tab],
              // The count belongs to the reminder list, so it goes away with it.
              count: _tab == 0 ? upcoming : null,
              showDone: _showDone,
              onToggleShowDone: _tab == 0
                  ? () => setState(() => _showDone = !_showDone)
                  : null,
              // The keyboard moved up here when the mic went into the nav bar.
              // It is the only route when voice fails, in noise or offline, so
              // it stays a visible control rather than a hidden long press.
              onTypeManually: _tab == 2 ? _addNoteManually : _openEditor,
              onSettings: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OnboardingPage(
                      permissions: _s.permissions,
                      apiKeys: _s.apiKeys,
                      updates: UpdateService(),
                    ),
                  ),
                );
                // The key may have changed in there. Rebuild the client from
                // what is actually stored rather than leaving the app running
                // on the one it booted with.
                await _s.refreshGemini();
                if (mounted) setState(() {});
              },
            ),
            if (_s.geminiError != null)
              _Banner(text: 'Voice parsing is off. ${_s.geminiError}'),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: RM.accentLight),
                    )
                  : _body(now, visible),
            ),
            // Sits between the mic bar and the nav, where the canvas puts it.
            // Hidden on the Workouts tab, where the running card already shows
            // the same clock far more prominently, so showing both would just
            // be the same fact twice on one screen.
            RunningSessionStrip(
              session: (_tab != 1 && _running != null)
                  ? RunningSessionView(
                      name: _running!.type,
                      startedAt: _running!.startedAt,
                    )
                  : null,
              onTap: () => setState(() => _tab = 1),
            ),
            _BottomNav(
              index: _tab,
              onSelect: (i) => setState(() => _tab = i),
              onVoice: _captureByVoice,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.count,
    required this.showDone,
    required this.onToggleShowDone,
    required this.onTypeManually,
    required this.onSettings,
  });

  final String title;
  final int? count;
  final bool showDone;

  /// Null on a tab that has no list to filter, which hides the control.
  final VoidCallback? onToggleShowDone;

  /// Typing instead of speaking. It lives in the header rather than beside the
  /// mic because the mic now sits in the nav bar, and this is the only route
  /// when voice fails, so it must stay visible rather than become a gesture.
  final VoidCallback onTypeManually;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 4, 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: RM.screenTitle)),
          if (count != null)
            Text(
              '$count upcoming',
              style: RM.rowMeta.copyWith(fontSize: 13),
            ),
          if (onToggleShowDone != null)
            IconButton(
              tooltip: showDone ? 'Hide done' : 'Show done',
              icon: Icon(
                showDone ? Icons.visibility_off : Icons.checklist,
                color: RM.inkSoft,
              ),
              onPressed: onToggleShowDone,
            ),
          IconButton(
            tooltip: 'Type instead of speaking',
            icon: const Icon(Icons.keyboard, color: RM.inkSoft),
            onPressed: onTypeManually,
          ),
          IconButton(
            tooltip: 'Permissions',
            icon: const Icon(Icons.tune, color: RM.inkSoft),
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.tasks,
    required this.now,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  final List<Task> tasks;
  final DateTime now;
  final void Function(Task) onTap;
  final void Function(Task) onToggle;
  final void Function(Task) onDelete;

  @override
  Widget build(BuildContext context) {
    // Flatten into rows with a day header injected whenever the label changes,
    // which keeps the whole thing one lazily built ListView.
    final rows = <Widget>[];
    String? lastLabel;
    for (final task in tasks) {
      final label = relativeDayLabel(task.dueAt, now);
      if (label != lastLabel) {
        rows.add(_DayHeader(label: label, when: task.dueAt, first: rows.isEmpty));
        lastLabel = label;
      } else {
        rows.add(const SizedBox(height: 6));
      }
      rows.add(
        _TaskRow(
          task: task,
          onTap: () => onTap(task),
          onToggle: () => onToggle(task),
          onDelete: () => onDelete(task),
        ),
      );
    }
    return ListView(
      // The bottom pad clears the mic bar so the last row is never trapped
      // under it.
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 120),
      children: rows,
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.label,
    required this.when,
    required this.first,
  });

  final String label;
  final DateTime when;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final date = formatDate(when);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, first ? 10 : 14, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label, style: RM.dayLabel),
          // A header that is already a date does not repeat itself.
          if (label != date) ...[
            const SizedBox(width: 8),
            Text(date, style: RM.dayDate),
          ],
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  final Task task;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rRow);

    return Dismissible(
      key: ValueKey(task.id),
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
                _DoneCircle(done: task.isDone, onTap: onToggle),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(formatTime(task.dueAt), style: RM.rowTime),
                          const SizedBox(width: 10),
                          Icon(
                            task.useAlarm ? Icons.alarm : Icons.notifications,
                            size: 18,
                            color: task.useAlarm ? RM.alarm : RM.accentLight,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: task.isDone
                            ? RM.rowTitle.copyWith(
                                color: RM.inkSoft,
                                decoration: TextDecoration.lineThrough,
                                decorationColor: RM.inkSoft,
                              )
                            : RM.rowTitle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  _meta(task),
                  softWrap: false,
                  style: task.useAlarm
                      ? RM.rowMeta.copyWith(
                          color: RM.alarm,
                          fontWeight: FontWeight.w600,
                        )
                      : RM.rowMeta,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// An alarm says so out loud, a notification just states its lead time.
  static String _meta(Task task) {
    final lead = formatLead(task.reminderMinutesBefore);
    if (!task.useAlarm) return lead;
    return 'Alarm · ${lead.replaceAll(' before', '')}';
  }
}

class _DoneCircle extends StatelessWidget {
  const _DoneCircle({required this.done, required this.onTap});

  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? RM.accent : Colors.transparent,
          border: done ? null : Border.all(color: RM.inkSoft, width: 2),
        ),
        child: done
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}


/// Four tabs with the microphone docked in the middle.
///
/// The mic is raised out of the bar rather than sitting in it as a fifth tab.
/// The design rule this app is built on is that the mic is the primary action,
/// and a flat fifth tab would make it a peer of Insights. Raised and filled, it
/// still outranks everything beside it while giving back the vertical space the
/// old floating button cost.
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.index,
    required this.onSelect,
    required this.onVoice,
  });

  static const double barHeight = 72;
  static const double micSize = 60;

  final int index;
  final void Function(int) onSelect;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // Room above the bar for the half of the mic that overhangs it.
      height: barHeight + micSize / 2,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: barHeight,
              color: RM.surface,
              child: Row(
                children: [
                  _NavItem(
                    icon: Icons.notifications_active,
                    label: 'Reminders',
                    selected: index == 0,
                    onTap: () => onSelect(0),
                  ),
                  _NavItem(
                    icon: Icons.fitness_center,
                    label: 'Workouts',
                    selected: index == 1,
                    onTap: () => onSelect(1),
                  ),
                  // The gap the mic sits in, sized so no label slides under it.
                  const SizedBox(width: micSize + 16),
                  _NavItem(
                    icon: Icons.sticky_note_2,
                    label: 'Notes',
                    selected: index == 2,
                    onTap: () => onSelect(2),
                  ),
                  _NavItem(
                    icon: Icons.insights,
                    label: 'Insights',
                    selected: index == 3,
                    onTap: () => onSelect(3),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            child: Semantics(
              button: true,
              label: 'Speak a reminder, note or gym check in',
              child: GestureDetector(
                onTap: onVoice,
                child: Container(
                  width: micSize,
                  height: micSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: RM.accent,
                    // The ring separates the mic from the bar behind it, so it
                    // reads as sitting on top rather than punched into it.
                    border: Border.all(color: RM.bg, width: 4),
                    boxShadow: [
                      BoxShadow(
                        color: RM.accent.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.mic, size: 28, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? RM.accentContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                icon,
                size: 22,
                color: selected ? RM.accentBright : RM.inkMid,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              // The bar is a fixed 72 high, so the label never wraps into it.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: selected
                  ? RM.rowMeta.copyWith(
                      color: RM.ink,
                      fontWeight: FontWeight.w700,
                    )
                  : RM.rowMeta.copyWith(color: RM.inkMid),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the strip needs to draw a live workout.
///
/// Workouts are not built yet, so this is a view model owned by the strip
/// rather than a domain model, and the strip draws nothing until something
/// real can be passed in.
@immutable
class RunningSessionView {
  const RunningSessionView({required this.name, required this.startedAt});

  final String name;
  final DateTime startedAt;
}

class RunningSessionStrip extends StatelessWidget {
  const RunningSessionStrip({super.key, required this.session, this.onTap});

  final RunningSessionView? session;

  /// Jumps to the Workouts tab. Optional so the strip stays usable in a
  /// context where there is nowhere to go.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    if (session == null) return const SizedBox.shrink();
    final strip = _RunningSession(session: session);
    if (onTap == null) return strip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: strip,
    );
  }
}

class _RunningSession extends StatefulWidget {
  const _RunningSession({required this.session});

  final RunningSessionView session;

  @override
  State<_RunningSession> createState() => _RunningSessionState();
}

class _RunningSessionState extends State<_RunningSession>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
    lowerBound: 0.3,
    upperBound: 1,
    value: 1,
  );
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
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

  String _elapsed() {
    var seconds = DateTime.now().difference(widget.session.startedAt).inSeconds;
    if (seconds < 0) seconds = 0;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: RM.session,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
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
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.session.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RM.dayLabel.copyWith(
                    fontSize: 13,
                    color: RM.accentBright,
                  ),
                ),
                Text(
                  'Session running · since '
                  '${formatTime(widget.session.startedAt)}',
                  style: RM.rowMeta.copyWith(
                    fontSize: 11,
                    color: RM.accentLight,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _elapsed(),
            style: RM.rowTime.copyWith(fontSize: 18, color: RM.accentBright),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mic_none, size: 64, color: RM.line),
            const SizedBox(height: 16),
            Text('Nothing scheduled', style: RM.sheetTitle),
            const SizedBox(height: 8),
            Text(
              'Tap the microphone and say what you need to remember.',
              textAlign: TextAlign.center,
              style: RM.body,
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: RM.field,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: RM.alarm),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: RM.body)),
        ],
      ),
    );
  }
}
