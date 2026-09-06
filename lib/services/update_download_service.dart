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
  const UpdateDownloadProgress(
    this.received,
    this.total,
    this.source, {
    this.bytesPerSecond = 0,
    this.probing = false,
  });
  final int received;
  final int total;
  final String source;

  /// Throughput over the last second, 0 until a full second has been measured.
  final double bytesPerSecond;

  /// True while the lines are being raced and no bytes are being kept yet.
  final bool probing;

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

/// One line and the throughput it showed during the probe, in bytes per second.
/// A line that never answered scores 0 and sorts behind every line that did.
class _ProbedSource {
  const _ProbedSource(this.uri, this.order, this.rate);
  final Uri uri;
  final int order;
  final double rate;
  bool get answered => rate > 0;
}

/// Abandons a line that a probed alternative can clearly beat. It carries no
/// message because the user never sees it; the switch itself is the outcome.
class _SlowSource implements Exception {
  const _SlowSource();
}

/// Streams into a private partial file; only complete, verified bytes become an APK.
class UpdateDownloadService implements UpdateDownloader {
  UpdateDownloadService({
    Future<Directory> Function()? directoryProvider,
    List<Uri> Function(AppUpdateInfo)? sources,
    this.connectTimeout = const Duration(seconds: 5),
    this.idleTimeout = const Duration(seconds: 15),
    this.probeWindow = const Duration(milliseconds: 1200),
    this.slowWindow = const Duration(seconds: 6),
  }) : _directoryProvider = directoryProvider ?? getTemporaryDirectory,
       _sources = sources ?? downloadSources;

  static const _channel = MethodChannel('com.readvibe.app/app_update');

  /// Sample size per line. Large enough that a fast line is judged on bandwidth
  /// rather than on a single packet, small enough that racing four lines costs
  /// a couple of megabytes at worst.
  static const _probeBytes = 512 * 1024;

  final Future<Directory> Function() _directoryProvider;
  final List<Uri> Function(AppUpdateInfo) _sources;
  final Duration connectTimeout;
  final Duration idleTimeout;

  /// How long a single line is sampled before the race is decided.
  final Duration probeWindow;

  /// How long a line has to stay behind a rival before it is given up on.
  final Duration slowWindow;

  final Set<HttpClient> _clients = {};
  bool _cancelled = false;
  bool _running = false;

  /// Direct GitHub first, then mirrors that were verified to serve release
  /// assets from mainland networks. Unlike the release feed, these mirrors only
  /// pass through file downloads, so they are not interchangeable with the
  /// endpoints in [UpdateService]. This order is only the tie-break; the probe
  /// decides which line actually carries the download.
  static List<Uri> downloadSources(AppUpdateInfo info) => [
    Uri.parse(info.apkUrl),
    Uri.parse('https://ghfast.top/${info.apkUrl}'),
    Uri.parse('https://gh-proxy.com/${info.apkUrl}'),
    Uri.parse('https://ghproxy.net/${info.apkUrl}'),
  ];

  @override
  void cancel() {
    _cancelled = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  void _checkCancelled() {
    if (_cancelled) throw UpdateDownloadCancelled();
  }

  /// Races every line over a short ranged read and returns them fastest first,
  /// so the download starts on the quickest line instead of on whichever one
  /// happens to be listed first.
  Future<List<_ProbedSource>> _rankSources(
    List<Uri> sources,
    AppUpdateInfo info,
    void Function(UpdateDownloadProgress) onProgress,
  ) async {
    if (sources.length < 2) {
      return [
        for (var index = 0; index < sources.length; index++)
          _ProbedSource(sources[index], index, 0),
      ];
    }
    onProgress(
      UpdateDownloadProgress(
        0,
        info.apkSize,
        '正在测速 ${sources.length} 条线路…',
        probing: true,
      ),
    );
    final probed = await Future.wait([
      for (var index = 0; index < sources.length; index++)
        _probe(sources[index], index),
    ]);
    _checkCancelled();
    // A probe failure is often transient, and the direct GitHub URL is the one
    // source that is not a third-party relay. Unanswered lines therefore keep
    // their declared order at the back rather than being dropped.
    return probed.toList()
      ..sort((a, b) {
        if (a.answered != b.answered) return a.answered ? -1 : 1;
        if (a.answered) return b.rate.compareTo(a.rate);
        return a.order.compareTo(b.order);
      });
  }

  Future<_ProbedSource> _probe(Uri uri, int order) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    _clients.add(client);
    try {
      return await _measure(
        client,
        uri,
        order,
      ).timeout(connectTimeout + probeWindow);
    } on Object {
      return _ProbedSource(uri, order, 0);
    } finally {
      _clients.remove(client);
      // Ends the sample immediately, including when the timeout above fired.
      client.close(force: true);
    }
  }

