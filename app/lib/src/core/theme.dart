import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// MemoriesIQ theme — Sage & gold keepsake. Material 3, light + dark.
///
/// Typography pairs **Fraunces** (a soft serif) for titles and memory content
/// with **Inter** for UI/body text. Gold is wired to `tertiary` so it stays a
/// deliberate accent (milestones, highlights) rather than a second brand colour.
///
/// Neither factory takes arguments: the palette is fixed, and which of the two
/// applies is [MaterialApp.themeMode]'s job — see `themeModeProvider`.
class AppTheme {
  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.sage,
      brightness: brightness,
    ).copyWith(
      // fromSeed doesn't recompute the `on*` pairs when their colour is
      // overridden, so they're set by hand. White fails on both sageLight
      // (2.1:1) and gold (3.0:1); ink clears AA on both.
      primary: isDark ? AppColors.sageLight : AppColors.sage,
      onPrimary: isDark ? AppColors.ink : Colors.white,
      primaryContainer:
          isDark ? AppColors.sageSoftDark : AppColors.sageSoftLight,
      onPrimaryContainer: isDark ? AppColors.sageLight : AppColors.sageDeep,
      tertiary: isDark ? AppColors.goldLight : AppColors.gold,
      onTertiary: AppColors.ink,
      surface: isDark ? AppColors.paperDark : AppColors.paperLight,
      onSurface: isDark ? AppColors.inkDark : AppColors.ink,
      surfaceContainerHigh: isDark ? AppColors.surfaceDark : Colors.white,
      outlineVariant: isDark ? AppColors.borderDark : AppColors.borderLight,
    );

    final baseText =
        (isDark ? ThemeData.dark() : ThemeData.light()).textTheme;
    final bodyText = GoogleFonts.interTextTheme(baseText);
    final textTheme = bodyText.copyWith(
      displayLarge:
          GoogleFonts.fraunces(textStyle: bodyText.displayLarge, fontWeight: FontWeight.w500),
      displayMedium:
          GoogleFonts.fraunces(textStyle: bodyText.displayMedium, fontWeight: FontWeight.w500),
      displaySmall:
          GoogleFonts.fraunces(textStyle: bodyText.displaySmall, fontWeight: FontWeight.w500),
      headlineMedium:
          GoogleFonts.fraunces(textStyle: bodyText.headlineMedium, fontWeight: FontWeight.w500),
      headlineSmall:
          GoogleFonts.fraunces(textStyle: bodyText.headlineSmall, fontWeight: FontWeight.w600),
      titleLarge:
          GoogleFonts.fraunces(textStyle: bodyText.titleLarge, fontWeight: FontWeight.w600),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleTextStyle: GoogleFonts.fraunces(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
      ),
    );
  }
}
