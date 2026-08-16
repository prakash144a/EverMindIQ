import 'package:flutter/material.dart';

import '../core/tokens.dart';

/// The user's initials on the app's identity gradient.
///
/// Falls back to a person icon when there's no name yet — an anonymous user has
/// nothing to show initials for.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({super.key, required this.initials, this.size = 44});

  /// Already-computed initials; see `initialsFor` in `data/models.dart`.
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.heroWash,
      ),
      child: initials.isEmpty
          ? Icon(Icons.person, color: Colors.white, size: size * 0.5)
          : Text(
              initials,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: size * 0.36,
                letterSpacing: 0.5,
              ),
            ),
    );
  }
}
