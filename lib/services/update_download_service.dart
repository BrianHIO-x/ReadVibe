import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  const _ProbedSource(this.uri, this.order, this.rate, this.prefix);
  final Uri uri;
  final int order;
  final double rate;

  /// The first bytes of the file as this line delivered them during the probe.
  final Uint8List prefix;
  bool get answered => rate > 0;

  /// Mirror relays are built for mainland networks. Direct GitHub is the one
  /// line that leaves the country, so it only leads when it is clearly faster.
  bool get domestic => uri.host != 'github.com';
}

/// Bytes and timing one line has delivered so far during the probe.
class _ProbeSample {
  _ProbeSample(this.uri, this.order);
  final Uri uri;
  final int order;
  final _bytes = BytesBuilder(copy: false);
  final _clock = Stopwatch();
  int _received = 0;
  int _timed = 0;
  bool complete = false;

  int get total => _received;

  void add(List<int> chunk, int limit, {bool keepBytes = true}) {
    final room = limit - _received;
    if (room <= 0) return;
    final count = math.min(chunk.length, room);
    if (keepBytes) {
      _bytes.add(count == chunk.length ? chunk : chunk.sublist(0, count));
    }
    _received += count;
    // Timing starts at the first chunk, so a line is judged on throughput
    // instead of on how quickly it answered.
    if (_clock.isRunning) {
      _timed += count;
    } else {
      _clock.start();
    }
    if (_received >= limit) complete = true;
  }

  /// Freezes the clock when the line stops, before the other lines finish.
  void finish() => _clock.stop();

  _ProbedSource result(Duration window) {
    final prefix = _bytes.takeBytes();
    if (_received == 0) return _ProbedSource(uri, order, 0, prefix);
    final micros = math.max(1, _clock.elapsedMicroseconds);
    final double rate;
    if (_timed > 0) {
      rate = _timed * 1000000 / micros;
    } else if (complete) {
      // The whole sample came in one chunk, faster than the probe can resolve.
      rate = _received * 1000000.0;
    } else {
      // A single chunk and then silence: credited over the whole window.
      rate = _received * 1000000 / math.max(1, window.inMicroseconds);
    }
    return _ProbedSource(uri, order, rate, prefix);
  }
}

/// Abandons a line that is too slow or that a probed alternative can clearly
/// beat. It carries no message because the user never sees it; the switch
/// itself is the outcome.
class _SlowSource implements Exception {
  const _SlowSource(this.measuredRate);
  final double measuredRate;
}

/// Streams into a private partial file; only complete, verified bytes become an APK.
class UpdateDownloadService implements UpdateDownloader {
  UpdateDownloadService({
    Future<Directory> Function()? directoryProvider,
    List<Uri> Function(AppUpdateInfo)? sources,
    Future<String?> Function()? loadLastSource,
    Future<void> Function(String source)? saveLastSource,
    this.connectTimeout = const Duration(seconds: 5),
    this.idleTimeout = const Duration(seconds: 15),
    this.probeDeadline = const Duration(seconds: 3),
    this.probeGrace = const Duration(milliseconds: 800),
    this.slowWindow = const Duration(seconds: 6),
    this.lowSpeedThreshold = 512 * 1024.0,
  }) : _directoryProvider = directoryProvider ?? getTemporaryDirectory,
       _sources = sources ?? downloadSources,
       _loadLastSource = loadLastSource ?? _readLastSource,
       _saveLastSource = saveLastSource ?? _writeLastSource;

  static const _channel = MethodChannel('com.readvibe.app/app_update');
  static const _lastSourceKey = 'update_last_download_source';

  /// Sample size per line. Large enough that a fast line is judged past its
  /// TCP slow start, and the winner's sample is kept as the start of the
  /// resumed segment, so the race costs only what the losing lines fetched.
  static const _probeBytes = 1024 * 1024;

  /// How much faster direct GitHub has to be before it leads the mirrors.
  static const _overseasMargin = 1.5;

  final Future<Directory> Function() _directoryProvider;
  final List<Uri> Function(AppUpdateInfo) _sources;
  final Future<String?> Function() _loadLastSource;
  final Future<void> Function(String source) _saveLastSource;
  final Duration connectTimeout;
  final Duration idleTimeout;

  /// Longest the race may take, connecting included. A line that has not
  /// answered by then is ranked on whatever it delivered.
  final Duration probeDeadline;

  /// Once one line finishes its sample, how long the rest still get.
  final Duration probeGrace;

  /// How long a line has to stay below the threshold before switching.
  final Duration slowWindow;

  /// Minimum throughput expected from the initial unprobed line before backup
  /// speed-testing is triggered.
  final double lowSpeedThreshold;

  final Set<HttpClient> _clients = {};
  bool _cancelled = false;
  bool _running = false;

  static String _sourceKey(Uri uri) =>
      uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;

  static double _sourceScore(_ProbedSource source) =>
      source.domestic ? source.rate : source.rate / _overseasMargin;

