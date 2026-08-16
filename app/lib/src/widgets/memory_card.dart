import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../data/models.dart';
import 'formatting.dart';

/// The hero "On This Day" card — a violet-washed keepsake with the resurfacing
/// reason, the memory title in Fraunces, a short summary and the date.
class MemoryCard extends StatelessWidget {
  const MemoryCard(this.item, {super.key, this.onTap});

  final MemoryItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(Insets.xl),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            gradient: AppColors.heroWash,
            boxShadow: [
              BoxShadow(
                color: AppColors.violet.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, color: Colors.white70, size: 18),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      item.reason.isEmpty ? 'ON THIS DAY' : item.reason.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.md),
              Text(
                item.title.isEmpty ? 'A moment worth keeping' : item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: Insets.sm),
              Text(
                item.summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, height: 1.35),
              ),
              const SizedBox(height: Insets.md),
              Text(
                prettyDate(item.eventDate),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
