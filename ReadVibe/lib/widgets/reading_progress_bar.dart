import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// A thin, fixed progress indicator pinned to the very top of the reader,
/// tracking the active chapter position in every reading mode.
///
/// Rebuilds only itself via [ValueListenableBuilder] so a scroll event doesn't
/// repaint the rest of the reader tree. Deliberately not gated behind the
/// overlay toggle — it gives the reader a persistent sense of progress
/// without needing to summon the header/footer bars.
class ReadingProgressBar extends StatelessWidget {
  final ValueListenable<double> progress;
  final Color trackColor;
  final Color fillColor;

  const ReadingProgressBar({
    super.key,
    required this.progress,
    required this.trackColor,
    required this.fillColor,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      builder: (context, value, _) {
        return SizedBox(
          height: 2,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: trackColor)),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value.isFinite
                    ? value.clamp(0.0, 1.0).toDouble()
                    : 0.0,
                child: ColoredBox(color: fillColor),
              ),
            ],
          ),
        );
      },
    );
  }
}
