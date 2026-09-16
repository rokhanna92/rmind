import 'package:flutter/material.dart';

/// Design tokens, transcribed from the RMIND canvas.
///
/// The design is committed to a single dark scheme. Light is not a half
/// finished second theme here, it simply does not exist yet, so the app locks
/// itself to dark rather than letting the system hand it an unstyled light
/// palette.
class RM {
  const RM._();

  // Surfaces, darkest to lightest.
  static const Color bg = Color(0xFF111318);
  static const Color surface = Color(0xFF191B21);
  static const Color sheet = Color(0xFF1D2027);
  static const Color field = Color(0xFF282A31);
  static const Color line = Color(0xFF444650);

  // Text, in descending emphasis.
  static const Color ink = Color(0xFFE2E2EA);
  static const Color inkMid = Color(0xFFC4C6D3);
  static const Color inkSoft = Color(0xFF8E90A0);

  // Accent family. [seed] is the Material seed the whole scheme derives from.
  static const Color seed = Color(0xFF4C6EF5);
  static const Color accent = Color(0xFF4C6EF5);
  static const Color accentLight = Color(0xFFB9C3FF);
  static const Color accentBright = Color(0xFFDEE0FF);
  static const Color accentContainer = Color(0xFF3A4B9B);
  static const Color onAccentDeep = Color(0xFF0F2878);

  /// The running workout session card and strip.
  static const Color session = Color(0xFF1E2A5E);

  /// Reserved strictly for alarms and for warnings. It is the only warm colour
  /// in the palette, which is what makes an alarm row readable at a glance, so
  /// it must not be spent on ordinary emphasis.
  static const Color alarm = Color(0xFFFFB77A);

  static const String fontFamily = 'Manrope';

  // Radii used across the design.
  static const double rRow = 16;
  static const double rCard = 22;
  static const double rField = 18;
  static const double rChip = 10;
  static const double rSheet = 28;

  /// Times, durations and counts line up in columns all over this app, so
  /// tabular figures are the default rather than an opt in.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextStyle _t(
    double size,
    FontWeight weight, {
    Color color = ink,
    double? height,
    double letterSpacing = 0,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
      fontFeatures: tabular,
    );
  }

  /// Screen titles, e.g. "Reminders".
  static TextStyle get screenTitle =>
      _t(28, FontWeight.w800, letterSpacing: -0.5);

  /// The clock time in a list row. Deliberately the largest thing in the row:
  /// the design's rule is that users scan for when, not what.
  static TextStyle get rowTime => _t(22, FontWeight.w800, letterSpacing: -0.3);

  /// The task title, which sits under the time and reads second.
  static TextStyle get rowTitle => _t(15, FontWeight.w400);

  /// Day headers such as "Today" or "Friday".
  static TextStyle get dayLabel => _t(15, FontWeight.w700);

  /// The lighter date beside a day header.
  static TextStyle get dayDate => _t(12, FontWeight.w400, color: inkSoft);

  /// Right hand metadata in a row, e.g. "30 min before".
  static TextStyle get rowMeta => _t(12, FontWeight.w500, color: inkSoft);

  /// Small uppercase section labels, e.g. "HEARD AS", "DATE".
  static TextStyle get label =>
      _t(11, FontWeight.w600, color: inkSoft, letterSpacing: 0.3);

  static TextStyle get sheetTitle =>
      _t(22, FontWeight.w700, letterSpacing: -0.3);

  /// The big value inside a date or time card on the confirm sheet.
  static TextStyle get fieldValueBig =>
      _t(28, FontWeight.w800, letterSpacing: -0.5, height: 1);

  static TextStyle get fieldValue => _t(20, FontWeight.w700);

  static TextStyle get chip => _t(13, FontWeight.w600, color: inkMid);

  static TextStyle get button => _t(16, FontWeight.w700, color: Colors.white);

  static TextStyle get body => _t(14, FontWeight.w400, color: inkMid, height: 1.5);

  /// The live transcript while listening. Large, because it is the only thing
  /// on screen worth reading at that moment.
  static TextStyle get transcript =>
      _t(24, FontWeight.w700, height: 1.3, letterSpacing: -0.3);

  /// The running session clock.
  static TextStyle get timer => _t(
        40,
        FontWeight.w800,
        color: Colors.white,
        letterSpacing: -1,
        height: 1,
      );

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).copyWith(
      surface: bg,
      primary: accent,
      onPrimary: Colors.white,
      secondary: accentLight,
      outline: line,
      error: alarm,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      fontFamily: fontFamily,
      splashFactory: InkSparkle.splashFactory,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accentLight,
        selectionColor: accentContainer,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: sheet,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: sheet,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: field,
        contentTextStyle: _t(14, FontWeight.w500),
        actionTextColor: accentLight,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rChip),
        ),
      ),
    );
  }
}
