import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

enum UpdateInstallResult { started, permissionRequired }

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdateDownloadCancelled implements Exception {}

class UpdateDownloadProgress {
  const UpdateDownloadProgress(this.received, this.total, this.source);
  final int received;
  final int total;
  final String source;
  double get fraction => total > 0 ? (received / total).clamp(0, 1) : 0;
}

abstract interface class UpdateDownloader {
  Future<File> download(
    AppUpdateInfo info,
    void Function(UpdateDownloadProgress) onProgress,
  );
  Future<UpdateInstallResult> install(File file, AppUpdateInfo info);
  void cancel();
}

/// Streams into a private partial file; only complete, verified bytes become an APK.
class UpdateDownloadService implements UpdateDownloader {
  UpdateDownloadService({
    Future<Directory> Function()? directoryProvider,
    List<Uri> Function(AppUpdateInfo)? sources,
    this.connectTimeout = const Duration(seconds: 5),
    this.idleTimeout = const Duration(seconds: 15),
  }) : _directoryProvider = directoryProvider ?? getTemporaryDirectory,
       _sources = sources ?? downloadSources;

  static const _channel = MethodChannel('com.readvibe.app/app_update');
  final Future<Directory> Function() _directoryProvider;
  final List<Uri> Function(AppUpdateInfo) _sources;
  final Duration connectTimeout;
  final Duration idleTimeout;
  HttpClient? _client;
  bool _cancelled = false;
  bool _running = false;

  /// Direct GitHub first, then mirrors that were verified to serve release
  /// assets from mainland networks. Unlike the release feed, these mirrors only
  /// pass through file downloads, so they are not interchangeable with the
  /// endpoints in [UpdateService].
  static List<Uri> downloadSources(AppUpdateInfo info) => [
    Uri.parse(info.apkUrl),
    Uri.parse('https://ghfast.top/${info.apkUrl}'),
    Uri.parse('https://gh-proxy.com/${info.apkUrl}'),
    Uri.parse('https://ghproxy.net/${info.apkUrl}'),
  ];

  @override
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _checkCancelled() {
    if (_cancelled) throw UpdateDownloadCancelled();
  }

  @override
  Future<File> download(
    AppUpdateInfo info,
    void Function(UpdateDownloadProgress) onProgress,
  ) async {
    if (_running) throw const UpdateDownloadException('已有下载正在进行');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(info.version) ||
        info.apkSize <= 0 ||
        info.apkSize > 200 * 1024 * 1024) {
      throw const UpdateDownloadException('安装包信息无效，请重新检查更新');
    }
    _running = true;
    _cancelled = false;
    Directory? session;
    try {
      final root = Directory(
        '${(await _directoryProvider()).path}/readvibe_updates',
      );
      await root.create(recursive: true);
      _checkCancelled();
      // Restrict cleanup to old sessions; never remove an installer's fresh file.
      final stale = DateTime.now().subtract(const Duration(days: 2));
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory &&
            (await entry.stat()).modified.isBefore(stale)) {
          await entry.delete(recursive: true);
        }
      }
      session = await root.createTemp('download-');
      final partial = File('${session.path}/update.part');
      final target = File('${session.path}/ReadVibe-${info.version}.apk');
      Object? lastError;
      final sources = _sources(info);
      for (var index = 0; index < sources.length; index++) {
        _checkCancelled();
        final uri = sources[index];
        final client = HttpClient()..connectionTimeout = connectTimeout;
        _client = client;
        try {
          onProgress(
            UpdateDownloadProgress(
              0,
              info.apkSize,
              '线路 ${index + 1}/${sources.length} · ${uri.host}',
            ),
          );
          final response = await (() async {
            final request = await client.getUrl(uri);
            request.headers.set('User-Agent', 'ReadVibe-Android');
            return request.close();
          })().timeout(connectTimeout);
          if (response.statusCode != 200 ||
              (response.contentLength >= 0 &&
                  response.contentLength != info.apkSize)) {
            throw const UpdateDownloadException('下载线路返回了无效文件');
          }
          final output = await partial.open(mode: FileMode.write);
          var received = 0;
          final clock = Stopwatch()..start();
          var lastProgress = 0;
          try {
            await for (final chunk in response.timeout(idleTimeout)) {
              _checkCancelled();
              received += chunk.length;
              if (received > info.apkSize) {
                throw const UpdateDownloadException('安装包大小不符');
              }
              await output.writeFrom(chunk);
              if (clock.elapsedMilliseconds - lastProgress >= 100 ||
                  received == info.apkSize) {
                lastProgress = clock.elapsedMilliseconds;
                onProgress(
                  UpdateDownloadProgress(
                    received,
                    info.apkSize,
                    '线路 ${index + 1}/${sources.length} · ${uri.host}',
                  ),
                );
              }
            }
          } finally {
            await output.close();
          }
          _checkCancelled();
          if (received != info.apkSize) {
            throw const UpdateDownloadException('下载不完整');
          }
          final header = await partial.open();
          late List<int> magic;
          try {
            magic = await header.read(4);
          } finally {
            await header.close();
          }
          if (magic.length < 4 ||
              magic[0] != 0x50 ||
              magic[1] != 0x4b ||
              magic[2] != 3 ||
              magic[3] != 4) {
            throw const UpdateDownloadException('下载结果不是 APK 文件');
          }
          if (info.sha256 != null) {
            final actual = await sha256.bind(partial.openRead()).first;
            if (actual.toString() != info.sha256!.toLowerCase()) {
              throw const UpdateDownloadException('安装包校验失败，请重新检查更新后重试');
            }
          }
          _checkCancelled();
          return await partial.rename(target.path);
        } on Object catch (error) {
          _checkCancelled();
          lastError = error;
          if (await partial.exists()) await partial.delete();
          if (error is FileSystemException) {
            throw const UpdateDownloadException('无法保存安装包，请检查剩余存储空间');
          }
        } finally {
          client.close(force: true);
          _client = null;
        }
      }
      throw lastError is UpdateDownloadException
          ? lastError
          : const UpdateDownloadException('下载线路暂时不可用，请检查网络后重试');
    } on Object {
      if (session != null && await session.exists()) {
        await session.delete(recursive: true);
      }
      rethrow;
    } finally {
      _running = false;
    }
  }

  @override
  Future<UpdateInstallResult> install(File file, AppUpdateInfo info) async {
    final result = await _channel.invokeMethod<String>('installApk', {
      'path': file.path,
      'version': info.version,
    });
    if (result == 'permissionRequired') {
      return UpdateInstallResult.permissionRequired;
    }
    if (result != 'started') throw const UpdateDownloadException('无法打开系统安装程序');
    return UpdateInstallResult.started;
  }
}