  static Future<String?> _readLastSource() async =>
      (await SharedPreferences.getInstance()).getString(_lastSourceKey);

  static Future<void> _writeLastSource(String source) async {
    await (await SharedPreferences.getInstance()).setString(
      _lastSourceKey,
      source,
    );
  }

  Future<String?> _loadLastSourceSafe() async {
    try {
      return await _loadLastSource();
    } on Object {
      return null;
    }
  }

  Future<void> _saveLastSourceSafe(String source) async {
    try {
      await _saveLastSource(source);
    } on Object {
      // Remembering the winning route is best-effort and must not fail the install.
    }
  }

  /// Mainland mirror relays first, direct GitHub last. Every relay here was
  /// measured to serve ranged release downloads without redirecting. The
  /// gh-proxy family moved to `.org`, and its `.com` names now answer with a
  /// redirect, so the `.org` hosts are listed directly. ghproxy.net was
  /// dropped after it took nine seconds to send its first byte. This order is
  /// only the tie-break; the race decides which line carries the download.
  static List<Uri> downloadSources(AppUpdateInfo info) => [
    for (final relay in mirrorHosts) Uri.parse('https://$relay/${info.apkUrl}'),
    Uri.parse(info.apkUrl),
  ];

  /// Relays that pass GitHub release downloads through for mainland networks.
  static const mirrorHosts = [
    'edgeone.gh-proxy.org',
    'gh-proxy.org',
    'cdn.gh-proxy.org',
    'gh-proxy.com',
    'hk.gh-proxy.org',
    'ghfast.top',
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

  /// Races backup lines over a short ranged read from [offset] and returns
  /// them fastest first, so switching skips slow lines instead of guessing.
  Future<List<_ProbedSource>> _rankSources(
    List<Uri> sources,
    AppUpdateInfo info,
    void Function(UpdateDownloadProgress) onProgress, {
    int offset = 0,
    bool probeSingle = false,
    String? probingLabel,
  }) async {
    if (sources.isEmpty) return const [];
    if (sources.length < 2 && !probeSingle) {
      return [
        for (var index = 0; index < sources.length; index++)
          _ProbedSource(sources[index], index, 0, Uint8List(0)),
      ];
    }
    final limit = math.min(_probeBytes, info.apkSize - offset);
    if (limit <= 0) {
      return [
        for (var index = 0; index < sources.length; index++)
          _ProbedSource(sources[index], index, 0, Uint8List(0)),
      ];
    }
    onProgress(
      UpdateDownloadProgress(
        offset,
        info.apkSize,
        probingLabel ?? '正在测速 ${sources.length} 条备用线路…',
        probing: true,
      ),
    );
    final samples = [
      for (var index = 0; index < sources.length; index++)
        _ProbeSample(sources[index], index),
    ];
    final stop = Completer<void>();
    void stopRace() {
      if (!stop.isCompleted) stop.complete();
    }

    final deadline = Timer(probeDeadline, stopRace);
    Timer? grace;
    await Future.wait([
      for (final sample in samples)
        _probe(sample, offset, limit, stop.future, () {
          grace ??= Timer(probeGrace, stopRace);
        }),
    ]);
    deadline.cancel();
    grace?.cancel();
    stopRace();
    _checkCancelled();
    final probed = [for (final sample in samples) sample.result(probeDeadline)];
    // A probe failure is often transient, so unanswered lines keep their
    // declared order at the back rather than being dropped.
    return probed..sort((a, b) {
      if (a.answered != b.answered) return a.answered ? -1 : 1;
      if (a.answered) return _sourceScore(b).compareTo(_sourceScore(a));
      return a.order.compareTo(b.order);
    });
  }

  Future<void> _probe(
    _ProbeSample sample,
    int offset,
    int limit,
    Future<void> stop,
    void Function() onSampled,
  ) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    _clients.add(client);
    // Closing the client ends a pending connection or a stream at once, so
    // the race stops on time even for a line that has gone quiet.
    unawaited(stop.then((_) => client.close(force: true)));
    try {
      await (() async {
        final request = await client.getUrl(sample.uri);
        request.headers.set('User-Agent', 'ReadVibe-Android');
        request.headers.set('Range', 'bytes=$offset-${offset + limit - 1}');
        final response = await request.close();
        if (response.statusCode != 200 && response.statusCode != 206) return;
        if (response.statusCode == 206 && !_rangeStartsAt(response, offset)) {
          return;
        }
        // Only bytes starting at [offset] can be appended to the partial file.
        final keepBytes = offset == 0 || response.statusCode == 206;
        await for (final chunk in response) {
          sample.add(chunk, limit, keepBytes: keepBytes);
          if (sample.complete) {
            onSampled();
            break;
          }
        }
      })().timeout(probeDeadline);
    } on Object {
      // Stopped, refused or reset. Whatever arrived still counts.
    } finally {
      sample.finish();
      _clients.remove(client);
      client.close(force: true);
    }
  }

