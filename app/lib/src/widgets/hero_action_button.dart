import 'package:flutter/material.dart';

import '../core/tokens.dart';

/// A large primary action for the home dock. [filled] is the solid violet
/// Record button; the outlined variant (Recall) reads as secondary but equal
/// in size. Wrap each in an [Expanded] inside a [Row].
class HeroActionButton extends StatelessWidget {
  const HeroActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = true,
  });

  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg = filled ? scheme.primary : scheme.surface;
    final Color fg = filled ? scheme.onPrimary : scheme.primary;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(Radii.pill),
      elevation: filled ? 1 : 0,
      shadowColor: AppColors.violet.withValues(alpha: 0.35),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: onTap,
        child: Container(
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  border: Border.all(color: scheme.primary.withValues(alpha: 0.3), width: 1.25),
                ),
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme(
                data: IconThemeData(color: fg, size: 17),
                child: icon,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                    color: fg, fontWeight: FontWeight.w600, fontSize: 13.5, letterSpacing: 0.1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
