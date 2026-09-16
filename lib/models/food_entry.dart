/// Something eaten, and roughly how much protein was in it.
///
/// The point of this diary is the daily habit, not precision. Nobody weighs
/// their eggs, so the numbers here are approximations by design and the app
/// says so rather than presenting a guess as a measurement.
class FoodEntry {
  const FoodEntry({
    this.id,
    required this.description,
    required this.proteinGrams,
    required this.eatenAt,
    this.estimated = true,
  });

  /// What one scoop is worth, until the user says otherwise. A shake is the
  /// most repeated entry there is, so it gets a known value rather than being
  /// guessed at every time.
  static const int defaultShakeGrams = 30;

  /// A day's target, until the user sets their own.
  static const int defaultDailyTarget = 140;

  /// Nothing sensible is a single item, so anything past this is almost
  /// certainly the model misreading a quantity.
  static const int maxGramsPerEntry = 300;

  final int? id;

  /// In the user's own words: "Protein shake", "4 eggs", "chicken and rice".
  final String description;

  final int proteinGrams;
  final DateTime eatenAt;

  /// False when the user said the number out loud, true when it was inferred.
  ///
  /// Worth keeping separate: "4 eggs, roughly 24 grams" is the user's own
  /// figure and should not be marked as the app's guess, while "chicken and
  /// rice" is the app guessing and the UI should admit it.
  final bool estimated;

  FoodEntry copyWith({
    int? id,
    String? description,
    int? proteinGrams,
    DateTime? eatenAt,
    bool? estimated,
  }) {
    return FoodEntry(
      id: id ?? this.id,
      description: description ?? this.description,
      proteinGrams: proteinGrams ?? this.proteinGrams,
      eatenAt: eatenAt ?? this.eatenAt,
      estimated: estimated ?? this.estimated,
    );
  }

  /// Clamped rather than rejected. A nonsense figure should not throw away the
  /// entry the user just dictated, and zero is legal: plenty of food has no
  /// protein worth recording but is still worth writing down.
  static int clampGrams(int grams) {
    if (grams < 0) return 0;
    if (grams > maxGramsPerEntry) return maxGramsPerEntry;
    return grams;
  }

  /// Times are stored as UTC epoch milliseconds, matching every other table.
  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'description': description,
      'protein_grams': proteinGrams,
      'eaten_at': eatenAt.toUtc().millisecondsSinceEpoch,
      'estimated': estimated ? 1 : 0,
    };
  }

  factory FoodEntry.fromMap(Map<String, Object?> map) {
    return FoodEntry(
      id: map['id'] as int?,
      description: map['description'] as String,
      proteinGrams: map['protein_grams'] as int,
      eatenAt: DateTime.fromMillisecondsSinceEpoch(
        map['eaten_at'] as int,
        isUtc: true,
      ).toLocal(),
      estimated: (map['estimated'] as int? ?? 1) == 1,
    );
  }

  @override
  String toString() =>
      'FoodEntry(id: $id, $description, ${proteinGrams}g, '
      'estimated: $estimated, at: $eatenAt)';
}
