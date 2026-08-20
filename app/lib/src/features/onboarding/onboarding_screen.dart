import 'package:flutter/material.dart';

import '../../core/tokens.dart';

/// "How it works" — a short, warm explainer of what MemoriesIQ does, and of the
/// privacy promise that makes people willing to put a life into it.
/// Reachable from the menu; also suitable as a first-run intro.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _slides = <(_SlideArt, String, String)>[
    (
      _SlideArt.record,
      'Speak or write a moment',
      'Tap Record and type it out — or switch to Speak and just talk. Either way, in any '
          'language. Back-date it to any day it really happened.',
    ),
    (
      _SlideArt.recall,
      'Talk to your memories',
      'Tap Recall and ask out loud, or chat by text. MemoriesIQ finds the moments that answer '
          'you, and reads them back.',
    ),
    (
      _SlideArt.resurface,
      'Rediscover the past',
      'Home resurfaces what happened on this day years ago, and marks the milestones worth '
          'keeping. Ask the AI about any of it out loud, or in chat.',
    ),
    (
      _SlideArt.private,
      'Yours, and only yours',
      'Your memories are private. No one else can read them or hear your recordings — not other '
          'people, and not the makers of this app.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _page == _slides.length - 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How it works')),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _slides.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) {
                final (art, title, body) = _slides[i];
                return Padding(
                  padding: const EdgeInsets.all(Insets.xxl),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _SlideArtwork(art),
                      const SizedBox(height: Insets.xxl),
                      Text(title,
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center),
                      const SizedBox(height: Insets.md),
                      Text(body,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              height: 1.4)),
                    ],
                  ),
                );
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _slides.length; i++)
                AnimatedContainer(
                  duration: Motion.fast,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  if (_isLast) {
                    Navigator.of(context).maybePop();
                  } else {
                    _controller.nextPage(duration: Motion.medium, curve: Curves.easeInOut);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                  child: Text(_isLast ? 'Start capturing' : 'Next'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _SlideArt { record, recall, resurface, private }

class _SlideArtwork extends StatelessWidget {
  const _SlideArtwork(this.art);
  final _SlideArt art;

  @override
  Widget build(BuildContext context) {
    final icon = switch (art) {
      _SlideArt.record => Icons.mic,
      _SlideArt.recall => Icons.auto_awesome,
      _SlideArt.resurface => Icons.history,
      _SlideArt.private => Icons.lock_outline,
    };
    return Container(
      width: 132,
      height: 132,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.heroWash,
      ),
      child: Icon(icon, color: Colors.white, size: 56),
    );
  }
}
