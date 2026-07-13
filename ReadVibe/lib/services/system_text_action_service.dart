import 'package:flutter/services.dart';

/// Delegates explicit translation and search requests to Android system
/// activities. Copy, share, and select-all continue to use Flutter's platform
/// selection callbacks directly.
class SystemTextActionService {
  static const _channel = MethodChannel('com.readvibe.app/system_text_actions');

  static Future<bool> translate(String text) => _invoke('translate', text);

  static Future<bool> search(String text) => _invoke('search', text);

  static Future<bool> _invoke(String action, String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return false;
    return await _channel.invokeMethod<bool>(action, normalized) ?? false;
  }
}
