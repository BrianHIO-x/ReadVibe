import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the paper edge-to-edge while independently controlling status icons.
/// Physical cutout metrics do not change when the IME or reader menus appear.
class ReaderWindowController extends ChangeNotifier
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.readvibe.app/reader_window');
  static Future<void> _commands = Future<void>.value();
  EdgeInsets? _cutout;
  EdgeInsets? _bars;
  bool _visible = true;
  bool _disposed = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _keyboardVisible = false;
  Timer? _restoreTimer;

  EdgeInsets contentInsets(EdgeInsets fallback) => EdgeInsets.fromLTRB(
    _cutout?.left ?? fallback.left,
    _cutout?.top ?? fallback.top,
    _cutout?.right ?? fallback.right,
    (_bars?.bottom ?? fallback.bottom).clamp(
      _cutout?.bottom ?? 0,
      double.infinity,
    ),
  );

  EdgeInsets chromeInsets(EdgeInsets fallback) => _bars ?? fallback;

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } on Object catch (error) {
      debugPrint('Edge-to-edge initialization failed: $error');
    }
    if (_disposed) return;
    await showChrome(true);
    await _refreshMetrics();
  }

  Future<void> showChrome(bool visible) {
    if (_disposed) return Future<void>.value();
    _visible = visible;
    return _enqueueChrome(visible);
  }

  static Future<void> _enqueueChrome(bool visible) {
    // Serial across routes too: an old reader's restoration cannot arrive
    // after a new reader has already hidden its chrome.
    return _commands = _commands.then((_) async {
      try {
        await _channel.invokeMethod<void>('setChrome', {'visible': visible});
      } on MissingPluginException {
        // Non-Android hosts retain Flutter's edge-to-edge surface.
      } on Object catch (error) {
        debugPrint('Reader window update failed: $error');
      }
    });
  }

  Future<void> _refreshMetrics() async {
    if (_disposed) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        final metrics = await _channel.invokeMapMethod<String, dynamic>(
          'metrics',
        );
        if (_disposed || metrics == null) return;
        final cutout = _insets(metrics['cutout']);
        final bars = _insets(metrics['bars']);
        if (cutout != _cutout || bars != _bars) {
          _cutout = cutout;
          _bars = bars;
          notifyListeners();
        }
      } while (_refreshAgain && !_disposed);
    } on MissingPluginException {
      // MediaQuery remains the safe fallback when native metrics are absent.
    } on Object catch (error) {
      debugPrint('Reader window metrics failed: $error');
    } finally {
      _refreshing = false;
    }
  }

  static EdgeInsets? _insets(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    final values = raw.whereType<num>().map((v) => v.toDouble()).toList();
    if (values.length != 4 || values.any((v) => !v.isFinite || v < 0)) {
      return null;
    }
    return EdgeInsets.fromLTRB(values[0], values[1], values[2], values[3]);
  }

  @override
  void didChangeMetrics() {
    unawaited(_refreshMetrics());
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final keyboard = views.any((view) => view.viewInsets.bottom > 0);
    if (_keyboardVisible && !keyboard) _scheduleRestore();
    _keyboardVisible = keyboard;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshMetrics());
      _scheduleRestore();
    } else {
      _restoreTimer?.cancel();
    }
  }

  void _scheduleRestore() {
    _restoreTimer?.cancel();
    // Android temporarily owns overlays during IME dismissal. The latest
    // requested chrome state wins, including a modal opened in the meantime.
    _restoreTimer = Timer(const Duration(milliseconds: 1100), () {
      if (!_disposed) unawaited(showChrome(_visible));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _restoreTimer?.cancel();
    unawaited(_enqueueChrome(true));
    super.dispose();
  }
}
