import 'package:flutter/material.dart';

import '../models/food_entry.dart';
import '../services/settings_store.dart';
import 'design.dart';

/// Lets the user set their own shake size and daily protein target.
///
/// Both numbers matter more than they look. The shake size is what the quick
/// add button records without asking, and the target is the denominator behind
/// every progress bar in the diary, so a wrong value here is wrong everywhere.
Future<void> showProteinSettings(
  BuildContext context, {
  required SettingsStore store,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: RM.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RM.rSheet)),
    ),
    builder: (context) => _ProteinSettingsSheet(store: store),
  );
}

class _ProteinSettingsSheet extends StatefulWidget {
  const _ProteinSettingsSheet({required this.store});

  final SettingsStore store;

  @override
  State<_ProteinSettingsSheet> createState() => _ProteinSettingsSheetState();
}

class _ProteinSettingsSheetState extends State<_ProteinSettingsSheet> {
  int _shake = FoodEntry.defaultShakeGrams;
  int _target = FoodEntry.defaultDailyTarget;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final shake = await widget.store.shakeGrams();
    final target = await widget.store.dailyProteinTarget();
    if (!mounted) return;
    setState(() {
      _shake = shake;
      _target = target;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await widget.store.setShakeGrams(_shake);
    await widget.store.setDailyProteinTarget(_target);
    if (!mounted) return;
    Navigator.of(context).pop();
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
      child: _loading
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: RM.accentLight),
              ),
            )
          : Column(
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
                Text('PROTEIN', style: RM.label.copyWith(fontSize: 13)),
                _Stepper(
                  label: 'One shake',
                  detail: 'What the quick add button logs.',
                  value: _shake,
                  step: 5,
                  // Never more than a single entry can hold, or the button
                  // would promise a number the diary quietly shrinks.
                  max: FoodEntry.maxGramsPerEntry,
                  onChanged: (v) => setState(() => _shake = v),
                ),
                _Stepper(
                  label: 'Daily target',
                  detail: 'Only a line to aim at, never a warning.',
                  value: _target,
                  step: 10,
                  max: 500,
                  onChanged: (v) => setState(() => _target = v),
                ),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: RM.accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: Text('Save', style: RM.button),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.detail,
    required this.value,
    required this.step,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String detail;
  final int value;
  final int step;
  final int max;
  final void Function(int) onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RM.field,
        borderRadius: BorderRadius.circular(RM.rField),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: RM.label),
                const SizedBox(height: 4),
                Text('$value g', style: RM.fieldValueBig),
                const SizedBox(height: 4),
                Text(detail, style: RM.body),
              ],
            ),
          ),
          _Round(
            icon: Icons.remove,
            onTap: value - step >= 1 ? () => onChanged(value - step) : null,
          ),
          const SizedBox(width: 8),
          _Round(
            icon: Icons.add,
            onTap: value + step <= max ? () => onChanged(value + step) : null,
          ),
        ],
      ),
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? RM.accentContainer : RM.surface,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? RM.accentBright : RM.inkSoft,
          ),
        ),
      ),
    );
  }
}
