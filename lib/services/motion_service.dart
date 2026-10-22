import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Display and power hints for animation, backed by the native motion
/// handler.
///
/// Anything that moves holds a reason while it does. The display runs at its
/// fastest rate while any reason is held and drops back shortly after the last
/// one is released, so a page at rest lets the panel idle. Holds expire on
/// their own unless renewed, which keeps a lost release from pinning the fast
/// rate.
class MotionService {
  MotionService._();

  static const _channel = MethodChannel('com.readvibe.app/motion');

  /// How long a hold lasts without being renewed.
  static const _holdTimeout = Duration(milliseconds: 1500);

  /// How long the fast rate outlives the last hold, so back-to-back motion
  /// does not switch the display mode for every gesture.
  static const _linger = Duration(milliseconds: 600);

  static final ValueNotifier<bool> _powerSaveMode = ValueNotifier<bool>(false);
  // Expiries are read off a monotonic clock, so a change to the system time
  // can never leave a hold alive.
  static final Stopwatch _clock = Stopwatch()..start();
  static final Map<Object, Duration> _holds = <Object, Duration>{};
  static Timer? _timer;
  static bool _fastRate = false;
  static Future<void> _commands = Future<void>.value();

  /// Whether the system battery saver is on.
  static ValueListenable<bool> get powerSaveMode => _powerSaveMode;

  static Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'powerSaveModeChanged') {
        _powerSaveMode.value = call.arguments == true;
      }
    });
    try {
      _powerSaveMode.value =
          await _channel.invokeMethod<bool>('isPowerSaveMode') ?? false;
    } on MissingPluginException {
      // Hosts without the native handler keep the defaults.
    } on Object catch (error) {
      debugPrint('Power save state unavailable: $error');
    }
  }

  /// Marks [reason] as moving, or renews its hold.
  static void hold(Object reason) {
    final renewing = _holds.containsKey(reason);
    _holds[reason] = _clock.elapsed + _holdTimeout;
    // A renewal only pushes the expiry later. The timer already set wakes
    // early and reschedules, which keeps per-frame renewals cheap.
    if (!renewing || !_fastRate) _update();
  }

  static void release(Object reason) {
    if (_holds.remove(reason) != null) _update();
  }

  /// Holds for motion with a known length.
  static void holdFor(Duration duration) {
    _holds[Object()] = _clock.elapsed + duration;
    _update();
  }

  /// Holds while any list in the app scrolls or flings. Install it above the
  /// navigator so every route's scrollables report here.
  static bool handleScroll(ScrollNotification notification) {
    final reason = notification.context;
    if (reason == null) return false;
    if (notification is ScrollEndNotification) {
      release(reason);
    } else if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification) {
      hold(reason);
    }
    return false;
  }

  static void _update() {
    _timer?.cancel();
    _timer = null;
    final now = _clock.elapsed;
    _holds.removeWhere((_, until) => until <= now);
    if (_holds.isNotEmpty) {
      _setFastRate(true);
      final next = _holds.values.reduce((a, b) => a < b ? a : b);
      _timer = Timer(next - now, _update);
    } else if (_fastRate) {
      _timer = Timer(_linger, () {
        if (_holds.isEmpty) _setFastRate(false);
      });
    }
  }

  static void _setFastRate(bool active) {
    if (_fastRate == active) return;
    _fastRate = active;
    _commands = _commands.then((_) async {
      try {
        await _channel.invokeMethod<void>('setHighRefreshRate', {
          'active': active,
        });
      } on MissingPluginException {
        // Non-Android hosts keep their own refresh policy.
      } on Object catch (error) {
        debugPrint('Refresh rate request failed: $error');
      }
    });
  }
}
