import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// The chrome shared by the record, recall and voice-mode screens.
///
/// Those three paint their own near-black ground regardless of the app's theme,
/// which leaves two things wrong when the app is in light mode: widgets that
/// take their colour from the theme (buttons, snack bars, the compose field)
/// resolve for a light surface and disappear, and the status-bar icons go dark
/// on a dark ground. Forcing the subtree dark fixes both at once, and keeps
/// fixing them for anything added to these screens later.
class ImmersiveChrome extends StatelessWidget {
  const ImmersiveChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(data: AppTheme.dark(), child: child),
    );
  }
}
