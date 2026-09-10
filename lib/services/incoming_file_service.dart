import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IncomingBookFile {
  final String path;
  final String name;
  final String mimeType;

  const IncomingBookFile({
    required this.path,
    required this.name,
    required this.mimeType,
  });
}

/// Receives Android ACTION_VIEW files copied into the app cache by the native
/// activity. Copies are consumed serially so two file-manager launches cannot
/// race the shelf import state or overwrite each other's feedback.
class IncomingFileService {
  IncomingFileService._();

  static const _channel = MethodChannel('com.readvibe.app/incoming_file');
  static Future<void> Function(IncomingBookFile file)? _handler;
  static ValueChanged<String>? _errorHandler;
  static bool _consuming = false;
  static bool _consumeAgain = false;

  static Future<void> start(
    Future<void> Function(IncomingBookFile file) handler, {
    ValueChanged<String>? onError,
  }) async {
    _handler = handler;
    _errorHandler = onError;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'available') await _consumePending();
    });
    await _consumePending();
  }

  static void stop() {
    _handler = null;
    _errorHandler = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<void> _consumePending() async {
    if (_consuming) {
      _consumeAgain = true;
      return;
    }
    _consuming = true;
    try {
      do {
        _consumeAgain = false;
        while (_handler != null) {
          final Map<Object?, Object?>? raw;
          try {
            raw = await _channel.invokeMapMethod<Object?, Object?>(
              'consumeNext',
            );
          } on PlatformException catch (error, stackTrace) {
            // The native queue itself is unreachable. Stop draining, and let
            // the next 'available' notification start a fresh attempt.
            _report(error.message, error, stackTrace);
            break;
          }
          if (raw == null) break;
          final path = raw['path'];
          final name = raw['name'];
          if (path is! String ||
              path.isEmpty ||
              name is! String ||
              name.isEmpty) {
            continue;
          }
          final handler = _handler;
          if (handler == null) return;
          try {
            await handler(
              IncomingBookFile(
                path: path,
                name: name,
                mimeType: raw['mimeType'] is String
                    ? raw['mimeType']! as String
                    : '',
              ),
            );
          } on Object catch (error, stackTrace) {
            // One unreadable file must not strand the others already queued
            // behind it; opening five books at once should import four when
            // only one of them is broken.
            _report(
              error is PlatformException ? error.message : null,
              error,
              stackTrace,
            );
          }
        }
      } while (_consumeAgain && _handler != null);
    } finally {
      _consuming = false;
    }
  }

  static void _report(
    String? platformMessage,
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('Failed to receive an external book: $error');
    debugPrintStack(stackTrace: stackTrace);
    final message = platformMessage?.trim();
    _errorHandler?.call(
      message != null && message.isNotEmpty ? message : '无法读取外部文件',
    );
  }
}
