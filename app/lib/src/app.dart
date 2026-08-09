import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'features/shell/app_shell.dart';

class VoiceIQApp extends StatelessWidget {
  const VoiceIQApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceIQ',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const AppShell(),
    );
  }
}