  /// A relay that answers a ranged read from some other offset would put the
  /// wrong bytes at the resume point.
  static bool _rangeStartsAt(HttpClientResponse response, int offset) {
    final range = response.headers.value(HttpHeaders.contentRangeHeader);
    if (range == null) return offset == 0;
    return range.trim().startsWith('bytes $offset-');
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
      final allSources = _sources(info);
      if (allSources.isEmpty) {
        throw const UpdateDownloadException('下载线路暂时不可用，请检查网络后重试');
      }
      final lastKey = await _loadLastSourceSafe();
      final matchedIndex = lastKey == null
          ? -1
          : allSources.indexWhere((uri) => _sourceKey(uri) == lastKey);
      final usedSavedSource = matchedIndex >= 0;
      final initialIndex = usedSavedSource ? matchedIndex : 0;
      final initialSource = allSources[initialIndex];
      final unprobedAlternatives = <Uri>[
        for (var i = 0; i < allSources.length; i++)
          if (i != initialIndex) allSources[i],
      ];
      // Leaving a line costs everything downloaded so far unless the bytes can
      // be carried over, and appending across two relays is only safe when the
      // joined file is checked against a digest.
      final canResume = info.sha256 != null;
      Object? lastError;
      var resumeFrom = 0;
      var hasProbed = false;
      var queue = <_ProbedSource>[
        _ProbedSource(initialSource, 0, 0, Uint8List(0)),
      ];

      for (var index = 0; index < queue.length; index++) {
        _checkCancelled();
        final current = queue[index];
        final uri = current.uri;
        final label = hasProbed
            ? '线路 ${index + 1}/${queue.length} · ${uri.host}'
            : '${usedSavedSource ? '上次线路' : '默认线路'} · ${uri.host}';
        final rival = hasProbed && index + 1 < queue.length
            ? queue[index + 1].rate
            : 0.0;
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
          if (response.statusCode == 206 && !_rangeStartsAt(response, received)) {
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
          var slowBytes = 0;
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
                final windowBytes = received - windowBase;
                rate = windowBytes * 1000 / window;
                final threshold = !hasProbed && unprobedAlternatives.isNotEmpty
                    ? lowSpeedThreshold
                    : rival / 2;
                // Before probing, an unprobed primary triggers backup racing
                // when it stays below [lowSpeedThreshold]; after probing, a
                // line yields only when a probed rival is over twice as fast.
                if (threshold > 0 && rate < threshold) {
                  slowMillis += window;
                  slowBytes += windowBytes;
                } else {
                  slowMillis = 0;
                  slowBytes = 0;
                }
                windowStart = elapsed;
                windowBase = received;
                final shouldSwitch = !hasProbed && unprobedAlternatives.isNotEmpty
                    ? slowMillis >= slowWindow.inMilliseconds &&
                          (canResume || received * 10 < info.apkSize) &&
                          received * 10 < info.apkSize * 9
                    : slowMillis >= slowWindow.inMilliseconds &&
                          canResume &&
                          received * 10 < info.apkSize * 9;
                if (shouldSwitch) {
                  throw _SlowSource(slowBytes * 1000 / slowMillis);
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
          final finished = await partial.rename(target.path);
          await _saveLastSourceSafe(_sourceKey(uri));
          return finished;
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
          if (!hasProbed && unprobedAlternatives.isNotEmpty) {
            hasProbed = true;
            final isSlow = error is _SlowSource;
            final ranked = await _rankSources(
              unprobedAlternatives,
              info,
              onProgress,
              offset: resumeFrom,
              probeSingle: isSlow,
              probingLabel: isSlow
                  ? '当前线路较慢，正在测速 ${unprobedAlternatives.length} 条备用线路…'
                  : '当前线路不可用，正在测速 ${unprobedAlternatives.length} 条备用线路…',
            );
            if (error is _SlowSource) {
              final slowPrimary = _ProbedSource(
                current.uri,
                allSources.length,
                error.measuredRate,
                Uint8List(0),
              );
              final best = ranked.firstOrNull;
              final switchToAlternative =
                  best != null &&
                  best.answered &&
                  _sourceScore(best) > _sourceScore(slowPrimary);
              if (switchToAlternative) {
                queue = [...ranked, slowPrimary];
                final head = best.prefix;
                if (canResume &&
                    head.isNotEmpty &&
                    resumeFrom + head.length < info.apkSize) {
                  await partial.writeAsBytes(
                    head,
                    mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
                    flush: true,
                  );
                  resumeFrom += head.length;
                }
              } else {
                queue = [slowPrimary, ...ranked];
              }
            } else {
              queue = ranked;
              final head = queue.isEmpty ? Uint8List(0) : queue.first.prefix;
              if (canResume &&
                  head.isNotEmpty &&
                  resumeFrom + head.length < info.apkSize) {
                await partial.writeAsBytes(
                  head,
                  mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
                  flush: true,
                );
                resumeFrom += head.length;
              }
            }
            index = -1;
          }
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
