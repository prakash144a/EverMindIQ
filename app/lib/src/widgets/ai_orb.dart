import 'package:flutter/material.dart';

import '../core/tokens.dart';

/// The MemoriesIQ AI presence: a luminous sage orb that breathes while idle and
/// pulses a halo while [active] (listening / speaking). Hand-rolled with
/// [AnimationController]s so it needs no animation package.
class AiOrb extends StatefulWidget {
  const AiOrb({super.key, this.size = 120, this.active = true});

  final double size;

  /// When true the orb breathes and emits an expanding halo. Set false for a
  /// still, resting state.
  final bool active;

  @override
  State<AiOrb> createState() => _AiOrbState();
}

class _AiOrbState extends State<AiOrb> with TickerProviderStateMixin {
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: Motion.breathe,
  );
  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AiOrb old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    if (widget.active) {
      _breathe.repeat(reverse: true);
      _halo.repeat();
    } else {
      _breathe.stop();
      _halo.stop();
    }
  }

  @override
  void dispose() {
    _breathe.dispose();
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 1.5,
      height: s * 1.5,
      child: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_breathe, _halo]),
          builder: (context, _) {
            final scale = widget.active ? 1.0 + 0.06 * _breathe.value : 1.0;
            final haloT = _halo.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                if (widget.active)
                  Opacity(
                    opacity: (1 - haloT) * 0.5,
                    child: Container(
                      width: s * (1 + 0.45 * haloT),
                      height: s * (1 + 0.45 * haloT),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.sage.withValues(alpha: 0.5)),
                      ),
                    ),
                  ),
                Transform.scale(
                  scale: scale,
                  child: Container(
                    width: s,
                    height: s,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        center: Alignment(-0.3, -0.4),
                        radius: 0.95,
                        colors: [AppColors.sageMist, AppColors.sage, AppColors.sageDeep],
                        stops: [0.0, 0.55, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.sage.withValues(alpha: 0.55),
                          blurRadius: 44,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
