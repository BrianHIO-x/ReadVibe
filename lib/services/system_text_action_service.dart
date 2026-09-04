import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SystemTextActionType { translate, search }

extension SystemTextActionTypeName on SystemTextActionType {
  String get platformName => name;
}

class SystemTextActionTarget {
  final String id;
  final String label;
  final String packageName;
  final String componentName;
  final String intentKind;
  final bool available;

  const SystemTextActionTarget({
    required this.id,
    required this.label,
    required this.packageName,
    required this.componentName,
    required this.intentKind,
    required this.available,
  });

  factory SystemTextActionTarget.fromMap(Map<Object?, Object?> map) {
    return SystemTextActionTarget(
      id: map['id'] as String? ?? '',
      label: map['label'] as String? ?? '',
      packageName: map['packageName'] as String? ?? '',
      componentName: map['componentName'] as String? ?? '',
      intentKind: map['intentKind'] as String? ?? '',
      available: map['available'] as bool? ?? false,
    );
  }
}

/// Uses Android's PackageManager as the source of truth, then applies the
/// product allowlist before anything reaches the visible picker.
class SystemTextActionService {
  static const _channel = MethodChannel('com.readvibe.app/system_text_actions');
  static const _defaultTranslateKey = 'text_action_default_translate_v1';
  static const _defaultSearchKey = 'text_action_default_search_v1';
  static const _aiPackages = <String, (String, String)>{
    'com.deepseek.chat': ('deepseek', 'DeepSeek'),
    'com.openai.chatgpt': ('chatgpt', 'ChatGPT'),
    'com.google.android.apps.bard': ('gemini', 'Gemini'),
    'com.anthropic.claude': ('claude', 'Claude'),
    'com.microsoft.copilot': ('copilot', 'Microsoft Copilot'),
    'ai.perplexity.app.android': ('perplexity', 'Perplexity'),
  };

  static Future<List<SystemTextActionTarget>> getTargets(
    SystemTextActionType action,
  ) async {
    final raw = await _channel.invokeListMethod<Object?>('getTargets', {
      'action': action.platformName,
    });
    final systemTargets = (raw ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(SystemTextActionTarget.fromMap)
        .where((target) => target.available)
        .toList(growable: false);
    if (action == SystemTextActionType.translate) {
      final byPackage = <String, SystemTextActionTarget>{
        for (final target in systemTargets) target.packageName: target,
      };
      return [
        for (final entry in _aiPackages.entries)
          if (byPackage[entry.key] case final resolved?)
            SystemTextActionTarget(
              id: entry.value.$1,
              label: entry.value.$2,
              packageName: resolved.packageName,
              componentName: resolved.componentName,
              intentKind: resolved.intentKind,
              available: true,
            ),
      ];
    }

    SystemTextActionTarget? browser(String packageName) {
      for (final target in systemTargets) {
        if (target.packageName == packageName) return target;
      }
      return null;
    }

    final edge = browser('com.microsoft.emmx');
    final chrome = browser('com.android.chrome');
    return [
      _browserTarget('edge', 'edge', edge),
      _browserTarget('chrome', 'chrome', chrome),
      SystemTextActionTarget(
        id: 'system',
        label: '系统浏览器',
        packageName: '',
        componentName: '',
        intentKind: 'view',
        available: systemTargets.isNotEmpty,
      ),
    ];
  }

  static SystemTextActionTarget _browserTarget(
    String id,
    String label,
    SystemTextActionTarget? resolved,
  ) {
    return SystemTextActionTarget(
      id: id,
      label: label,
      packageName: resolved?.packageName ?? '',
      componentName: resolved?.componentName ?? '',
      intentKind: 'view',
      available: resolved != null,
    );
  }

  static Future<bool> launch({
    required SystemTextActionType action,
    required SystemTextActionTarget target,
    required String text,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty || target.id.isEmpty || !target.available) {
      return false;
    }
    return await _channel.invokeMethod<bool>('launch', {
          'action': action.platformName,
          'targetId': target.id,
          'packageName': target.packageName,
          'componentName': target.componentName,
          'intentKind': target.intentKind,
          'text': normalized,
        }) ??
        false;
  }

  static Future<String?> getDefaultTargetId(SystemTextActionType action) async {
    final prefs = await SharedPreferences.getInstance();
    final target = prefs.getString(_preferenceKey(action))?.trim();
    return target == null || target.isEmpty ? null : target;
  }

  static Future<void> setDefaultTargetId(
    SystemTextActionType action,
    String? targetId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = targetId?.trim();
    if (normalized == null || normalized.isEmpty) {
      await prefs.remove(_preferenceKey(action));
    } else {
      await prefs.setString(_preferenceKey(action), normalized);
    }
  }

  static Future<void> clearDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove(_defaultTranslateKey),
      prefs.remove(_defaultSearchKey),
    ]);
  }

  static String _preferenceKey(SystemTextActionType action) {
    return action == SystemTextActionType.translate
        ? _defaultTranslateKey
        : _defaultSearchKey;
  }
}
