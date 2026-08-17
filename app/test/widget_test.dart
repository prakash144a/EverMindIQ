import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voiceiq/src/app.dart';

void main() {
  testWidgets('App boots and renders the shell', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MemoriesIQApp()));
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
