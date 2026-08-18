import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voiceiq/src/app.dart';

void main() {
  testWidgets('App boots and renders the shell', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MemoriesIQApp()));
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
    // The root reads the theme provider; booting must not depend on the network.
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
  });
}
