import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/food_entry.dart';
import '../services/gemini_client.dart';
import 'design.dart';
import 'format.dart';

/// Shows the food sheet and returns the entry to save, or null if dismissed.
///
/// The same sheet serves three jobs: confirming what Gemini heard, editing an
/// entry, and adding one by hand. They differ only in what seeds the fields, so
/// they share one form rather than three that drift apart.
Future<FoodEntry?> showFoodEditor(
  BuildContext context, {
  FoodEntry? existing,
  FoodIntent? parsed,
  required int shakeGrams,
  required DateTime day,
}) {
  return showModalBottomSheet<FoodEntry>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: RM.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RM.rSheet)),
    ),
    builder: (context) => _FoodEditorSheet(
      existing: existing,
      parsed: parsed,
      shakeGrams: shakeGrams,
      day: day,
    ),
  );
}

/// How much one tap of the stepper is worth. Five is the smallest step this
/// diary can honestly claim: nobody knows their lunch to the gram.
const int _step = 5;

class _FoodEditorSheet extends StatefulWidget {
  const _FoodEditorSheet({
    this.existing,
    this.parsed,
    required this.shakeGrams,
    required this.day,
  });

  final FoodEntry? existing;
  final FoodIntent? parsed;
  final int shakeGrams;
  final DateTime day;

  @override
  State<_FoodEditorSheet> createState() => _FoodEditorSheetState();
}

class _FoodEditorSheetState extends State<_FoodEditorSheet> {
  late final TextEditingController _description;
  late final TextEditingController _gramsField;
  late int _grams;
  late bool _estimated;
  late DateTime _eatenAt;
  late bool _hasDescription;

  bool get _isConfirming => widget.parsed != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final parsed = widget.parsed;

    _description = TextEditingController(
      text: existing?.description ?? parsed?.description ?? '',
    );

    if (existing != null) {
      _grams = FoodEntry.clampGrams(existing.proteinGrams);
      _estimated = existing.estimated;
      _eatenAt = existing.eatenAt;
    } else {
      _seedGrams(parsed);
      _eatenAt = _defaultTime();
    }

    _gramsField = TextEditingController(text: '$_grams');
    _gramsField.addListener(_onGramsTyped);

