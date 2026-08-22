import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Release metadata fetched from GitHub for a newer version.
class AppUpdateInfo {
  final String version;
  final String notes;
  final String apkUrl;
  final String apkName;
  final int apkSize;
  final String? sha256;
  final String releasePageUrl;

  const AppUpdateInfo({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
    required this.releasePageUrl,
    this.sha256,
  });
}

/// Outcome of an update check. [info] is set when a newer release exists.
/// [failed] distinguishes "could not reach the release feed" from "already
/// up to date", which the manual check entry needs for its feedback.
class UpdateCheckResult {
  final AppUpdateInfo? info;
  final bool failed;

  const UpdateCheckResult.upToDate() : info = null, failed = false;
  const UpdateCheckResult.available(AppUpdateInfo this.info) : failed = false;
  const UpdateCheckResult.error() : info = null, failed = true;
}

/// Silent update check against the project's GitHub Releases.
///
/// The app is sideloaded, so update checks compare GitHub Releases and hand
/// the release page to the user's browser. ReadVibe itself never requests APK
/// installation permission.
class UpdateService {
  static const _channel = MethodChannel('com.readvibe.app/app_update');
  static const _apiUrl =
      'https://api.github.com/repos/BrianHIO-x/ReadVibe/releases/latest';
  static const _timeout = Duration(seconds: 12);

  /// Checks the release feed: a newer release when available, up-to-date
  /// when the feed answers with the current version, or an error when the
  /// feed cannot be reached or parsed.
  Future<UpdateCheckResult> checkForUpdate() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(_apiUrl)).timeout(_timeout);
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('User-Agent', 'ReadVibe-Android');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        return const UpdateCheckResult.error();
      }
      final body = await utf8.decoder.bind(response).join().timeout(_timeout);
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return const UpdateCheckResult.error();

      final latest = _versionFromTag(json['tag_name'] as String? ?? '');
      if (latest == null) return const UpdateCheckResult.error();
      final current = (await PackageInfo.fromPlatform()).version;
      if (!isNewerVersion(latest, current)) {
        return const UpdateCheckResult.upToDate();
      }

      final assets = json['assets'];
      if (assets is! List) return const UpdateCheckResult.error();
      final apks = assets
          .whereType<Map<String, dynamic>>()
          .where((a) => (a['name'] as String? ?? '').endsWith('.apk'))
          .toList();
      if (apks.isEmpty) return const UpdateCheckResult.error();
      final asset = apks.firstWhere(
        (a) => (a['name'] as String).contains('arm64-v8a'),
        orElse: () => apks.first,
      );
      final url = asset['browser_download_url'] as String?;
      if (url == null || url.isEmpty) return const UpdateCheckResult.error();

      return UpdateCheckResult.available(
        AppUpdateInfo(
          version: latest,
          notes: (json['body'] as String? ?? '').trim(),
          apkUrl: url,
          apkName: asset['name'] as String,
          apkSize: (asset['size'] as num?)?.toInt() ?? 0,
          releasePageUrl:
              json['html_url'] as String? ??
              'https://github.com/BrianHIO-x/ReadVibe/releases/latest',
          sha256: sha256FromNotes(json['body'] as String? ?? ''),
        ),
      );
    } on Object {
      return const UpdateCheckResult.error();
    } finally {
      client.close();
    }
  }

  Future<bool> openReleasePage(AppUpdateInfo info) async {
    try {
      return await _channel.invokeMethod<bool>('openExternalUrl', {
            'url': info.releasePageUrl,
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Compares two three-dotted public versions. Returns true when [remote]
  /// is strictly newer than [current].
  static bool isNewerVersion(String remote, String current) {
    final remoteParts = _parseVersion(remote);
    final currentParts = _parseVersion(current);
    if (remoteParts == null || currentParts == null) return false;
    for (var i = 0; i < 3; i++) {
      if (remoteParts[i] != currentParts[i]) {
        return remoteParts[i] > currentParts[i];
      }
    }
    return false;
  }

  /// Extracts the SHA-256 line recorded in release notes
  /// (`SHA-256：…` or `SHA-256: …`).
  static String? sha256FromNotes(String notes) {
    final match = RegExp('SHA-256[：:]\\s*([0-9a-fA-F]{64})').firstMatch(notes);
    return match?.group(1);
  }

  static String? _versionFromTag(String tag) {
    final cleaned = tag.trim().replaceFirst(RegExp('^[vV]'), '');
    return _parseVersion(cleaned) == null ? null : cleaned;
  }

  static List<int>? _parseVersion(String version) {
    final parts = version.trim().split('.');
    if (parts.length != 3) return null;
    final parsed = parts.map(int.tryParse).toList();
    if (parsed.any((p) => p == null)) return null;
    return parsed.cast<int>();
  }
}
