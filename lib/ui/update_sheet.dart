import 'dart:io';

import 'package:flutter/material.dart';

import '../services/update_service.dart';
import 'design.dart';

/// Walks the whole update flow: check, download, hand over to the installer.
///
/// One sheet rather than a dialog per step, because every step here is the
/// same question in a different state and bouncing the user between surfaces
/// hides where they are in it.
Future<void> showUpdateSheet(
  BuildContext context, {
  required UpdateService service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: RM.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RM.rSheet)),
    ),
    builder: (context) => _UpdateSheet(service: service),
  );
}

enum _Step {
  checking,
  upToDate,
  available,
  downloading,
  ready,
  permission,
  failed,
}

/// How long the "Android will ask you" sentence stays alone on screen before
/// the installer is called. A system dialog that appears unannounced reads as
/// malware, and this is the whole reason the READY step exists.
const Duration _readPause = Duration(milliseconds: 900);

/// The release notes are the one thing here with no natural ceiling.
const double _notesMaxHeight = 180;

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.service});

  final UpdateService service;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  final ScrollController _notes = ScrollController();

  _Step _step = _Step.checking;
  ReleaseInfo? _release;
  File? _apk;
  String? _message;
  String? _installedLabel;

  /// Whole percent rather than a fraction, so a chunk that moves the bar by
  /// nothing does not rebuild the sheet.
  int _percent = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final label = await widget.service.currentVersionLabel();
    if (!mounted) return;
    setState(() => _installedLabel = label);
    await _check();
  }

  Future<void> _check() async {
    setState(() {
      _step = _Step.checking;
      _message = null;
      _percent = 0;
    });

    final status = await widget.service.check();
    if (!mounted) return;

    switch (status) {
      case UpToDate():
        setState(() => _step = _Step.upToDate);
      case UpdateAvailable(release: final release):
        setState(() {
          _release = release;
          _step = _Step.available;
        });
      case UpdateCheckFailed(message: final message):
        _fail(message);
    }
  }

  Future<void> _download() async {
    final release = _release;
    if (release == null) return;

    setState(() {
      _step = _Step.downloading;
      _percent = 0;
    });

    try {
      final apk = await widget.service.download(
        release,
        onProgress: _onProgress,
      );
      if (!mounted) return;
      _apk = apk;
      await _handOver();
    } on UpdateException catch (error) {
      if (!mounted) return;
      _fail(error.message);
    } on Exception catch (error) {
      if (!mounted) return;
      _fail('The download failed: $error');
    }
  }

  void _onProgress(double value) {
    if (!mounted) return;
    final percent = (value * 100).round();
    if (percent == _percent) return;
    setState(() => _percent = percent);
  }

  /// Everything between a finished download and the system installer.
  Future<void> _handOver() async {
    final apk = _apk;
    if (apk == null) return;

    if (!await widget.service.canInstall()) {
      if (!mounted) return;
      setState(() => _step = _Step.permission);
      return;
    }
    if (!mounted) return;

    setState(() => _step = _Step.ready);
    await Future<void>.delayed(_readPause);
    if (!mounted) return;

    final opened = await widget.service.install(apk);
    if (!mounted || opened) return;
    _fail(
      'Android would not open the installer. The download is saved, so '
      'trying again is safe.',
    );
  }

  Future<void> _requestPermission() async {
    await widget.service.requestInstallPermission();
    // Deliberately no re-check here: the settings screen is still in front of
    // the user, so the answer would be the stale one they just left behind.
  }

  void _fail(String message) {
    setState(() {
      _message = message;
      _step = _Step.failed;
    });
  }

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: RM.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          // The sheet gives way and scrolls rather than overflowing, which is
          // what a long release note in landscape would otherwise do.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _content(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content() {
    switch (_step) {
      case _Step.checking:
        return _checking();
      case _Step.upToDate:
        return _upToDate();
      case _Step.available:
        return _available();
      case _Step.downloading:
        return _downloading();
      case _Step.ready:
        return _ready();
      case _Step.permission:
        return _permission();
      case _Step.failed:
        return _failed();
    }
  }

  List<Widget> _checking() {
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: RM.accentLight,
            ),
          ),
          const SizedBox(width: 14),
          Flexible(
            child: Text('Checking for updates', style: RM.sheetTitle),
          ),
        ],
      ),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _upToDate() {
    return [
      const Icon(Icons.check_circle, size: 44, color: RM.accentLight),
      const SizedBox(height: 14),
      Text(
        'You are on the latest version',
        style: RM.sheetTitle,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 6),
      Text(
        'Version ${_installedLabel ?? 'unknown'}',
        style: RM.rowMeta,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 22),
      _SecondaryButton(label: 'Close', onPressed: _close),
    ];
  }

  List<Widget> _available() {
    final release = _release!;
    return [
      Text('Version ${release.version} is available', style: RM.sheetTitle),
      const SizedBox(height: 6),
      Text(
        '${_megabytes(release.apkBytes)} download'
        '${_installedLabel == null ? '' : ' · you have $_installedLabel'}',
        style: RM.rowMeta,
      ),
      if (release.notes.isNotEmpty) ...[
        const SizedBox(height: 16),
        Container(
          constraints: const BoxConstraints(maxHeight: _notesMaxHeight),
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            color: RM.field,
            borderRadius: BorderRadius.circular(RM.rField),
          ),
          child: Scrollbar(
            controller: _notes,
            child: SingleChildScrollView(
              controller: _notes,
              padding: const EdgeInsets.only(right: 6),
              child: Text(release.notes, style: RM.body),
            ),
          ),
        ),
      ],
      const SizedBox(height: 22),
      _PrimaryButton(label: 'Download and install', onPressed: _download),
    ];
  }

  List<Widget> _downloading() {
    final release = _release;
    return [
      Text(
        release == null ? 'Downloading' : 'Downloading ${release.version}',
        style: RM.sheetTitle,
      ),
      const SizedBox(height: 18),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: _percent / 100,
          minHeight: 6,
          color: RM.accentLight,
          backgroundColor: RM.field,
        ),
      ),
      const SizedBox(height: 10),
      Text('$_percent%', style: RM.rowMeta),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _ready() {
    return [
      const Icon(Icons.system_update_alt, size: 44, color: RM.accentLight),
      const SizedBox(height: 14),
      Text(
        'Android will ask you to confirm',
        style: RM.sheetTitle,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      Text(
        'The download is finished. Android now shows its own install screen, '
        'which RMIND cannot skip or answer for you. Tap Install there to '
        'finish, or Cancel to keep the version you have.',
        style: RM.body,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      // Cancelling Android's install dialog returns here with nothing to do.
      // Without these the sheet is a dead end and the only way out is to kill
      // the app, having already paid for the download.
      _PrimaryButton(label: 'Open the installer again', onPressed: _handOver),
      const SizedBox(height: 8),
      _SecondaryButton(
        label: 'Not now',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _permission() {
    return [
      const Icon(Icons.lock_outline, size: 44, color: RM.accentLight),
      const SizedBox(height: 14),
      Text(
        'Android needs your permission',
        style: RM.sheetTitle,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      Text(
        'Android only lets an app install other apps once you allow it. Open '
        'the settings screen, turn the permission on for RMIND, then come '
        'back here. The download is already saved.',
        style: RM.body,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 22),
      _PrimaryButton(
        label: 'Open the setting',
        onPressed: _requestPermission,
      ),
      const SizedBox(height: 10),
      _SecondaryButton(label: 'I have allowed it', onPressed: _handOver),
    ];
  }

  List<Widget> _failed() {
    return [
      const Icon(Icons.error_outline, size: 44, color: RM.alarm),
      const SizedBox(height: 14),
      Text(
        _message ?? 'The update could not be checked.',
        style: RM.body,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 22),
      _PrimaryButton(label: 'Retry', onPressed: _check),
      const SizedBox(height: 10),
      _SecondaryButton(label: 'Close', onPressed: _close),
    ];
  }
}

/// One decimal is as much precision as a download size can honestly claim.
String _megabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: RM.accentLight,
          foregroundColor: RM.onAccentDeep,
          textStyle: RM.button.copyWith(fontSize: 15),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(26)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: RM.inkMid,
          textStyle: RM.chip.copyWith(fontSize: 15),
          side: const BorderSide(color: RM.line),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(26)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}
