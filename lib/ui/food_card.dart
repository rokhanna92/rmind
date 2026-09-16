import 'package:flutter/material.dart';

import 'design.dart';

/// Protein at a glance, sitting at the top of the Workouts tab.
///
/// Training and eating are the same habit to this user, so the diary announces
/// itself where the gym already is rather than hiding behind another tab. The
/// card shows the day's total, how far off the target it is, and the one tap
/// that covers most of the logging.
class FoodCard extends StatelessWidget {
  const FoodCard({
    super.key,
    required this.todayGrams,
    required this.target,
    required this.shakeGrams,
    required this.onAddShake,
    required this.onOpen,
  });

  final int todayGrams;
  final int target;

  /// The user's own figure for one shake, not a guess by the app.
  final int shakeGrams;

  final Future<void> Function() onAddShake;

  /// Opens the full diary.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rCard);

    return Material(
      color: RM.surface,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ProteinSummary(
            todayGrams: todayGrams,
            target: target,
            trailing: ShakePill(grams: shakeGrams, onAdd: onAddShake),
          ),
        ),
      ),
    );
  }
}

/// The day's protein readout: a label, the total against the target, and a bar.
///
/// Shared by [FoodCard] and the diary page rather than written twice, so the
/// small card and the full page can never disagree about how far along the day
/// is. The page passes larger sizes; nothing else differs.
class ProteinSummary extends StatelessWidget {
  const ProteinSummary({
    super.key,
    required this.todayGrams,
    required this.target,
    this.totalSize = 26,
    this.barHeight = 6,
    this.trailing,
  });

  final int todayGrams;
  final int target;

  /// Size of the total, which is the only thing on this widget that changes
  /// between the card and the page.
  final double totalSize;

  final double barHeight;

  /// Sits to the right of the total, normally the quick add pill.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // Past the target the bar stays full rather than overflowing, and the total
    // is tinted rather than reddened: eating enough protein is not a failure
    // state, so nothing here is allowed to read like a warning.
    final reached = target > 0 && todayGrams >= target;
    final fraction = target > 0
        ? (todayGrams / target).clamp(0.0, 1.0)
        : (todayGrams > 0 ? 1.0 : 0.0);

    final trailing = this.trailing;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Protein today', style: RM.label),
                  const SizedBox(height: 6),
                  // One rich line rather than a Row, so the target sits on the
                  // total's baseline for free, and scaled down rather than
                  // wrapped once the user turns their text size up on a 360dp
                  // phone.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$todayGrams g',
                            style: RM.rowTime.copyWith(
                              fontSize: totalSize,
                              color: reached ? RM.accentLight : RM.ink,
                            ),
                          ),
                          TextSpan(
                            text: '  of $target g',
                            style: RM.rowMeta,
                          ),
                        ],
                      ),
                      softWrap: false,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing,
            ],
          ],
        ),
        SizedBox(height: barHeight + 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(barHeight / 2),
          child: SizedBox(
            height: barHeight,
            child: ColoredBox(
              color: RM.field,
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: const ColoredBox(color: RM.accentLight),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One tap for the shake the user drinks several times a week.
///
/// Speaking a whole sentence for the most repeated entry there is would be
/// worse than a tap, and the grams are printed on the pill so the number being
/// added is never a surprise.
class ShakePill extends StatefulWidget {
  const ShakePill({super.key, required this.grams, required this.onAdd});

  final int grams;
  final Future<void> Function() onAdd;

  @override
  State<ShakePill> createState() => _ShakePillState();
}

class _ShakePillState extends State<ShakePill> {
  bool _busy = false;

  /// Taps are dropped while the write is in flight. The whole point of this
  /// control is that it is quick to hit, which also makes it easy to hit twice
  /// and log the shake twice.
  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onAdd();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rField);

    return Material(
      color: _busy
          ? RM.accentContainer.withValues(alpha: 0.5)
          : RM.accentContainer,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: _busy ? null : _add,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '+ shake',
                softWrap: false,
                style: RM.chip.copyWith(
                  fontWeight: FontWeight.w700,
                  color: RM.accentBright,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${widget.grams} g',
                softWrap: false,
                style: RM.label.copyWith(
                  fontSize: 11,
                  color: RM.accentLight,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
