import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backup_service.dart';
import 'design.dart';
import 'format.dart';

/// Saving a backup and restoring one.
///
/// The screen's whole job is to make sure nobody restores a backup without
/// first seeing what is in it and what it will do to what they already have.
/// Hence the counts before the choice, the two options spelled out in words
/// rather than as a switch, and the second confirmation on the one that
/// deletes data.
class BackupPage extends StatefulWidget {
  const BackupPage({
    super.key,
    required this.service,
    required this.onRestored,
  });

  final BackupService service;

  /// Called after a successful restore so the host can reload everything and
  /// put the reminders back in front of the OS. The restored rows have new
  /// ids, so nothing that was scheduled before still matches.
  final Future<void> Function() onRestored;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  BackupSummary? _totals;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _loadTotals();
  }

  Future<void> _loadTotals() async {
    try {
      final totals = await widget.service.currentTotals();
      if (!mounted) return;
      setState(() => _totals = totals);
    } on Object catch (e) {
      _say('Could not count what is on this phone. $e', isError: true);
    }
  }

  void _say(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = isError;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final file = await widget.service.exportToFile();
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          subject: 'RMIND backup',
        ),
      );

      // Android often cannot say which app took the file, so only an outright
      // dismissal counts as "not saved". Claiming success either way would be
      // the one lie this screen must never tell.
      if (result.status == ShareResultStatus.dismissed) {
        _say('Nothing was saved. Tap Save a backup again and pick where the '
            'file should go.');
      } else {
        _say('Backup saved: ${_contents(_totals)}.');
      }
    } on BackupException catch (e) {
      _say(e.message, isError: true);
    } on Object catch (e) {
      _say('The backup could not be written. $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Pick a RMIND backup',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null) return;

      final String json;
      try {
        // Read as bytes rather than by path: on Android the picker hands back
        // a content URI that is not a file this app can open by name.
        json = utf8.decode(await picked.readAsBytes());
      } on FormatException {
        _say(
          '"${picked.name}" is not readable text, so it is not a RMIND backup.',
          isError: true,
        );
        return;
      }

      // Nothing is written until this has read the whole file, so the counts
      // below are what a restore would actually put back.
      final summary = await widget.service.inspect(json);
      if (!mounted) return;

      final replace = await _askWhatToDo(summary);
      if (replace == null || !mounted) return;
      if (replace) {
        final sure = await _confirmReplace(summary);
        if (!sure || !mounted) return;
      }

      final restored = await widget.service.restore(
        json,
        replaceExisting: replace,
      );

      // Past this line the rows are on the phone. A failure in the reload or
      // the reschedule is not a failed restore, and saying so would send the
      // user back to restore a second time, which in merge mode doubles
      // everything they just put back.
      try {
        await widget.onRestored();
        await _loadTotals();
        _say('Restored ${_contents(restored)}.');
      } on Object catch (e) {
        _say(
          'Restored ${_contents(restored)}, but RMIND could not finish '
          'reloading, so the reminders may not be back with the alarm clock '
          'yet. Close and reopen the app. $e',
          isError: true,
        );
      }
    } on BackupException catch (e) {
      _say(e.message, isError: true);
    } on Object catch (e) {
      _say('That file could not be restored. $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// True to replace, false to merge, null if the user backed out.
  Future<bool?> _askWhatToDo(BackupSummary backup) {
    final here = _totals;

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RM.sheet,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RM.rCard),
        ),
        title: Text('This backup holds', style: RM.sheetTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatRow(label: 'Reminders', value: backup.tasks),
              _StatRow(label: 'Workouts', value: backup.sessions),
              _StatRow(label: 'Notes', value: backup.notes),
              const SizedBox(height: 10),
              Text(_madeOn(backup), style: RM.rowMeta),
              const SizedBox(height: 20),
              Text('What should happen to what is on this phone?',
                  style: RM.body),
              const SizedBox(height: 12),
              _ChoiceTile(
                title: 'Merge into what is here',
                detail: 'Adds everything in the backup to this phone. '
                    'Nothing already here is deleted, so anything the backup '
                    'also holds ends up twice.',
                onTap: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: 10),
              _ChoiceTile(
                title: 'Replace everything',
                detail: here == null
                    ? 'Deletes everything on this phone first, then puts the '
                        'backup back. This cannot be undone.'
                    : 'Deletes the ${_contents(here)} on this phone first, '
                        'then puts the backup back. This cannot be undone.',
                onTap: () => Navigator.of(context).pop(true),
                danger: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: RM.inkMid),
            child: Text(
              'Cancel',
              style: RM.button.copyWith(fontSize: 14, color: RM.inkMid),
            ),
          ),
        ],
      ),
    );
  }

  /// The second look at an irreversible delete.
  Future<bool> _confirmReplace(BackupSummary backup) async {
    final here = _totals;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RM.sheet,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RM.rCard),
        ),
        title: Text(
          'Delete everything on this phone?',
          style: RM.sheetTitle.copyWith(color: RM.alarm),
        ),
        content: Text(
          here == null
              ? 'Everything on this phone is deleted and replaced by the '
                  '${_contents(backup)} in the backup. There is no undo.'
              : 'The ${_contents(here)} on this phone are deleted and '
                  'replaced by the ${_contents(backup)} in the backup. '
                  'There is no undo.',
          style: RM.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(foregroundColor: RM.inkMid),
            child: Text(
              'Keep what is here',
              style: RM.button.copyWith(fontSize: 14, color: RM.inkMid),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: RM.alarm,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(RM.rChip),
              ),
            ),
            child: Text(
              'Delete and restore',
              // The alarm colour is warm and light, so the label on top of it
              // is the background colour rather than white.
              style: RM.button.copyWith(fontSize: 14, color: RM.bg),
            ),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final totals = _totals;
    final message = _message;

    return Scaffold(
      backgroundColor: RM.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: RM.ink),
        title: Text('Backup', style: RM.screenTitle.copyWith(fontSize: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'A backup is a single file holding every reminder, workout and '
            'note on this phone. Nothing is stored anywhere else, so if the '
            'phone is lost or wiped, that file is the only way any of it '
            'comes back.',
            style: RM.body,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            decoration: BoxDecoration(
              color: RM.surface,
              borderRadius: BorderRadius.circular(RM.rCard),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ON THIS PHONE NOW', style: RM.label),
                const SizedBox(height: 8),
                if (totals == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: CircularProgressIndicator(color: RM.accentLight),
                    ),
                  )
                else ...[
                  _StatRow(label: 'Reminders', value: totals.tasks),
                  _StatRow(label: 'Workouts', value: totals.sessions),
                  _StatRow(label: 'Notes', value: totals.notes),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          _WideButton(
            label: 'Save a backup',
            icon: Icons.save_alt,
            enabled: !_busy,
            onPressed: _save,
          ),
          const SizedBox(height: 12),
          _WideButton(
            label: 'Restore from a backup',
            icon: Icons.settings_backup_restore,
            enabled: !_busy,
            onPressed: _restore,
            primary: false,
          ),
          if (message != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: RM.surface,
                borderRadius: BorderRadius.circular(RM.rRow),
              ),
              child: Text(
                message,
                style: _messageIsError
                    ? RM.body.copyWith(color: RM.alarm)
                    : RM.body,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "3 reminders, 1 workout and 12 notes", or "nothing" for an empty phone.
String _contents(BackupSummary? summary) {
  if (summary == null) return 'what is on this phone';

  final parts = <String>[
    _count(summary.tasks, 'reminder'),
    _count(summary.sessions, 'workout'),
    _count(summary.notes, 'note'),
  ];
  return '${parts[0]}, ${parts[1]} and ${parts[2]}';
}

String _count(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

String _madeOn(BackupSummary backup) {
  final made = backup.createdAt;
  final when = '${formatDate(made)} ${made.year} at ${formatTime(made)}';
  return backup.appVersion == BackupService.unknownVersion
      ? 'Made $when'
      : 'Made $when by RMIND ${backup.appVersion}';
}

/// One line of the count block: what it is on the left, how many on the right.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: RM.rowTitle.copyWith(fontSize: 16)),
          Text('$value', style: RM.fieldValue),
        ],
      ),
    );
  }
}

/// A full width action. Disabled states look disabled rather than merely
/// refusing to do anything, since both of these take a few seconds.
class _WideButton extends StatelessWidget {
  const _WideButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
    this.primary = true,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final foreground = primary ? Colors.white : RM.accentBright;

    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 20, color: enabled ? foreground : RM.inkSoft),
        label: Text(
          label,
          style: enabled
              ? RM.button.copyWith(color: foreground)
              : RM.button.copyWith(color: RM.inkSoft),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: primary ? RM.accent : RM.accentContainer,
          disabledBackgroundColor: RM.field,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
      ),
    );
  }
}

/// One of the two ways a restore can go, said in words. A segmented control
/// here would let someone destroy their data with a mis-tap.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.detail,
    required this.onTap,
    this.danger = false,
  });

  final String title;
  final String detail;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RM.field,
      borderRadius: BorderRadius.circular(RM.rRow),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RM.rRow),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: RM.rowTitle.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: danger ? RM.alarm : RM.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(detail, style: RM.body),
            ],
          ),
        ),
      ),
    );
  }
}
