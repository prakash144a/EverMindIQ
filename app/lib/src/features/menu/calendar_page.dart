import 'package:flutter/material.dart';

import '../calendar/calendar_screen.dart';

/// Wraps the body-only [CalendarScreen] in a Scaffold for pushed navigation.
class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Timeline & Calendar')),
      body: const CalendarScreen(),
    );
  }
}
