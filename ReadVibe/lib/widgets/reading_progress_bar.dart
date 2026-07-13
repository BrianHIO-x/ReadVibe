import 'package:flutter/material.dart';

/// A thin, fixed progress indicator pinned to the very top of the reader,
/// tracking scroll position within the current chapter.
///
/// Rebuilds only itself via [AnimatedBuilder] so a scroll event doesn't
/// repaint the rest of the reader tree. Deliberately not gated behind the
/// overlay toggle — it gives the reader a persistent sense of progress
/// without needing to summon the header/footer bars.
class ReadingProgressBar extends StatelessWidget {
  final ScrollController controller;
  final Color trackColor;
  final Color fillColor;

  const ReadingProgressBar({
    super.key,
    required this.controller,
    required this.trackColor,
    required this.fillColor,
  });

  double _progress() {
    // hasClients only means a ScrollPosition is attached — it can still be
    // true before the first layout has established content dimensions
    // (e.g. the very first frame after a chapter switch), at which point
    // reading maxScrollExtent throws. hasContentDimensions guards that.
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return 0.0;
    }
    final maxExtent = controller.position.maxScrollExtent;
    if (maxExtent <= 0) return 0.0;
    return (controller.offset / maxExtent).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SizedBox(
          height: 2,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: trackColor)),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: _progress(),
                child: ColoredBox(color: fillColor),
              ),
            ],
          ),
        );
      },
    );
  }
}
