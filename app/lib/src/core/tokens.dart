import 'package:flutter/material.dart';

/// Design tokens for MemoriesIQ — the single source of truth for the brand's
/// colours, spacing, radii and motion. "Refined violet keepsake" identity:
/// a warm indigo-violet with a gold accent reserved for milestones/highlights.
class AppColors {
  const AppColors._();

  static const violet = Color(0xFF6C5CE7); // primary
  static const violetDeep = Color(0xFF4A3DB8); // gradients, pressed states
  static const violetLight = Color(0xFF9A8CFF); // primary on dark grounds
  static const gold = Color(0xFFF4B740); // accent — milestones ⭐ / highlights

  // Neutrals carry a slight violet bias so they read as chosen, not default grey.
  static const inkLight = Color(0xFF1E1A2B);
  static const paperLight = Color(0xFFF7F4FD);
  static const paperDark = Color(0xFF100D1A);
  static const surfaceDark = Color(0xFF191527);

  /// Soft violet→deep-violet wash used on hero memory cards and the AI orb.
  static const LinearGradient heroWash = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [violetDeep, violet],
  );
}

/// 4-based spacing scale. Use these instead of ad-hoc numbers.
class Insets {
  const Insets._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii.
class Radii {
  const Radii._();
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

/// Motion durations.
class Motion {
  const Motion._();
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 400);
  static const Duration breathe = Duration(milliseconds: 3600);
}
