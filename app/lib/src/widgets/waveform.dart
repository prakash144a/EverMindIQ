import 'package:flutter/material.dart';

import '../core/tokens.dart';

/// A live recording waveform. Feed it a rolling buffer of normalized
/// amplitudes (0..1, newest last) and it draws gold→sage bars that scroll
/// right as you speak.
class WaveformView extends StatelessWidget {
  const WaveformView({
    super.key,
    required this.amplitudes,
    this.height = 56,
    this.barCount = 32,
  });

  final List<double> amplitudes;
  final double height;
  final int barCount;

  @override
  Widget build(BuildContext context) {
    // Take the most recent [barCount] samples, padding the left with silence.
    final recent = amplitudes.length > barCount
        ? amplitudes.sublist(amplitudes.length - barCount)
        : [...List.filled(barCount - amplitudes.length, 0.04), ...amplitudes];

    return SizedBox(
      height: height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final a in recent)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: AnimatedContainer(
                  duration: Motion.fast,
                  height: (height * a.clamp(0.04, 1.0)),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    gradient: const LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [AppColors.sage, AppColors.gold],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