  /// Times the bytes that arrive after the first chunk, so a line is judged on
  /// throughput instead of on how quickly it answered. Connecting is a fixed
  /// cost the whole download pays once, at the start.
  Future<_ProbedSource> _measure(HttpClient client, Uri uri, int order) async {
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'ReadVibe-Android');
    request.headers.set('Range', 'bytes=0-${_probeBytes - 1}');
    final response = await request.close();
    if (response.statusCode != 200 && response.statusCode != 206) {
      return _ProbedSource(uri, order, 0);
    }
    final clock = Stopwatch();
    var timed = 0;
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (clock.isRunning) {
        timed += chunk.length;
      } else {
        clock.start();
      }
      if (total >= _probeBytes || clock.elapsed >= probeWindow) break;
    }
    clock.stop();
    if (total <= 0) return _ProbedSource(uri, order, 0);
    // A line that delivered the whole sample in one chunk is faster than the
    // probe can resolve, so it is credited with everything that arrived.
    final measured = timed > 0 ? timed : total;
    final micros = clock.elapsedMicroseconds < 1
        ? 1
        : clock.elapsedMicroseconds;
    return _ProbedSource(uri, order, measured * 1000000 / micros);
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
      final sources = await _rankSources(_sources(info), info, onProgress);
      // Leaving a line costs everything downloaded so far unless the bytes can
      // be carried over, and appending across two relays is only safe when the
      // joined file is checked against a digest.
      final canResume = info.sha256 != null;
      Object? lastError;
      var resumeFrom = 0;
      for (var index = 0; index < sources.length; index++) {
        _checkCancelled();
        final uri = sources[index].uri;
        final label = '线路 ${index + 1}/${sources.length} · ${uri.host}';
        final rival = index + 1 < sources.length ? sources[index + 1].rate : 0.0;
        final client = HttpClient()..connectionTimeout = connectTimeout;
        _clients.add(client);
        var received = resumeFrom;
        try {
          onProgress(UpdateDownloadProgress(received, info.apkSize, label));
          final response = await (() async {
            final request = await client.getUrl(uri);
            request.headers.set('User-Agent', 'ReadVibe-Android');
            if (resumeFrom > 0) {
              request.headers.set('Range', 'bytes=$resumeFrom-');
            }
            return request.close();
          })().timeout(connectTimeout);
          if (response.statusCode != 200 && response.statusCode != 206) {
            throw const UpdateDownloadException('下载线路返回了无效文件');
          }
          // A relay that ignores the range answers 200 with the whole file, so
          // the carried-over bytes are dropped and this line starts from zero.
          if (response.statusCode == 200) received = 0;
          if (response.contentLength >= 0 &&
              response.contentLength != info.apkSize - received) {
            throw const UpdateDownloadException('下载线路返回了无效文件');
          }
          final output = await partial.open(
            mode: received > 0 ? FileMode.append : FileMode.write,
          );
          final clock = Stopwatch()..start();
          var lastProgress = 0;
          var windowStart = 0;
          var windowBase = received;
          var slowMillis = 0;
          var rate = 0.0;
          try {
            await for (final chunk in response.timeout(idleTimeout)) {
              _checkCancelled();
              received += chunk.length;
              if (received > info.apkSize) {
                throw const UpdateDownloadException('安装包大小不符');
              }
              await output.writeFrom(chunk);
              final elapsed = clock.elapsedMilliseconds;
              final window = elapsed - windowStart;
              if (window >= 1000) {
                rate = (received - windowBase) * 1000 / window;
                // A rival that never answered scores 0, which no rate falls
                // below, so an unprobed line is never switched to on speed.
                slowMillis = rate < rival / 2 ? slowMillis + window : 0;
                windowStart = elapsed;
                windowBase = received;
                if (slowMillis >= slowWindow.inMilliseconds &&
                    canResume &&
                    received * 10 < info.apkSize * 9) {
                  throw const _SlowSource();
                }
              }
              if (elapsed - lastProgress >= 100 || received == info.apkSize) {
                lastProgress = elapsed;
                onProgress(
                  UpdateDownloadProgress(
                    received,
                    info.apkSize,
                    label,
                    bytesPerSecond: rate,
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
          if (error is FileSystemException) {
            if (await partial.exists()) await partial.delete();
            throw const UpdateDownloadException('无法保存安装包，请检查剩余存储空间');
          }
          // Hand the bytes already on disk to the next line while the digest can
          // vouch for the joined file. A complete but rejected file is worthless
          // to a resume, so it goes instead of being appended to.
          resumeFrom = 0;
          if (await partial.exists()) {
            final length = await partial.length();
            if (canResume && length > 0 && length < info.apkSize) {
              resumeFrom = length;
            } else {
              await partial.delete();
            }
          }
          if (error is! _SlowSource) lastError = error;
        } finally {
          _clients.remove(client);
          client.close(force: true);
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
