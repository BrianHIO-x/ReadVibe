import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// Release checks are separate from downloading and Android installation.
abstract interface class UpdateChecker {
  Future<UpdateCheckResult> checkForUpdate();

  Future<String> currentVersion();
}

class UpdateService implements UpdateChecker {
  UpdateService({
    List<Uri>? feeds,
    this.versionReader,
    this.timeout = const Duration(seconds: 5),
  }) : _feeds =
           feeds ??
           [Uri.parse(_apiUrl), Uri.parse('https://gh-proxy.com/$_apiUrl')];

  static const _apiUrl =
      'https://api.github.com/repos/BrianHIO-x/ReadVibe/releases/latest';
  final List<Uri> _feeds;
  final Future<String> Function()? versionReader;
  final Duration timeout;
  Future<UpdateCheckResult>? _checking;

  @override
  Future<String> currentVersion() async => versionReader != null
      ? await versionReader!()
      : (await PackageInfo.fromPlatform()).version;

  /// Checks the release feed: a newer release when available, up-to-date
  /// when the feed answers with the current version, or an error when the
  /// feed cannot be reached or parsed.
  @override
  Future<UpdateCheckResult> checkForUpdate() =>
      _checking ??= _check().whenComplete(() => _checking = null);

  Future<UpdateCheckResult> _check() async {
    try {
      final current = await currentVersion();
      for (final feed in _feeds) {
        try {
          return parseRelease(await _readFeed(feed), current);
        } on Object {
          // A blocked/limited endpoint or an HTML proxy error is not "latest".
        }
      }
    } on Object {
      // Package metadata can also be unavailable.
    }
    return const UpdateCheckResult.error();
  }

  Future<Object?> _readFeed(Uri feed) async {
    final client = HttpClient();
    try {
      return await (() async {
        final request = await client.getUrl(feed);
        request.headers.set('Accept', 'application/vnd.github+json');
        request.headers.set('User-Agent', 'ReadVibe-Android');
        request.headers.set('Cache-Control', 'no-cache');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const FormatException('更新线路暂时不可用');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 1024 * 1024) throw const FormatException('版本信息过大');
        }
        return jsonDecode(utf8.decode(bytes));
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  static UpdateCheckResult parseRelease(Object? json, String current) {
    if (json is! Map<String, dynamic> ||
        json['draft'] == true ||
        json['prerelease'] == true) {
      throw const FormatException('无效的正式版本信息');
    }

    final latest = _versionFromTag(json['tag_name'] as String? ?? '');
    if (latest == null || _parseVersion(current) == null) {
      throw const FormatException('版本号无效');
    }
    if (!isNewerVersion(latest, current)) {
      return const UpdateCheckResult.upToDate();
    }

    final assets = json['assets'];
    if (assets is! List) throw const FormatException('缺少安装包');
    final apks = assets
        .whereType<Map<String, dynamic>>()
        .where((a) => (a['name'] as String? ?? '').endsWith('-arm64-v8a.apk'))
        .toList();
    if (apks.isEmpty) throw const FormatException('缺少 arm64 安装包');
    final asset = apks.first;
    final url = asset['browser_download_url'] as String?;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.startsWith('/BrianHIO-x/ReadVibe/releases/download/') ||
        !uri.path.endsWith('/${asset['name']}')) {
      throw const FormatException('安装包来源无效');
    }
    final size = (asset['size'] as num?)?.toInt() ?? 0;
    if (size <= 0 || size > 200 * 1024 * 1024) {
      throw const FormatException('安装包大小无效');
    }
    final digest = asset['digest'] as String? ?? '';
    final hash =
        RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest)?.group(1) ??
        sha256FromNotes(json['body'] as String? ?? '');

    return UpdateCheckResult.available(
      AppUpdateInfo(
        version: latest,
        notes: (json['body'] as String? ?? '').trim(),
        apkUrl: url!,
        apkName: asset['name'] as String,
        apkSize: size,
        releasePageUrl:
            json['html_url'] as String? ??
            'https://github.com/BrianHIO-x/ReadVibe/releases/latest',
        sha256: hash,
      ),
    );
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
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version.trim())) return null;
    final parts = version.trim().split('.');
    if (parts.length != 3) return null;
    final parsed = parts.map(int.tryParse).toList();
    if (parsed.any((p) => p == null)) return null;
    return parsed.cast<int>();
  }
}
