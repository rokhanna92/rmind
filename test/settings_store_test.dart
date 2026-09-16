import 'package:flutter_test/flutter_test.dart';
import 'package:rmind/models/food_entry.dart';
import 'package:rmind/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('defaults', () {
    test('shakeGrams falls back to the model default', () async {
      expect(await SettingsStore().shakeGrams(), FoodEntry.defaultShakeGrams);
    });

    test('dailyProteinTarget falls back to the model default', () async {
      expect(
        await SettingsStore().dailyProteinTarget(),
        FoodEntry.defaultDailyTarget,
      );
    });
  });

  group('round trip', () {
    test('a shake value written is the value read back', () async {
      final store = SettingsStore();

      await store.setShakeGrams(25);

      expect(await store.shakeGrams(), 25);
    });

    test('a target written is the value read back', () async {
      final store = SettingsStore();

      await store.setDailyProteinTarget(180);

      expect(await store.dailyProteinTarget(), 180);
    });

    test('the two settings do not touch each other', () async {
      final store = SettingsStore();

      await store.setShakeGrams(25);

      expect(await store.dailyProteinTarget(), FoodEntry.defaultDailyTarget);

      await store.setDailyProteinTarget(180);

      expect(await store.shakeGrams(), 25);
    });
  });

  group('clamping', () {
    test('a value below the range is stored as the minimum', () async {
      final store = SettingsStore();

      await store.setShakeGrams(0);
      await store.setDailyProteinTarget(-40);

      expect(await store.shakeGrams(), SettingsStore.minGrams);
      expect(await store.dailyProteinTarget(), SettingsStore.minGrams);
    });

    test('a value above the range is stored as the maximum', () async {
      final store = SettingsStore();

      await store.setShakeGrams(9999);
      await store.setDailyProteinTarget(100000);

      expect(await store.shakeGrams(), SettingsStore.maxShakeGrams);
      expect(await store.dailyProteinTarget(), SettingsStore.maxTargetGrams);
    });

    test('the ends of the range are stored untouched', () async {
      final store = SettingsStore();

      await store.setShakeGrams(SettingsStore.minGrams);
      await store.setDailyProteinTarget(SettingsStore.maxTargetGrams);

      expect(await store.shakeGrams(), SettingsStore.minGrams);
      expect(await store.dailyProteinTarget(), SettingsStore.maxTargetGrams);
    });

    test('a nonsense value already in storage is clamped on the way out',
        () async {
      SharedPreferences.setMockInitialValues({
        SettingsStore.shakeGramsKey: 0,
        SettingsStore.dailyProteinTargetKey: 9999,
      });

      final store = SettingsStore();

      expect(await store.shakeGrams(), SettingsStore.minGrams);
      expect(await store.dailyProteinTarget(), SettingsStore.maxTargetGrams);
    });

    test('a shake never exceeds what one entry can hold', () async {
      // The quick add pill prints this figure and the repository clamps every
      // entry to the same ceiling, so a shake the store accepts but the
      // database would shrink is the pill lying about what it just added.
      final store = SettingsStore();

      await store.setShakeGrams(SettingsStore.maxTargetGrams);

      expect(await store.shakeGrams(), FoodEntry.maxGramsPerEntry);
      expect(
        FoodEntry.clampGrams(await store.shakeGrams()),
        await store.shakeGrams(),
      );
    });

    test('a target may run past what one entry can hold', () async {
      // A day is several entries, so the target is not bound by the per entry
      // ceiling the way the shake figure is.
      final store = SettingsStore();

      await store.setDailyProteinTarget(FoodEntry.maxGramsPerEntry + 100);

      expect(
        await store.dailyProteinTarget(),
        FoodEntry.maxGramsPerEntry + 100,
      );
    });

    test('a shake left over from the older wider range is clamped on read',
        () async {
      SharedPreferences.setMockInitialValues({
        SettingsStore.shakeGramsKey: 480,
      });

      expect(await SettingsStore().shakeGrams(), FoodEntry.maxGramsPerEntry);
    });
  });

  group('sharing', () {
    test('a second store sees what the first wrote', () async {
      await SettingsStore().setShakeGrams(42);
      await SettingsStore().setDailyProteinTarget(160);

      final other = SettingsStore();

      expect(await other.shakeGrams(), 42);
      expect(await other.dailyProteinTarget(), 160);
    });

    test('a store reads back what it wrote rather than a cached first read',
        () async {
      final store = SettingsStore();

      expect(await store.shakeGrams(), FoodEntry.defaultShakeGrams);
      await store.setShakeGrams(35);

      expect(await store.shakeGrams(), 35);
    });

    test('an injected instance is the one used', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = SettingsStore(prefs: prefs);

      await store.setShakeGrams(28);

      expect(prefs.getInt(SettingsStore.shakeGramsKey), 28);
      expect(await SettingsStore().shakeGrams(), 28);
    });
  });
}
