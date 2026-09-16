import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/food_entry.dart';

/// The handful of numbers the food diary lets the user set for themselves.
///
/// Typed accessors over shared_preferences and nothing else: no formatting, no
/// widgets, no opinions about how a target is shown.
///
/// Nothing is held in a field between calls. The settings screen writes a value
/// and the home screen reads it moments later from its own instance, so a
/// cached copy would be a stale copy, and this is read rarely enough that
/// going back to the store every time costs nothing.
class SettingsStore {
  /// [prefs] exists so tests, and any caller that already has an instance, can
  /// hand one in. Left unset, every call fetches the shared instance.
  SettingsStore({SharedPreferences? prefs}) : _injected = prefs;

  static const String shakeGramsKey = 'food_shake_grams';
  static const String dailyProteinTargetKey = 'food_daily_protein_target';

  /// Nothing edible is worth less than a gram, and nothing a person eats in a
  /// day runs past 500. A target outside this is a typo or a misheard number,
  /// and storing it would hand the UI a figure it cannot draw sensibly.
  static const int minGrams = 1;
  static const int maxTargetGrams = 500;

  /// The shake figure is the grams of a single entry, so it stops where a
  /// single entry stops. Allowing more would let the quick add pill print a
  /// number the repository then clamps on its way into the database, and the
  /// whole point of that pill is that the number added is never a surprise.
  static const int maxShakeGrams = FoodEntry.maxGramsPerEntry;

  final SharedPreferences? _injected;

  /// The grams one shake is worth, as the user has it. Not a guess: when they
  /// say "had a protein shake" this is the figure that gets recorded.
  Future<int> shakeGrams() =>
      _read(shakeGramsKey, FoodEntry.defaultShakeGrams, maxShakeGrams);

  Future<void> setShakeGrams(int grams) =>
      _write(shakeGramsKey, grams, maxShakeGrams);

  Future<int> dailyProteinTarget() =>
      _read(dailyProteinTargetKey, FoodEntry.defaultDailyTarget, maxTargetGrams);

  Future<void> setDailyProteinTarget(int grams) =>
      _write(dailyProteinTargetKey, grams, maxTargetGrams);

  /// Never throws. This runs during startup, and a device whose preferences
  /// are unavailable has to land on a working screen using the defaults rather
  /// than on a crash the user cannot get past.
  ///
  /// The stored value is clamped on the way out as well as on the way in, so
  /// every caller can rely on a usable number. A zero target restored from an
  /// older backup would otherwise reach the UI as a divisor.
  Future<int> _read(String key, int fallback, int max) async {
    try {
      final prefs = _injected ?? await SharedPreferences.getInstance();
      final stored = prefs.getInt(key);
      if (stored == null) return fallback;
      return clamp(stored, max);
    } on MissingPluginException {
      return fallback;
    } on PlatformException {
      return fallback;
    }
  }

  /// A failed write is allowed to throw, unlike a failed read: the user is
  /// looking at the settings screen when this runs, and a number that silently
  /// did not save is worse than an error saying so.
  Future<void> _write(String key, int grams, int max) async {
    final prefs = _injected ?? await SharedPreferences.getInstance();
    await prefs.setInt(key, clamp(grams, max));
  }

  static int clamp(int grams, int max) {
    if (grams < minGrams) return minGrams;
    if (grams > max) return max;
    return grams;
  }
}
