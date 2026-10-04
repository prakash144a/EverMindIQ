import 'package:flutter/widgets.dart';

/// Where a memory, a journal or any other "open this" should appear.
///
/// On a phone there is one navigator and the answer is always "on top". On a
/// wide screen the app is three panes, and something opened from the Recall
/// pane — a memory an answer cited — belongs in the pane beside it, where the
/// memories are, not squeezed into the conversation and not over the whole
/// window. The wide shell wraps itself in this and names its middle pane's
/// navigator; everything else asks [of] and gets the ordinary navigator back
/// when there is no such pane.
class ContentNavigator extends InheritedWidget {
  const ContentNavigator({super.key, required this.navigatorKey, required super.child});

  final GlobalKey<NavigatorState> navigatorKey;

  /// The middle pane's navigator on a wide screen; otherwise the nearest one.
  static NavigatorState of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ContentNavigator>();
    return scope?.navigatorKey.currentState ?? Navigator.of(context);
  }

  @override
  bool updateShouldNotify(ContentNavigator oldWidget) => navigatorKey != oldWidget.navigatorKey;
}
