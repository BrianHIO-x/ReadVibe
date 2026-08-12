import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Release metadata fetched from GitHub for a newer version.
class AppUpdateInfo {
  final String version;
  final String notes;
  final String apkUrl;
  final String apkName;
  final int apkSize;
  final String? sha256;

  const AppUpdateInfo({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
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
/// The app is sideloaded, so updates mean: compare versions, download the APK
/// asset, verify it against the SHA-256 recorded in the release notes, then
/// hand it to the system package installer.
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
      final request = await client
          .getUrl(Uri.parse(_apiUrl))
          .timeout(_timeout);
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
          sha256: sha256FromNotes(json['body'] as String? ?? ''),
        ),
      );
    } on Object {
      return const UpdateCheckResult.error();
    } finally {
      client.close();
    }
  }

  /// Downloads the APK into the update cache directory, reporting
  /// received/total bytes through [onProgress]. Verifies SHA-256 when the
  /// release notes carry one.
  Future<File> downloadApk(
    AppUpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates',
    );
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final target = File('${directory.path}${Platform.pathSeparator}'
        'ReadVibe-${info.version}.apk');

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(info.apkUrl));
      request.headers.set('User-Agent', 'ReadVibe-Android');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : info.apkSize;
      final sink = target.openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();

      final expected = info.sha256;
      if (expected != null) {
        final digest = await sha256.bind(target.openRead()).first;
        if (digest.toString().toLowerCase() != expected.toLowerCase()) {
          await target.delete();
          throw const FormatException('安装包校验失败，请重新下载');
        }
      }
      return target;
    } finally {
      client.close();
    }
  }

  /// Whether the user has granted "install unknown apps" for ReadVibe.
  Future<bool> canRequestInstalls() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestInstalls') ?? false;
    } on Object {
      return false;
    }
  }

  /// Opens the system page where the user allows installs from ReadVibe.
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on Object {
      // Settings page unavailable; the install intent will surface the same
      // prompt on most devices.
    }
  }

  /// Hands the downloaded APK to the system package installer.
  Future<bool> installApk(String filePath) async {
    try {
      return await _channel.invokeMethod<bool>(
            'installApk',
            <String, String>{'filePath': filePath},
          ) ??
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
    final match = RegExp(
      'SHA-256[：:]\\s*([0-9a-fA-F]{64})',
    ).firstMatch(notes);
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
