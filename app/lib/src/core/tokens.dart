import 'package:flutter/material.dart';

/// Design tokens for MemoriesIQ — the single source of truth for the brand's
/// colours, spacing, radii and motion. "Sage & gold keepsake" identity: a calm
/// sage green with a gold accent reserved for milestones/highlights.
class AppColors {
  const AppColors._();

  static const sage = Color(0xFF40835A); // primary on light grounds
  static const sageDeep = Color(0xFF2F6647); // gradients, pressed states
  static const sageLight = Color(0xFF83BE9B); // primary on dark grounds
  static const sageMist = Color(0xFFD8EEE0); // highlight inside orb gradients

  static const gold = Color(0xFFC08A2C); // accent — milestones ⭐ / highlights
  static const goldLight = Color(0xFFE0B457); // accent on dark grounds

  // Neutrals carry a slight green bias so they read as chosen, not default grey.
  static const ink = Color(0xFF14201A);
  static const inkDark = Color(0xFFEAF2EC);
  static const paperLight = Color(0xFFF5F9F6);
  static const paperDark = Color(0xFF0F1613);
  static const surfaceDark = Color(0xFF18211C);
  static const borderLight = Color(0xFFE1EAE4);
  static const borderDark = Color(0xFF26332B);
  static const sageSoftLight = Color(0xFFE7F2EA); // tints, chips
  static const sageSoftDark = Color(0xFF1A2922);

  // The ground the record/recall/voice screens paint themselves on. Those
  // screens are dark by design in either theme, so this pair is deliberately
  // outside the light/dark split.
  static const immersiveTop = Color(0xFF1A3627);
  static const immersiveBottom = Color(0xFF080F0B);

  /// Soft sage→deep-sage wash used on hero memory cards and the AI orb.
  static const LinearGradient heroWash = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [sageDeep, sage],
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