    _hasDescription = _description.text.trim().isNotEmpty;
    // Only rebuilds when the description crosses between empty and non empty,
    // rather than on every keystroke, since that flip is all the Save button
    // cares about.
    _description.addListener(() {
      final has = _description.text.trim().isNotEmpty;
      if (has != _hasDescription && mounted) {
        setState(() => _hasDescription = has);
      }
    });
  }

  /// The whole point of this sheet.
  ///
  /// A number the user said is theirs and is not marked as a guess. "A protein
  /// shake" resolves to the figure they configured, which is also theirs. Only
  /// when neither applies does the app admit it is guessing, and then it seeds
  /// nothing rather than inventing a number that would look like a measurement.
  void _seedGrams(FoodIntent? parsed) {
    final stated = parsed?.proteinGrams;
    if (stated != null) {
      _grams = FoodEntry.clampGrams(stated);
      _estimated = false;
      return;
    }
    if (parsed != null && parsed.isShake) {
      _grams = FoodEntry.clampGrams(widget.shakeGrams);
      _estimated = false;
      return;
    }
    _grams = 0;
    _estimated = true;
  }

  /// Now on the day being shown, midday on any other. A past day has no useful
  /// clock reading, and midday sorts a backfilled meal somewhere sensible.
  DateTime _defaultTime() {
    final now = DateTime.now();
    final day = widget.day;
    final isToday =
        day.year == now.year && day.month == now.month && day.day == now.day;
    if (isToday) return now;
    return DateTime(day.year, day.month, day.day, 12);
  }

  @override
  void dispose() {
    _description.dispose();
    _gramsField.dispose();
    super.dispose();
  }

  void _onGramsTyped() {
    final typed = int.tryParse(_gramsField.text.trim());
    if (typed == null) {
      // Mid edit, with the field cleared. Held at zero without rewriting the
      // text, which would fight the caret while they type the next digit.
      if (_grams != 0) _setGrams(0, rewrite: false);
      return;
    }
    _setGrams(typed);
  }

  /// [rewrite] pushes the clamped value back into the field, which is what the
  /// stepper needs and what catches a typed number past the ceiling.
  void _setGrams(int value, {bool rewrite = true}) {
    final clamped = FoodEntry.clampGrams(value);
    setState(() {
      // Only a changed number makes this the user's own figure. The field's
      // listener also fires when the caret merely moves, and putting a caret
      // in a box is not the user standing behind the figure in it.
      if (clamped != _grams) _estimated = false;
      _grams = clamped;
    });

    if (!rewrite) return;
    final text = '$clamped';
    if (_gramsField.text == text) return;
    _gramsField.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_eatenAt),
      builder: (context, child) => Theme(data: RM.theme(), child: child!),
    );
    if (picked == null) return;
    setState(() {
      // The date stays whatever the entry already carried, so changing the
      // clock never quietly moves a meal to another day.
      _eatenAt = DateTime(
        _eatenAt.year,
        _eatenAt.month,
        _eatenAt.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  void _save() {
    final description = _description.text.trim();
    if (description.isEmpty) return;

    final existing = widget.existing;
    final entry = existing == null
        ? FoodEntry(
            description: description,
            proteinGrams: _grams,
            eatenAt: _eatenAt,
            estimated: _estimated,
          )
        : existing.copyWith(
            description: description,
            proteinGrams: _grams,
            eatenAt: _eatenAt,
            estimated: _estimated,
          );
    Navigator.of(context).pop(entry);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();

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
          spacing: 18,
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
              _isConfirming ? 'HEARD AS' : 'FOOD',
              style: RM.label.copyWith(fontSize: 13),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Plain text on the sheet, with no box drawn around it. What
                // was eaten is the document here, not one field of a form.
                TextField(
                  controller: _description,
                  autofocus: !_isConfirming && widget.existing == null,
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
                    hintText: 'What did you eat?',
                    hintStyle: RM.sheetTitle.copyWith(color: RM.inkSoft),
                  ),
                ),
                const SizedBox(height: 12),
                Container(height: 1, color: RM.line),
              ],
            ),
            _GramsCard(
              controller: _gramsField,
              grams: _grams,
              onStep: (delta) => _setGrams(_grams + delta),
            ),
            if (_estimated)
              const _NoticeRow(
                icon: Icons.help_outline,
                text: 'I could not tell how much protein that is. Put in your '
                    'own number and it stops being a guess.',
                color: RM.accentLight,
              ),
            _TimeRow(when: _eatenAt, now: now, onTap: _pickTime),
            _SaveButton(onTap: _hasDescription ? _save : null),
          ],
        ),
      ),
    );
  }
}

/// The number, with a stepper either side of it.
///
/// Typing is allowed because the user often knows the figure, and the stepper
/// is there because they often only know it to within a scoop.
class _GramsCard extends StatelessWidget {
  const _GramsCard({
    required this.controller,
    required this.grams,
    required this.onStep,
  });

  final TextEditingController controller;
  final int grams;
  final void Function(int delta) onStep;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
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
                Text('PROTEIN', style: RM.label),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: TextField(
                        controller: controller,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: RM.fieldValueBig,
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
                    ),
                    const SizedBox(width: 6),
                    Text('g', style: RM.fieldValue.copyWith(color: RM.inkSoft)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _StepButton(
            icon: Icons.remove,
            onTap: grams <= 0 ? null : () => onStep(-_step),
          ),
          const SizedBox(width: 8),
          _StepButton(
            icon: Icons.add,
            onTap: grams >= FoodEntry.maxGramsPerEntry
                ? null
                : () => onStep(_step),
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  /// Null at the floor or the ceiling, which is what draws the button dead.
  final VoidCallback? onTap;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: RM.sheet,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 22,
            color: enabled ? RM.accentBright : RM.line,
          ),
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.when, required this.now, required this.onTap});

  final DateTime when;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rField);
    return Material(
      color: RM.field,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              const Icon(Icons.schedule, size: 20, color: RM.inkSoft),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  formatWhen(when, now),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RM.dayLabel.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text('Change', style: RM.chip.copyWith(color: RM.accentLight)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onTap});

  /// Null while there is nothing written down. A button that looks live but
  /// does nothing when tapped reads as a broken app, so it is drawn dead as
  /// well as being dead.
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
              style:
                  enabled ? RM.button : RM.button.copyWith(color: RM.inkSoft),
            ),
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
