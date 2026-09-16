import 'package:flutter/material.dart';

import '../services/permissions_service.dart';
import '../services/api_key_store.dart';
import '../services/backup_service.dart';
import '../services/settings_store.dart';
import '../services/update_service.dart';
import 'api_key_page.dart';
import 'backup_page.dart';
import 'protein_settings_sheet.dart';
import 'design.dart';
import 'update_sheet.dart';

/// Walks through the Android grants this app needs to actually work.
///
/// Shown automatically on launch while anything critical is missing, and
/// reachable later from the settings icon. Exact alarms and battery
/// optimisation are the two that silently break reminders, so they get plain
/// language explanations rather than a permission name.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.permissions,
    this.apiKeys,
    this.updates,
    this.backups,
    this.settings,
    this.onRestored,
  });

  final PermissionsService permissions;

  /// Null hides the key and update rows, which is what the first run wants:
  /// nothing but permissions until the app is usable at all.
  final ApiKeyStore? apiKeys;
  final UpdateService? updates;
  final BackupService? backups;
  final SettingsStore? settings;

  /// Reloads the app after a restore has replaced what is in the database.
  final Future<void> Function()? onRestored;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  PermissionReport? _report;
  String? _version;
  String? _proteinDetail;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadVersion();
    _loadProtein();
  }

  Future<void> _loadVersion() async {
    final updates = widget.updates;
    if (updates == null) return;
    final label = await updates.currentVersionLabel();
    if (!mounted) return;
    setState(() => _version = label);
  }

  Future<void> _loadProtein() async {
    final store = widget.settings;
    if (store == null) return;
    final shake = await store.shakeGrams();
    final target = await store.dailyProteinTarget();
    if (!mounted) return;
    setState(() => _proteinDetail = 'Shake $shake g, target $target g a day.');
  }

  Future<void> _refresh() async {
    final report = await widget.permissions.checkAll();
    if (!mounted) return;
    setState(() => _report = report);
  }

  Future<void> _request(Future<bool> Function() request) async {
    await request();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;

    return Scaffold(
      backgroundColor: RM.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: RM.ink),
        title: Text('Setup', style: RM.screenTitle.copyWith(fontSize: 22)),
      ),
      body: report == null
          ? const Center(
              child: CircularProgressIndicator(color: RM.accentLight),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'RMIND needs these to hear you and to reach you on time.',
                  style: RM.body,
                ),
                const SizedBox(height: 16),
                _PermissionTile(
                  icon: Icons.mic,
                  title: 'Microphone',
                  detail: 'To hear the reminder you speak.',
                  granted: report.microphone,
                  critical: true,
                  onGrant: () =>
                      _request(widget.permissions.requestMicrophone),
                ),
                _PermissionTile(
                  icon: Icons.notifications,
                  title: 'Notifications',
                  detail: 'To show the reminder when it is due.',
                  granted: report.notifications,
                  critical: true,
                  onGrant: () =>
                      _request(widget.permissions.requestNotifications),
                ),
                _PermissionTile(
                  icon: Icons.alarm,
                  title: 'Exact alarms',
                  detail: 'Without this Android is free to delay a reminder '
                      'by minutes or hours to save battery.',
                  granted: report.exactAlarms,
                  critical: true,
                  onGrant: () =>
                      _request(widget.permissions.requestExactAlarms),
                ),
                _PermissionTile(
                  icon: Icons.battery_saver,
                  title: 'Battery saver',
                  detail: 'Strongly recommended. Battery optimisation is the '
                      'usual reason a reminder never arrives.',
                  granted: report.batteryOptimisationDisabled,
                  critical: false,
                  onGrant: () => _request(
                    widget.permissions.requestDisableBatteryOptimisation,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: report.allCritical
                        ? () => Navigator.of(context).maybePop()
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: RM.accent,
                      disabledBackgroundColor: RM.field,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: Text(
                      report.allCritical
                          ? 'Done'
                          : 'Grant the required permissions to continue',
                      style: report.allCritical
                          ? RM.button
                          : RM.button.copyWith(color: RM.inkSoft),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _refresh,
                  style: TextButton.styleFrom(foregroundColor: RM.accentLight),
                  child: Text(
                    'Re-check',
                    style: RM.button.copyWith(
                      fontSize: 14,
                      color: RM.accentLight,
                    ),
                  ),
                ),
                if (widget.apiKeys != null ||
                    widget.updates != null ||
                    widget.backups != null ||
                    widget.settings != null) ...[
                  const SizedBox(height: 28),
                  Text('App', style: RM.dayLabel),
                  const SizedBox(height: 12),
                  if (widget.apiKeys != null)
                    _AppRow(
                      icon: Icons.key,
                      title: 'Gemini key',
                      detail: 'Kept on this phone. Voice parsing needs it.',
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                ApiKeyPage(store: widget.apiKeys!),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  if (widget.settings != null)
                    _AppRow(
                      icon: Icons.local_drink,
                      title: 'Protein',
                      detail: _proteinDetail ?? 'Shake size and daily target.',
                      onTap: () async {
                        await showProteinSettings(
                          context,
                          store: widget.settings!,
                        );
                        await _loadProtein();
                      },
                    ),
                  if (widget.backups != null)
                    _AppRow(
                      icon: Icons.save_alt,
                      title: 'Backup',
                      detail: 'Save everything to a file, or restore it.',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BackupPage(
                            service: widget.backups!,
                            onRestored: widget.onRestored ?? () async {},
                          ),
                        ),
                      ),
                    ),
                  if (widget.updates != null)
                    _AppRow(
                      icon: Icons.system_update,
                      title: 'Check for updates',
                      detail: _version ?? 'Looking up this version...',
                      onTap: () =>
                          showUpdateSheet(context, service: widget.updates!),
                    ),
                ],
              ],
            ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.granted,
    required this.critical,
    required this.onGrant,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool granted;
  final bool critical;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RM.surface,
        borderRadius: BorderRadius.circular(RM.rRow),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 24,
            color: granted ? RM.accentLight : RM.inkSoft,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wrap rather than Row: both children sized to their content,
                // and the tag drops to its own line when the text scale grows.
                // A Row needed both children Flexible to survive a large text
                // scale, which then split the width evenly and clipped the
                // title to "Battery sav..." at ordinary size. Wrapping loses
                // neither word at either extreme.
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      title,
                      style: RM.rowTitle.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!critical) Text('optional', style: RM.label),
                  ],
                ),
                const SizedBox(height: 2),
                Text(detail, style: RM.body),
              ],
            ),
          ),
          const SizedBox(width: 14),
          if (granted)
            const Icon(Icons.check_circle, size: 24, color: RM.accentLight)
          else
            SizedBox(
              height: 40,
              child: FilledButton(
                onPressed: onGrant,
                style: FilledButton.styleFrom(
                  backgroundColor: RM.accentContainer,
                  foregroundColor: RM.accentBright,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: Text(
                  'Grant',
                  style: RM.button.copyWith(
                    fontSize: 14,
                    color: RM.accentBright,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A tappable row for the app level settings under the permission list.
class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: RM.surface,
        borderRadius: BorderRadius.circular(RM.rRow),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(RM.rRow),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon, size: 24, color: RM.inkSoft),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: RM.rowTitle.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(detail, style: RM.body),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 22, color: RM.inkSoft),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
