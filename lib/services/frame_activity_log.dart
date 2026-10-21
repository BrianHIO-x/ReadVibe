import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Frame counts for profile builds.
///
/// Every ten seconds that drew anything, the log reports how many frames were
/// drawn and the slowest build and raster times among them. A page left at
/// rest should log nothing at all; a count there means something is animating
/// out of sight. Release and debug builds never start it.
class FrameActivityLog {
  FrameActivityLog._();

  static const _window = Duration(seconds: 10);

  static void start() {
    if (!kProfileMode) return;
    var frames = 0;
    var slowestBuild = Duration.zero;
    var slowestRaster = Duration.zero;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      frames += timings.length;
      for (final timing in timings) {
        if (timing.buildDuration > slowestBuild) {
          slowestBuild = timing.buildDuration;
        }
        if (timing.rasterDuration > slowestRaster) {
          slowestRaster = timing.rasterDuration;
        }
      }
    });
    Timer.periodic(_window, (_) {
      if (frames == 0) return;
      debugPrint(
        'ReadVibe frames: $frames in ${_window.inSeconds}s, '
        'slowest build ${_milliseconds(slowestBuild)} ms, '
        'slowest raster ${_milliseconds(slowestRaster)} ms',
      );
      frames = 0;
      slowestBuild = Duration.zero;
      slowestRaster = Duration.zero;
    });
  }

  static String _milliseconds(Duration duration) =>
      (duration.inMicroseconds / 1000).toStringAsFixed(1);
}
