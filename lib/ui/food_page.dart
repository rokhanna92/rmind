import 'package:flutter/material.dart';

import '../models/food_entry.dart';
import 'design.dart';
import 'food_card.dart';
import 'format.dart';

/// One day of eating, and nothing else.
///
/// The diary is deliberately a day at a time. The habit being built is a daily
/// one, so a running list across weeks would bury the only number that matters
/// today under every number that already happened.
class FoodPage extends StatelessWidget {
  const FoodPage({
    super.key,
    required this.entries,
    required this.day,
    required this.todayGrams,
    required this.target,
    required this.shakeGrams,
    required this.onAddShake,
    required this.onEdit,
    required this.onDelete,
    required this.onChangeDay,
  });

  /// The shown day's entries, newest first.
  final List<FoodEntry> entries;

  /// The day being shown.
  final DateTime day;

  final int todayGrams;
  final int target;
  final int shakeGrams;

  final Future<void> Function() onAddShake;
  final Future<void> Function(FoodEntry) onEdit;
  final Future<void> Function(FoodEntry) onDelete;
  final void Function(DateTime) onChangeDay;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // Nothing can be logged in the future, so today is the end of the road.
    final atToday = daysBetween(now, day) >= 0;

    return Scaffold(
      backgroundColor: RM.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: RM.ink),
        title: Text('Protein', style: RM.screenTitle.copyWith(fontSize: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          _DaySwitcher(
            day: day,
            now: now,
            // Stepped by calendar arithmetic rather than by subtracting a
            // Duration, so a daylight saving day is still one day wide.
            onBack: () => onChangeDay(
              DateTime(day.year, day.month, day.day - 1),
            ),
            onForward: atToday
                ? null
                : () => onChangeDay(DateTime(day.year, day.month, day.day + 1)),
          ),
          const SizedBox(height: 16),
          ProteinSummary(
            todayGrams: todayGrams,
            target: target,
            totalSize: 34,
            barHeight: 10,
            trailing: ShakePill(grams: shakeGrams, onAdd: onAddShake),
          ),
          const SizedBox(height: 24),
          if (entries.isEmpty)
            const _EmptyDay()
          else
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _EntryRow(
                entry: entries[i],
                onTap: () => onEdit(entries[i]),
                onDelete: () => onDelete(entries[i]),
              ),
            ],
        ],
      ),
    );
  }
}

/// Yesterday, today, and no further.
class _DaySwitcher extends StatelessWidget {
  const _DaySwitcher({
    required this.day,
    required this.now,
    required this.onBack,
    required this.onForward,
  });

  final DateTime day;
  final DateTime now;
  final VoidCallback onBack;

  /// Null on today, which is what draws the chevron dead.
  final VoidCallback? onForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Chevron(icon: Icons.chevron_left, onTap: onBack),
        Expanded(
          child: Text(
            relativeDayLabel(day, now),
            textAlign: TextAlign.center,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: RM.dayLabel,
          ),
        ),
        _Chevron(icon: Icons.chevron_right, onTap: onForward),
      ],
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 26, color: enabled ? RM.ink : RM.line),
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  final FoodEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RM.rRow);

    return Dismissible(
      // Identity rather than the id: an entry that has not been written yet
      // has no id, and two of those would collide on a null key.
      key: ObjectKey(entry),
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: RM.rowTitle,
                      ),
                      const SizedBox(height: 4),
                      Text(formatTime(entry.eatenAt), style: RM.rowMeta),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _Grams(entry: entry),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The number on the right of a row.
///
/// An estimate is drawn as one: tilde, softer ink, and the word underneath. A
/// figure the user said out loud is their own and gets none of that, because
/// marking it as a guess would be the app calling them wrong.
class _Grams extends StatelessWidget {
  const _Grams({required this.entry});

  final FoodEntry entry;

  @override
  Widget build(BuildContext context) {
    final estimated = entry.estimated;
    final value = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${estimated ? '~' : ''}${entry.proteinGrams} g',
          softWrap: false,
          style: RM.rowTime.copyWith(
            fontSize: 20,
            color: estimated ? RM.inkMid : RM.ink,
          ),
        ),
        if (estimated) ...[
          const SizedBox(height: 2),
          Text('estimated', softWrap: false, style: RM.label),
        ],
      ],
    );

    if (!estimated) return value;
    return Tooltip(
      message: 'RMIND guessed this. Tap the row to put in your own number.',
      child: value,
    );
  }
}

/// A day with nothing in it.
///
/// Teaches the two sentences the feature listens for, including the one where
/// the user supplies the number themselves, rather than inventing data to fill
/// the screen.
class _EmptyDay extends StatelessWidget {
  const _EmptyDay();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.restaurant, size: 56, color: RM.line),
          const SizedBox(height: 28),
          Text(
            'Nothing logged',
            textAlign: TextAlign.center,
            style: RM.sheetTitle.copyWith(fontSize: 22),
          ),
          const SizedBox(height: 8),
          Text(
            'Say what you ate. A rough number is enough, and your own number '
            'is better than mine.',
            textAlign: TextAlign.center,
            style: RM.body,
          ),
          const SizedBox(height: 28),
          const _ExampleCard(
            label: 'TRY SAYING',
            phrase: '“Had a protein shake”',
          ),
          const SizedBox(height: 10),
          const _ExampleCard(
            label: 'OR',
            phrase: '“Four eggs, roughly 24 grams of protein”',
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
