import 'package:flutter/material.dart';

/// Where photos, videos and files will be attached to a memory — not yet.
///
/// A placeholder on purpose. Nothing can be uploaded today: the server stores
/// audio and text and nothing else. The control is here so the place for it is
/// settled and visible before the feature is, and it says plainly that it is
/// coming rather than pretending to work — every entry is disabled, and the
/// button never opens a file picker.
///
/// When attachments are built, this is the widget that grows an `onPicked`.
class AttachPlaceholderButton extends StatelessWidget {
  const AttachPlaceholderButton({super.key, this.color});

  /// Icon colour; the theme's by default.
  final Color? color;

  static const comingSoon = 'Photos, videos and files are coming soon';

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return PopupMenuButton<void>(
      tooltip: comingSoon,
      position: PopupMenuPosition.under,
      // Labelled, with "Soon" beside it rather than as a badge over the icon:
      // a badge hangs outside its button, and here that put it on top of the
      // microphone next door.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.attach_file_rounded, size: 20, color: tint),
            const SizedBox(width: 4),
            Text('Attach',
                style: TextStyle(color: tint, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('Soon',
                  style: TextStyle(color: tint, fontWeight: FontWeight.w600, fontSize: 11)),
            ),
          ],
        ),
      ),
      itemBuilder: (_) => const [
        PopupMenuItem<void>(
          enabled: false,
          child: Text(comingSoon, style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        PopupMenuDivider(),
        PopupMenuItem<void>(
          enabled: false,
          child: _Kind(icon: Icons.image_outlined, label: 'Photo'),
        ),
        PopupMenuItem<void>(
          enabled: false,
          child: _Kind(icon: Icons.videocam_outlined, label: 'Video'),
        ),
        PopupMenuItem<void>(
          enabled: false,
          child: _Kind(icon: Icons.insert_drive_file_outlined, label: 'File'),
        ),
      ],
    );
  }
}

class _Kind extends StatelessWidget {
  const _Kind({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}
