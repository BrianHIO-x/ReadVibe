import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/reader_bookmark.dart';
import '../models/reader_note.dart';
import '../models/reader_settings.dart';
import 'archive_safety.dart';
import 'storage/chapter_disk_store.dart';
import 'storage_service.dart';
import 'storage_vault_channel.dart';

const kVaultDefaultQuotaBytes = 2 * 1024 * 1024 * 1024;

const kVaultQuotaPresets = <({String label, int bytes})>[
  (label: '512 MB', bytes: 512 * 1024 * 1024),
  (label: '1 GB', bytes: 1024 * 1024 * 1024),
  (label: '2 GB', bytes: 2 * 1024 * 1024 * 1024),
  (label: '4 GB', bytes: 4 * 1024 * 1024 * 1024),
  (label: '不限', bytes: 0),
];

class VaultConfig {
  const VaultConfig({
    this.treeUri,
    this.displayName,
    this.autoSync = true,
    this.includePrivate = false,
    this.quotaBytes = kVaultDefaultQuotaBytes,
    this.lastSyncAt,
    this.lastError,
  });

  final String? treeUri;
  final String? displayName;
  final bool autoSync;
  final bool includePrivate;
  final int quotaBytes;
  final DateTime? lastSyncAt;
  final String? lastError;

  bool get isBound => treeUri != null && treeUri!.isNotEmpty;
  bool get isDirectMode => (treeUri ?? '').startsWith('file://');
}

class VaultStatus {
  const VaultStatus({
    required this.config,
    required this.permissionValid,
    required this.vaultExists,
    required this.usedBytes,
    required this.freeDeviceBytes,
    required this.bookCount,
    required this.privateBookCount,
    required this.staleTmpCount,
    required this.syncing,
  });

  final VaultConfig config;
  final bool permissionValid;
  final bool vaultExists;
  final int usedBytes;
  final int freeDeviceBytes;
  final int bookCount;
  final int privateBookCount;
  final int staleTmpCount;
  final bool syncing;
}

class VaultSyncReport {
  const VaultSyncReport({
    required this.uploadedBooks,
    required this.skippedBooks,
    required this.deletedOrphans,
    required this.totalBytes,
    this.quotaPaused = false,
    this.lowSpacePaused = false,
    this.errorMessage,
  });

  final int uploadedBooks;
  final int skippedBooks;
  final int deletedOrphans;
  final int totalBytes;
  final bool quotaPaused;
  final bool lowSpacePaused;
  final String? errorMessage;

  bool get ok => errorMessage == null && !quotaPaused && !lowSpacePaused;
}

class VaultInspectPreview {
  const VaultInspectPreview({
    required this.bookCount,
    required this.privateBookCount,
    required this.noteCount,
    required this.bookmarkCount,
    required this.hasSettings,
    required this.totalBytes,
    this.updatedAt,
  });

  final int bookCount;
  final int privateBookCount;
  final int noteCount;
  final int bookmarkCount;
  final bool hasSettings;
  final int totalBytes;
  final DateTime? updatedAt;
}

class VaultRestoreReport {
  const VaultRestoreReport({
    required this.restoredBooks,
    required this.updatedBooks,
    required this.mergedNotes,
    required this.mergedBookmarks,
    required this.restoredSettings,
  });

  final int restoredBooks;
  final int updatedBooks;
  final int mergedNotes;
  final int mergedBookmarks;
  final bool restoredSettings;
}

class VaultVerifyReport {
  const VaultVerifyReport({
    required this.validBooks,
    required this.missingFiles,
    required this.removedOrphans,
    required this.removedTmpFiles,
    required this.freedBytes,
  });

  final int validBooks;
  final int missingFiles;
  final int removedOrphans;
  final int removedTmpFiles;
  final int freedBytes;
}

/// Manages uninstall-proof incremental sync & reversible recovery in a user-selected
/// SAF folder (`ReadVibe_Vault/`).
class DataSafetyVaultService {
  DataSafetyVaultService(
    this._storage, {
    this.readAppVersion,
  });

  static const _keyTreeUri = 'readvibe_vault_tree_uri';
  static const _keyDisplayName = 'readvibe_vault_display_name';
  static const _keyAutoSync = 'readvibe_vault_auto_sync';
  static const _keyIncludePrivate = 'readvibe_vault_include_private';
  static const _keyQuotaBytes = 'readvibe_vault_quota_bytes';
  static const _keyLastSyncAt = 'readvibe_vault_last_sync_at';
  static const _keyLastError = 'readvibe_vault_last_error';

  static const _manifestRelPath = 'vault_manifest.json';
  static const _stagingDirName = 'readvibe_vault_staging';
  static const _schemaVersion = 1;
  static const _appRootToken = '{{READVIBE_ROOT}}';
  static const _autoSyncDebounce = Duration(seconds: 4);

  final StorageService _storage;
  final Future<String> Function()? readAppVersion;

  Future<void> _queue = Future<void>.value();
  Timer? _debounceTimer;
  bool _syncing = false;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(StorageVaultChannel.cancelOperations());
  }

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<VaultConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final rawLastSync = prefs.getString(_keyLastSyncAt);
    final rawUri = prefs.getString(_keyTreeUri);
    final rawName = prefs.getString(_keyDisplayName);
    final rawErr = prefs.getString(_keyLastError);
    return VaultConfig(
      treeUri: rawUri != null && rawUri.isNotEmpty ? rawUri : null,
      displayName: rawName != null && rawName.isNotEmpty ? rawName : null,
      autoSync: prefs.getBool(_keyAutoSync) ?? true,
      includePrivate: prefs.getBool(_keyIncludePrivate) ?? false,
      quotaBytes: prefs.getInt(_keyQuotaBytes) ?? kVaultDefaultQuotaBytes,
      lastSyncAt: rawLastSync != null ? DateTime.tryParse(rawLastSync) : null,
      lastError: rawErr != null && rawErr.isNotEmpty ? rawErr : null,
    );
  }

  Future<void> _setLastError(String? message) async {
    final prefs = await SharedPreferences.getInstance();
    if (message == null || message.trim().isEmpty) {
      await prefs.remove(_keyLastError);
    } else {
      await prefs.setString(_keyLastError, message.trim());
    }
  }

  Future<VaultStatus> loadStatus() async {
    final config = await loadConfig();
    var freeBytes = 0;
    try {
      freeBytes = await StorageVaultChannel.deviceFreeBytes();
    } on Object {
      freeBytes = 0;
    }

    if (!config.isBound) {
      return VaultStatus(
        config: config,
        permissionValid: false,
        vaultExists: false,
        usedBytes: 0,
        freeDeviceBytes: freeBytes,
        bookCount: 0,
        privateBookCount: 0,
        staleTmpCount: 0,
        syncing: _syncing,
      );
    }

    VaultTreeAccess? access;
    try {
      access = await StorageVaultChannel.checkTree(config.treeUri!);
    } on Object {
      access = null;
    }
    final valid = access?.valid ?? false;
    if (access != null && access.freeBytes > 0) {
      freeBytes = access.freeBytes;
    }
    if (!valid) {
      return VaultStatus(
        config: config,
        permissionValid: false,
        vaultExists: false,
        usedBytes: 0,
        freeDeviceBytes: freeBytes,
        bookCount: 0,
        privateBookCount: 0,
        staleTmpCount: 0,
        syncing: _syncing,
      );
    }

    var vaultExists = false;
    var usedBytes = 0;
    var staleTmpCount = 0;
    var bookCount = 0;
    var privateBookCount = 0;
    try {
      final listing = await StorageVaultChannel.listVaultFiles(config.treeUri!);
      vaultExists = listing.exists;
      usedBytes = listing.totalBytes;
      staleTmpCount = listing.staleTmpCount;
      final manifest = await _readRemoteManifest(config.treeUri!);
      if (manifest != null) {
        final rawBooks = manifest['books'];
        if (rawBooks is List) {
          bookCount = rawBooks.length;
          for (final item in rawBooks) {
            if (item is Map && item['isPrivate'] == true) {
              privateBookCount++;
            }
          }
        }
      } else {
        bookCount = listing.files
            .where((entry) => entry.relativePath.startsWith('books/'))
            .length;
      }
    } on Object catch (error) {
      debugPrint('Failed to inspect vault status: $error');
    }

    return VaultStatus(
      config: config,
      permissionValid: true,
      vaultExists: vaultExists,
      usedBytes: usedBytes,
      freeDeviceBytes: freeBytes,
      bookCount: bookCount,
      privateBookCount: privateBookCount,
      staleTmpCount: staleTmpCount,
      syncing: _syncing,
    );
  }

  Future<VaultStatus?> bindFolder() async {
    final access = await StorageVaultChannel.pickTree();
    if (access == null || !access.valid) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTreeUri, access.treeUri);
    await prefs.setString(_keyDisplayName, access.displayName);
    await prefs.remove(_keyLastError);
    return loadStatus();
  }

  Future<VaultStatus?> bindDirectFolder(String path) async {
    final access = await StorageVaultChannel.bindLocalDirectory(path);
    if (access == null || !access.valid) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTreeUri, access.treeUri);
    await prefs.setString(_keyDisplayName, access.displayName);
    await prefs.remove(_keyLastError);
    return loadStatus();
  }

  Future<void> unbindFolder() => _runExclusive(() async {
    _debounceTimer?.cancel();
    final config = await loadConfig();
    if (config.isBound) {
      await StorageVaultChannel.releaseTree(config.treeUri!);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyTreeUri);
    await prefs.remove(_keyDisplayName);
    await prefs.remove(_keyLastSyncAt);
    await prefs.remove(_keyLastError);
  });

  Future<({int deletedCount, int freedBytes})> purgeVaultData() =>
      _runExclusive(() async {
        _debounceTimer?.cancel();
        final config = await loadConfig();
        var result = (deletedCount: 0, freedBytes: 0);
        if (config.isBound) {
          result = await StorageVaultChannel.purgeVault(config.treeUri!);
          await StorageVaultChannel.releaseTree(config.treeUri!);
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_keyTreeUri);
        await prefs.remove(_keyDisplayName);
        await prefs.remove(_keyLastSyncAt);
        await prefs.remove(_keyLastError);
        return result;
      });

  Future<void> setAutoSync(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoSync, enabled);
    if (!enabled) _debounceTimer?.cancel();
  }

  Future<VaultSyncReport?> setIncludePrivate(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIncludePrivate, enabled);
    final config = await loadConfig();
    if (!config.isBound) return null;
    return syncNow();
  }

  Future<void> setQuotaBytes(int quotaBytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyQuotaBytes, quotaBytes < 0 ? 0 : quotaBytes);
  }

  void scheduleAutoSync() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_autoSyncDebounce, () {
      if (_disposed) return;
      unawaited(_runDebouncedSync());
    });
  }

  Future<void> _runDebouncedSync() async {
    try {
      final config = await loadConfig();
      if (!config.isBound || !config.autoSync) return;
      await syncNow();
    } on Object catch (error, stack) {
      debugPrint('Auto vault sync error: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  Future<VaultSyncReport> syncNow() => _runExclusive(() async {
    final config = await loadConfig();
    if (!config.isBound) {
      return const VaultSyncReport(
        uploadedBooks: 0,
        skippedBooks: 0,
        deletedOrphans: 0,
        totalBytes: 0,
        errorMessage: '尚未选择守护目录',
      );
    }

    _syncing = true;
    try {
      final access = await StorageVaultChannel.checkTree(config.treeUri!);
      if (access == null || !access.valid) {
        const msg = '守护目录授权已失效，请重新选择目录';
        await _setLastError(msg);
        return const VaultSyncReport(
          uploadedBooks: 0,
          skippedBooks: 0,
          deletedOrphans: 0,
          totalBytes: 0,
          errorMessage: msg,
        );
      }

      if (access.freeBytes > 0 &&
          access.freeBytes < kMinDeviceFreeBytesMargin) {
        const msg = '手机可用存储空间不足 256 MB，已自动暂停写入守护目录';
        await _setLastError(msg);
        return const VaultSyncReport(
          uploadedBooks: 0,
          skippedBooks: 0,
          deletedOrphans: 0,
          totalBytes: 0,
          lowSpacePaused: true,
          errorMessage: msg,
        );
      }

      final stagingDir = await _ensureStagingDir();
      final appDir = await _storage.getAppDataDirectory();
      final appRoot = p.normalize(appDir.path);

      final existingListing = await StorageVaultChannel.listVaultFiles(
        config.treeUri!,
      );
      final remoteFilesByPath = <String, VaultFileEntry>{
        for (final entry in existingListing.files) entry.relativePath: entry,
      };
      final previousManifest = await _readRemoteManifest(config.treeUri!);
      final prevBookPayloads = _readPayloadIndex(
        previousManifest?['bookPayloads'],
      );
      final prevFontPayloads = _readPayloadIndex(
        previousManifest?['fontPayloads'],
      );

      final rawRecords = await _storage.getAllBookMetadataRecords();
      final settings = await _storage.getSettings();
      final normalGroups = await _storage.getShelfGroups(private: false);
      final privateGroups = config.includePrivate
          ? await _storage.getShelfGroups(private: true)
          : const <String>[];

      final desiredBooks = <Map<String, dynamic>>[];
      final desiredStates = <String, Map<String, dynamic>>{};
      final desiredBookRelPaths = <String, String>{};
      final desiredFingerprints = <String, String>{};

      for (final raw in rawRecords) {
        final id = raw['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final isPrivate = raw['isPrivate'] == true;
        if (isPrivate && !config.includePrivate) continue;

        final record = Map<String, dynamic>.from(
          _rewritePathsInJson(raw, appRoot: appRoot, toToken: true) as Map,
        );
        desiredBooks.add(record);
        desiredStates[id] = await _collectBookState(id, raw);

        final bookDir = await _storage.chapterDirectory(id);
        final relPath = _vaultBookRelPath(id, p.basename(bookDir.path));
        desiredBookRelPaths[id] = relPath;
        desiredFingerprints[id] = await _computeBookFingerprint(
          raw: raw,
          bookDir: bookDir,
          appRoot: appRoot,
        );
      }

      String? desiredFontRel;
      File? localFontFile;
      String? localFontTokenPath;
      String? localFontFingerprint;
      final fontPath = settings.importedFontPath;
      if (fontPath != null && fontPath.isNotEmpty) {
        final f = File(fontPath);
        if (await f.exists()) {
          final rel = _vaultFontRelPath(p.basename(f.path));
          if (rel != null) {
            final stat = await f.stat();
            desiredFontRel = rel;
            localFontFile = f;
            localFontTokenPath = p.isWithin(appRoot, p.normalize(f.path))
                ? '$_appRootToken/${p.posix.joinAll(p.split(p.relative(p.normalize(f.path), from: appRoot)))}'
                : null;
            localFontFingerprint = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
          }
        }
      }

      // Delete removed / private-disabled orphans first so quota is reclaimed cleanly.
      final validRelSet = <String>{
        _manifestRelPath,
        ...desiredBookRelPaths.values,
        ?desiredFontRel,
      };
      var deletedOrphans = 0;
      for (final remote in existingListing.files) {
        if (!validRelSet.contains(remote.relativePath)) {
          final deleted = await StorageVaultChannel.deleteVaultFile(
            treeUri: config.treeUri!,
            relativePath: remote.relativePath,
          );
          if (deleted) deletedOrphans++;
        }
      }

      var uploadedBooks = 0;
      var skippedBooks = 0;
      var quotaPaused = false;
      var lowSpacePaused = false;
      String? issueMessage;
      final nextBookPayloads = <String, Map<String, dynamic>>{};

      for (final record in desiredBooks) {
        final id = record['id']!.toString();
        final relPath = desiredBookRelPaths[id]!;
        final fingerprint = desiredFingerprints[id]!;
        final prevPayload = prevBookPayloads[id];
        final remoteEntry = remoteFilesByPath[relPath];
        final unchanged =
            remoteEntry != null &&
            prevPayload != null &&
            prevPayload['relativePath'] == relPath &&
            prevPayload['fingerprint'] == fingerprint;

        if (unchanged) {
          skippedBooks++;
          nextBookPayloads[id] = prevPayload;
          continue;
        }

        final bookDir = await _storage.chapterDirectory(id);
        final rawRecord = rawRecords.firstWhere(
          (item) => item['id']?.toString() == id,
          orElse: () => record,
        );
        final stagingFile = File(
          p.join(stagingDir.path, '${p.basename(relPath)}.${DateTime.now().microsecondsSinceEpoch}'),
        );
        try {
          await _packBookArchiveInIsolate(
            zipPath: stagingFile.path,
            appRoot: appRoot,
            bookDirPath: bookDir.path,
            sourcePath: rawRecord['sourcePath']?.toString(),
            coverPath: rawRecord['coverImagePath']?.toString(),
            tokenizedMetaJson: jsonEncode(record),
          );
          final sizeBytes = await stagingFile.length();
          final digest = await sha256.bind(stagingFile.openRead()).first;
          final written = await StorageVaultChannel.writeCacheFileToVault(
            treeUri: config.treeUri!,
            sourcePath: stagingFile.path,
            relativePath: relPath,
            maxVaultBytes: config.quotaBytes,
          );
          uploadedBooks++;
          nextBookPayloads[id] = <String, dynamic>{
            'relativePath': relPath,
            'fingerprint': fingerprint,
            'sha256': digest.toString(),
            'sizeBytes': written > 0 ? written : sizeBytes,
          };
        } on PlatformException catch (error) {
          if (prevPayload != null && remoteEntry != null) {
            nextBookPayloads[id] = prevPayload;
          }
          if (error.code == 'QUOTA_EXCEEDED') {
            quotaPaused = true;
            issueMessage = error.message ?? '已达到守护目录空间配额上限，未继续写入';
            break;
          }
          if (error.code == 'LOW_DISK_SPACE') {
            lowSpacePaused = true;
            issueMessage = error.message ?? '手机可用存储空间不足，已暂停写入';
            break;
          }
          issueMessage = error.message ?? '写入守护文件失败';
        } finally {
          if (await stagingFile.exists()) {
            await stagingFile.delete();
          }
        }
      }

      final nextFontPayloads = <String, Map<String, dynamic>>{};
      if (!quotaPaused &&
          !lowSpacePaused &&
          desiredFontRel != null &&
          localFontFile != null &&
          localFontFingerprint != null) {
        final prevFont = prevFontPayloads[desiredFontRel];
        final remoteFont = remoteFilesByPath[desiredFontRel];
        final fontUnchanged =
            remoteFont != null &&
            prevFont != null &&
            prevFont['fingerprint'] == localFontFingerprint;
        if (fontUnchanged) {
          nextFontPayloads[desiredFontRel] = prevFont;
        } else {
          final stagingFont = File(
            p.join(stagingDir.path, 'font_${DateTime.now().microsecondsSinceEpoch}_${p.basename(desiredFontRel)}'),
          );
          try {
            await _streamCopyFile(localFontFile, stagingFont);
            final digest = await sha256.bind(stagingFont.openRead()).first;
            final size = await stagingFont.length();
            await StorageVaultChannel.writeCacheFileToVault(
              treeUri: config.treeUri!,
              sourcePath: stagingFont.path,
              relativePath: desiredFontRel,
              maxVaultBytes: config.quotaBytes,
            );
            nextFontPayloads[desiredFontRel] = <String, dynamic>{
              'relativePath': desiredFontRel,
              'fingerprint': localFontFingerprint,
              'sha256': digest.toString(),
              'sizeBytes': size,
              'tokenPath': localFontTokenPath,
            };
          } on PlatformException catch (error) {
            if (error.code == 'QUOTA_EXCEEDED') {
              quotaPaused = true;
              issueMessage = error.message ?? '已达到守护目录空间配额上限';
            } else if (error.code == 'LOW_DISK_SPACE') {
              lowSpacePaused = true;
              issueMessage = error.message ?? '手机可用存储空间不足';
            }
          } finally {
            if (await stagingFont.exists()) await stagingFont.delete();
          }
        }
      }

      final manifestPayload = <String, dynamic>{
        'schemaVersion': _schemaVersion,
        'appVersion': await _resolveAppVersion(),
        'updatedAt': DateTime.now().toIso8601String(),
        'includePrivate': config.includePrivate,
        'settings': _rewritePathsInJson(
          settings.toJson(),
          appRoot: appRoot,
          toToken: true,
        ),
        'shelfGroups': normalGroups,
        'privateShelfGroups': privateGroups,
        'books': desiredBooks,
        'states': desiredStates,
        'bookPayloads': nextBookPayloads,
        'fontPayloads': nextFontPayloads,
      };

      final manifestStage = File(
        p.join(stagingDir.path, 'manifest_${DateTime.now().microsecondsSinceEpoch}.json'),
      );
      try {
        await manifestStage.writeAsString(jsonEncode(manifestPayload), flush: true);
        await StorageVaultChannel.writeCacheFileToVault(
          treeUri: config.treeUri!,
          sourcePath: manifestStage.path,
          relativePath: _manifestRelPath,
          // Always allow small manifest updates so state/notes stay durable even near quota.
          maxVaultBytes: 0,
        );
      } finally {
        if (await manifestStage.exists()) await manifestStage.delete();
      }

      final finalListing = await StorageVaultChannel.listVaultFiles(
        config.treeUri!,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastSyncAt, DateTime.now().toIso8601String());
      await _setLastError(issueMessage);

      return VaultSyncReport(
        uploadedBooks: uploadedBooks,
        skippedBooks: skippedBooks,
        deletedOrphans: deletedOrphans,
        totalBytes: finalListing.totalBytes,
        quotaPaused: quotaPaused,
        lowSpacePaused: lowSpacePaused,
        errorMessage: issueMessage,
      );
    } finally {
      _syncing = false;
    }
  });

  Future<VaultInspectPreview?> inspectVault() => _runExclusive(() async {
    final config = await loadConfig();
    if (!config.isBound) return null;
    final access = await StorageVaultChannel.checkTree(config.treeUri!);
    if (access == null || !access.valid) return null;
    final listing = await StorageVaultChannel.listVaultFiles(config.treeUri!);
    final manifest = await _readRemoteManifest(config.treeUri!);
    if (manifest == null) return null;

    final rawBooks = manifest['books'] is List
        ? manifest['books'] as List
        : const [];
    var privateCount = 0;
    for (final item in rawBooks) {
      if (item is Map && item['isPrivate'] == true) privateCount++;
    }
    var noteCount = 0;
    var bookmarkCount = 0;
    final rawStates = manifest['states'];
    if (rawStates is Map) {
      for (final entry in rawStates.values) {
        if (entry is! Map) continue;
        if (entry['notes'] is List) noteCount += (entry['notes'] as List).length;
        if (entry['bookmarks'] is List) {
          bookmarkCount += (entry['bookmarks'] as List).length;
        }
        if (entry['pdfNotes'] is Map) {
          noteCount += (entry['pdfNotes'] as Map).length;
        }
        if (entry['pdfBookmarks'] is List) {
          bookmarkCount += (entry['pdfBookmarks'] as List).length;
        }
      }
    }
    return VaultInspectPreview(
      bookCount: rawBooks.length,
      privateBookCount: privateCount,
      noteCount: noteCount,
      bookmarkCount: bookmarkCount,
      hasSettings: manifest['settings'] is Map,
      totalBytes: listing.totalBytes,
      updatedAt: manifest['updatedAt'] is String
          ? DateTime.tryParse(manifest['updatedAt'] as String)
          : null,
    );
  });

  Future<VaultRestoreReport> restoreFromVault({
    bool includePrivate = true,
    bool restoreSettings = true,
  }) => _runExclusive(() async {
    final config = await loadConfig();
    if (!config.isBound) {
      throw const FormatException('尚未绑定守护目录');
    }
    final access = await StorageVaultChannel.checkTree(config.treeUri!);
    if (access == null || !access.valid) {
      throw const FormatException('守护目录授权已失效，请重新选择目录');
    }
    final manifest = await _readRemoteManifest(config.treeUri!);
    if (manifest == null) {
      throw const FormatException('守护目录内暂无可恢复的同步索引');
    }

    final appDir = await _storage.getAppDataDirectory();
    final appRoot = p.normalize(appDir.path);
    final rawBooks = manifest['books'] is List
        ? manifest['books'] as List
        : const [];
    final rawStates = manifest['states'] is Map
        ? Map<String, dynamic>.from(manifest['states'] as Map)
        : const <String, dynamic>{};
    final payloads = _readPayloadIndex(manifest['bookPayloads']);
    final fontPayloads = _readPayloadIndex(manifest['fontPayloads']);

    final existingIds = (await _storage.getAllBookMetadataRecords())
        .map((r) => r['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    // Restore custom fonts first.
    for (final entry in fontPayloads.entries) {
      final relPath = entry.key;
      final tokenPath = entry.value['tokenPath']?.toString();
      final expectedSha = entry.value['sha256']?.toString();
      if (tokenPath == null || !tokenPath.startsWith('$_appRootToken/')) {
        continue;
      }
      String? staged;
      try {
        staged = await StorageVaultChannel.readVaultFileToCache(
          treeUri: config.treeUri!,
          relativePath: relPath,
          maxBytes: 128 * 1024 * 1024,
        );
        if (staged == null) continue;
        final stagedFile = File(staged);
        if (expectedSha != null && expectedSha.isNotEmpty) {
          final actualSha = (await sha256.bind(stagedFile.openRead()).first)
              .toString();
          if (actualSha != expectedSha) continue;
        }
        final relUnderApp = tokenPath.substring('$_appRootToken/'.length);
        final dest = _resolveSafeAppDest(relUnderApp, appRoot);
        if (dest != null) {
          await dest.parent.create(recursive: true);
          await _streamCopyFile(stagedFile, dest);
        }
      } finally {
        if (staged != null) {
          final f = File(staged);
          if (await f.exists()) await f.delete();
        }
      }
    }

    if (restoreSettings && manifest['settings'] is Map) {
      final rewritten = Map<String, dynamic>.from(
        _rewritePathsInJson(
          manifest['settings'],
          appRoot: appRoot,
          toToken: false,
        ) as Map,
      );
      await _storage.saveSettings(ReaderSettings.fromJson(rewritten));
    }

    if (manifest['shelfGroups'] is List) {
      final mergedNormal = normalizeBookGroups([
        ...(await _storage.getShelfGroups(private: false)),
        ...(manifest['shelfGroups'] as List).map((e) => e.toString()),
      ]);
      await _storage.saveShelfGroups(mergedNormal, private: false);
    }
    if (includePrivate && manifest['privateShelfGroups'] is List) {
      final mergedPrivate = normalizeBookGroups([
        ...(await _storage.getShelfGroups(private: true)),
        ...(manifest['privateShelfGroups'] as List).map((e) => e.toString()),
      ]);
      await _storage.saveShelfGroups(mergedPrivate, private: true);
    }

    var restoredBooks = 0;
    var updatedBooks = 0;
    var mergedNotes = 0;
    var mergedBookmarks = 0;

    for (final rawItem in rawBooks) {
      if (rawItem is! Map) continue;
      final isPrivate = rawItem['isPrivate'] == true;
      if (isPrivate && !includePrivate) continue;
      final id = rawItem['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final payload = payloads[id];
      final relPath = payload?['relativePath']?.toString();
      final expectedSha = payload?['sha256']?.toString();
      if (relPath != null && relPath.isNotEmpty) {
        String? stagedZip;
        try {
          stagedZip = await StorageVaultChannel.readVaultFileToCache(
            treeUri: config.treeUri!,
            relativePath: relPath,
            maxBytes: kMaxSingleArchiveEntryBytes,
          );
          if (stagedZip != null) {
            final zipFile = File(stagedZip);
            if (expectedSha != null && expectedSha.isNotEmpty) {
              final actualSha = (await sha256.bind(zipFile.openRead()).first)
                  .toString();
              if (actualSha != expectedSha) {
                throw FormatException('书籍「${rawItem['title'] ?? id}」守护文件校验失败');
              }
            }
            await _unpackBookArchiveInIsolate(
              zipPath: stagedZip,
              appRoot: appRoot,
            );
          }
        } finally {
          if (stagedZip != null) {
            final f = File(stagedZip);
            if (await f.exists()) await f.delete();
          }
        }
      }

      _storage.clearDeletedBookMarker(id);
      final record = Map<String, dynamic>.from(
        _rewritePathsInJson(rawItem, appRoot: appRoot, toToken: false) as Map,
      );
      await _storage.upsertRestoredBookRecord(record);
      if (existingIds.contains(id)) {
        updatedBooks++;
      } else {
        restoredBooks++;
      }

      final state = rawStates[id] is Map
          ? Map<String, dynamic>.from(rawStates[id] as Map)
          : const <String, dynamic>{};
      final counts = await _mergeBookState(id, record, state);
      mergedNotes += counts.notes;
      mergedBookmarks += counts.bookmarks;
    }

    return VaultRestoreReport(
      restoredBooks: restoredBooks,
      updatedBooks: updatedBooks,
      mergedNotes: mergedNotes,
      mergedBookmarks: mergedBookmarks,
      restoredSettings: restoreSettings && manifest['settings'] is Map,
    );
  });

  Future<VaultVerifyReport> verifyAndCleanVault() => _runExclusive(() async {
    final config = await loadConfig();
    if (!config.isBound) {
      throw const FormatException('尚未绑定守护目录');
    }
    final access = await StorageVaultChannel.checkTree(config.treeUri!);
    if (access == null || !access.valid) {
      throw const FormatException('守护目录授权已失效，请重新选择目录');
    }
    final listing = await StorageVaultChannel.listVaultFiles(config.treeUri!);
    final manifest = await _readRemoteManifest(config.treeUri!);
    final referenced = <String>{_manifestRelPath};
    final payloads = _readPayloadIndex(manifest?['bookPayloads']);
    final fontPayloads = _readPayloadIndex(manifest?['fontPayloads']);
    for (final pEntry in payloads.values) {
      final rel = pEntry['relativePath']?.toString();
      if (rel != null && rel.isNotEmpty) referenced.add(rel);
    }
    for (final rel in fontPayloads.keys) {
      referenced.add(rel);
    }

    final existingPaths = {
      for (final file in listing.files) file.relativePath: file,
    };
    var validBooks = 0;
    var missingFiles = 0;
    for (final pEntry in payloads.values) {
      final rel = pEntry['relativePath']?.toString();
      if (rel != null && existingPaths.containsKey(rel)) {
        validBooks++;
      } else {
        missingFiles++;
      }
    }

    var removedOrphans = 0;
    var freedBytes = 0;
    if (manifest != null) {
      for (final file in listing.files) {
        if (!referenced.contains(file.relativePath)) {
          final ok = await StorageVaultChannel.deleteVaultFile(
            treeUri: config.treeUri!,
            relativePath: file.relativePath,
          );
          if (ok) {
            removedOrphans++;
            freedBytes += file.sizeBytes;
          }
        }
      }
    }
    await _setLastError(null);
    return VaultVerifyReport(
      validBooks: validBooks,
      missingFiles: missingFiles,
      removedOrphans: removedOrphans,
      removedTmpFiles: listing.staleTmpCount,
      freedBytes: freedBytes,
    );
  });

  Future<Directory> _ensureStagingDir() async {
    final cache = await getTemporaryDirectory();
    final dir = Directory(p.join(cache.path, _stagingDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Map<String, dynamic>?> _readRemoteManifest(String treeUri) async {
    String? stagedPath;
    try {
      stagedPath = await StorageVaultChannel.readVaultFileToCache(
        treeUri: treeUri,
        relativePath: _manifestRelPath,
        maxBytes: kMaxManifestBytes,
      );
      if (stagedPath == null) return null;
      final raw = await File(stagedPath).readAsString();
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on Object {
      return null;
    } finally {
      if (stagedPath != null) {
        final f = File(stagedPath);
        if (await f.exists()) await f.delete();
      }
    }
  }

  Future<Map<String, dynamic>> _collectBookState(
    String bookId,
    Map<String, dynamic> rawBook,
  ) async {
    final isPdf = rawBook['format'] == 'pdf';
    final pageCount = rawBook['pageCount'] is num
        ? (rawBook['pageCount'] as num).toInt()
        : 0;
    final progress = await _storage.getProgress(bookId);
    final notes = await _storage.getNotes(
      bookId,
      isPdf: isPdf,
      pdfPageCount: pageCount,
    );
    final bookmarks = await _storage.getBookmarks(bookId);
    final collapsedToc = await _storage.getCollapsedTocGroups(bookId);
    final prefs = await SharedPreferences.getInstance();
    final legacyChapters = prefs.getString('$kLegacyChapterPrefPrefix$bookId');

    PdfReadingProgress? pdfProgress;
    Set<int>? pdfBookmarks;
    Map<int, String>? pdfNotes;
    PdfDisplayTheme? pdfTheme;
    if (isPdf && pageCount > 0) {
      pdfProgress = await _storage.getPdfProgress(bookId, pageCount: pageCount);
      pdfBookmarks = await _storage.getPdfBookmarks(bookId, pageCount);
      pdfNotes = await _storage.getPdfNotes(bookId, pageCount);
      pdfTheme = await _storage.getPdfDisplayTheme(bookId);
    }

    return <String, dynamic>{
      if (progress != null) 'progress': progress.toJson(),
      if (notes.isNotEmpty) 'notes': [for (final n in notes) n.toJson()],
      if (bookmarks.isNotEmpty)
        'bookmarks': [for (final b in bookmarks) b.toJson()],
      if (collapsedToc.isNotEmpty) 'collapsedTocGroups': collapsedToc.toList(),
      'legacyChapters': ?legacyChapters,
      if (pdfProgress != null) 'pdfProgress': pdfProgress.toJson(),
      if (pdfBookmarks != null && pdfBookmarks.isNotEmpty)
        'pdfBookmarks': pdfBookmarks.toList(),
      if (pdfNotes != null && pdfNotes.isNotEmpty)
        'pdfNotes': {
          for (final e in pdfNotes.entries) e.key.toString(): e.value,
        },
      if (pdfTheme != null) 'pdfDisplayTheme': pdfTheme.name,
    };
  }

  Future<({int notes, int bookmarks})> _mergeBookState(
    String bookId,
    Map<String, dynamic> record,
    Map<String, dynamic> state,
  ) async {
    final isPdf = record['format'] == 'pdf';
    final pageCount = record['pageCount'] is num
        ? (record['pageCount'] as num).toInt()
        : 0;
    var addedNotes = 0;
    var addedBookmarks = 0;

    if (state['progress'] is Map) {
      final incoming = ReadingProgress.fromJson(
        Map<String, dynamic>.from(state['progress'] as Map),
      );
      final current = await _storage.getProgress(bookId);
      if (current == null ||
          incoming.lastReadDate.isAfter(current.lastReadDate)) {
        await _storage.saveProgress(incoming);
      }
    }

    if (state['notes'] is List) {
      final current = await _storage.getNotes(
        bookId,
        isPdf: isPdf,
        pdfPageCount: pageCount,
      );
      final byId = <String, ReaderNote>{
        for (final n in current) n.id: n,
      };
      for (final raw in state['notes'] as List) {
        if (raw is! Map) continue;
        final note = ReaderNote.fromJson(Map<String, dynamic>.from(raw));
        if (note == null) continue;
        final existing = byId[note.id];
        if (existing == null) {
          byId[note.id] = note;
          addedNotes++;
        } else if (note.updatedAt.isAfter(existing.updatedAt)) {
          byId[note.id] = note;
        }
      }
      await _storage.saveNotes(bookId, sortedReaderNotes(byId.values.toList()));
    }

    if (state['bookmarks'] is List) {
      final current = await _storage.getBookmarks(bookId);
      final byId = <String, ReaderBookmark>{
        for (final b in current) b.id: b,
      };
      for (final raw in state['bookmarks'] as List) {
        if (raw is! Map) continue;
        final bm = ReaderBookmark.fromJson(Map<String, dynamic>.from(raw));
        if (bm == null) continue;
        if (!byId.containsKey(bm.id)) {
          byId[bm.id] = bm;
          addedBookmarks++;
        }
      }
      await _storage.saveBookmarks(bookId, byId.values.toList());
    }

    if (state['collapsedTocGroups'] is List) {
      final current = await _storage.getCollapsedTocGroups(bookId);
      await _storage.saveCollapsedTocGroups(bookId, {
        ...current,
        ...(state['collapsedTocGroups'] as List).map((e) => e.toString()),
      });
    }

    if (state['legacyChapters'] is String) {
      final prefs = await SharedPreferences.getInstance();
      final key = '$kLegacyChapterPrefPrefix$bookId';
      if (!prefs.containsKey(key)) {
        await prefs.setString(key, state['legacyChapters'] as String);
      }
    }

    if (isPdf && pageCount > 0) {
      if (state['pdfProgress'] is Map) {
        final incoming = PdfReadingProgress.fromJson(
          Map<String, dynamic>.from(state['pdfProgress'] as Map),
        );
        final current = await _storage.getPdfProgress(
          bookId,
          pageCount: pageCount,
        );
        if (current == null ||
            incoming.lastReadDate.isAfter(current.lastReadDate)) {
          await _storage.savePdfProgress(incoming);
        }
      }
      if (state['pdfBookmarks'] is List) {
        final current = await _storage.getPdfBookmarks(bookId, pageCount);
        final incoming = (state['pdfBookmarks'] as List)
            .whereType<num>()
            .map((e) => e.toInt())
            .toSet();
        await _storage.savePdfBookmarks(
          bookId,
          {...current, ...incoming},
          pageCount,
        );
      }
      if (state['pdfNotes'] is Map) {
        final current = await _storage.getPdfNotes(bookId, pageCount);
        final merged = Map<int, String>.from(current);
        (state['pdfNotes'] as Map).forEach((k, v) {
          final page = int.tryParse(k.toString());
          if (page != null && v is String && !merged.containsKey(page)) {
            merged[page] = v;
          }
        });
        await _storage.savePdfNotes(bookId, merged, pageCount);
      }
      if (state['pdfDisplayTheme'] is String) {
        final themeName = state['pdfDisplayTheme'] as String;
        final theme = PdfDisplayTheme.values.firstWhere(
          (item) => item.name == themeName,
          orElse: () => PdfDisplayTheme.original,
        );
        await _storage.savePdfDisplayTheme(bookId, theme);
      }
    }
    return (notes: addedNotes, bookmarks: addedBookmarks);
  }

  Future<String> _computeBookFingerprint({
    required Map<String, dynamic> raw,
    required Directory bookDir,
    required String appRoot,
  }) async {
    final parts = <String>[
      'rev:${raw['contentRevision'] ?? 0}',
      'title:${raw['title'] ?? ''}',
      'author:${raw['author'] ?? ''}',
      'priv:${raw['isPrivate'] == true}',
    ];
    if (await bookDir.exists()) {
      final entities = <File>[];
      await for (final entity in bookDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = p.posix.joinAll(p.split(p.relative(entity.path, from: bookDir.path)));
        if (_isTransientArtifact(rel)) continue;
        entities.add(entity);
      }
      entities.sort((a, b) => a.path.compareTo(b.path));
      for (final file in entities) {
        final stat = await file.stat();
        parts.add(
          '${p.relative(file.path, from: bookDir.path)}:${stat.size}:${stat.modified.millisecondsSinceEpoch}',
        );
      }
    }
    for (final key in const ['sourcePath', 'coverImagePath']) {
      final path = raw[key]?.toString();
      if (path != null &&
          path.isNotEmpty &&
          p.isWithin(appRoot, p.normalize(path))) {
        final f = File(path);
        if (await f.exists()) {
          final stat = await f.stat();
          parts.add('$key:${stat.size}:${stat.modified.millisecondsSinceEpoch}');
        }
      }
    }
    return sha256.convert(utf8.encode(parts.join('|'))).toString();
  }

  Future<String> _resolveAppVersion() async {
    try {
      final reader = readAppVersion;
      if (reader != null) return await reader();
    } on Object {
      // Fallback version string if unavailable.
    }
    return '0.8.2';
  }
}

Map<String, Map<String, dynamic>> _readPayloadIndex(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, Map<String, dynamic>>{};
  raw.forEach((key, value) {
    if (value is Map) {
      out[key.toString()] = Map<String, dynamic>.from(value);
    }
  });
  return out;
}

String _vaultBookRelPath(String bookId, String localDirName) {
  if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(localDirName)) {
    return 'books/$localDirName.rvbook';
  }
  final hash = sha256.convert(utf8.encode(bookId)).toString().substring(0, 32);
  return 'books/$hash.rvbook';
}

String? _vaultFontRelPath(String fileName) {
  final ext = p.extension(fileName).toLowerCase();
  if (ext != '.ttf' && ext != '.otf') return null;
  var stem = p
      .basenameWithoutExtension(fileName)
      .replaceAll(RegExp(r'[^A-Za-z0-9_.\-\u4e00-\u9fa5]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (stem.isEmpty) stem = 'custom_font';
  if (stem.length > 120) stem = stem.substring(0, 120);
  return 'fonts/$stem$ext';
}

bool _isTransientArtifact(String relPosix) {
  for (final part in relPosix.split('/')) {
    if (part.endsWith('.tmp') ||
        part.endsWith('.bak') ||
        part.contains('.edit.')) {
      return true;
    }
  }
  return false;
}

Future<void> _streamCopyFile(File src, File dest) async {
  final out = dest.openWrite();
  try {
    await out.addStream(src.openRead());
    await out.flush();
  } finally {
    await out.close();
  }
}

File? _resolveSafeAppDest(String relPosix, String appRoot) {
  if (relPosix.isEmpty ||
      relPosix.startsWith('/') ||
      relPosix.contains('\\') ||
      relPosix.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    return null;
  }
  final normalizedRoot = p.normalize(appRoot);
  final dest = p.normalize(p.joinAll([normalizedRoot, ...relPosix.split('/')]));
  if (!p.isWithin(normalizedRoot, dest)) return null;
  return File(dest);
}

Future<void> _packBookArchiveInIsolate({
  required String zipPath,
  required String appRoot,
  required String bookDirPath,
  required String? sourcePath,
  required String? coverPath,
  required String tokenizedMetaJson,
}) {
  return Isolate.run(() async {
    final normalizedRoot = p.normalize(appRoot);
    final fileEntries = <({String diskPath, String archivePath})>[];
    final seenEntries = <String>{};

    void queueFile(File file) {
      if (!file.existsSync()) return;
      final normalized = p.normalize(file.path);
      if (!p.isWithin(normalizedRoot, normalized)) return;
      final relPosix = p.posix.joinAll(
        p.split(p.relative(normalized, from: normalizedRoot)),
      );
      if (_isTransientArtifact(relPosix)) return;
      if (seenEntries.add(relPosix)) {
        fileEntries.add((diskPath: normalized, archivePath: relPosix));
      }
    }

    final bookDir = Directory(bookDirPath);
    if (bookDir.existsSync()) {
      for (final entity in bookDir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) queueFile(entity);
      }
    }
    if (sourcePath != null && sourcePath.isNotEmpty) {
      queueFile(File(sourcePath));
    }
    if (coverPath != null && coverPath.isNotEmpty) {
      queueFile(File(coverPath));
    }

    final encoder = ZipFileEncoder();
    encoder.create(zipPath, level: ZipFileEncoder.gzip);
    try {
      encoder.addArchiveFile(
        ArchiveFile.bytes('meta.json', utf8.encode(tokenizedMetaJson)),
      );
      for (final spec in fileEntries) {
        final file = File(spec.diskPath);
        if (spec.archivePath.toLowerCase().endsWith('.json')) {
          final text = file.readAsStringSync();
          if (text.contains(normalizedRoot) ||
              text.contains(normalizedRoot.replaceAll('\\', '/'))) {
            final rewritten = _rewritePathsInJson(
              jsonDecode(text),
              appRoot: normalizedRoot,
              toToken: true,
            );
            final encoded = utf8.encode(jsonEncode(rewritten));
            encoder.addArchiveFile(
              ArchiveFile.bytes(spec.archivePath, encoded),
            );
            continue;
          }
        }
        await encoder.addFile(file, spec.archivePath, ZipFileEncoder.gzip);
      }
    } finally {
      await encoder.close();
    }
  });
}

Future<void> _unpackBookArchiveInIsolate({
  required String zipPath,
  required String appRoot,
}) {
  return Isolate.run(() {
    final normalizedRoot = p.normalize(appRoot);
    final input = InputFileStream(zipPath);
    final modifiedChapters = <String, Map<String, ({int bytes, String sha256})>>{};
    final manifestDirs = <String>{};

    try {
      final archive = ZipDecoder().decodeStream(input);
      final budget = ArchiveExtractionBudget();
      for (final entry in archive) {
        assertSafeArchiveEntry(entry);
        budget.recordHeader(entry);
        if (entry.isDirectory || entry.name == 'meta.json') continue;
        final dest = _resolveSafeAppDest(entry.name, normalizedRoot);
        if (dest == null) continue;
        dest.parent.createSync(recursive: true);

        final out = OutputFileStream(dest.path);
        try {
          entry.writeContent(out, freeMemory: true);
        } finally {
          out.closeSync();
        }
        budget.recordExtractedBytes(dest.lengthSync());

        final lower = entry.name.toLowerCase();
        if (lower.endsWith('.json')) {
          final raw = dest.readAsStringSync();
          if (raw.contains('{{READVIBE_ROOT}}')) {
            final decoded = jsonDecode(raw);
            final rewritten = jsonEncode(
              _rewritePathsInJson(decoded, appRoot: normalizedRoot, toToken: false),
            );
            final bytes = utf8.encode(rewritten);
            dest.writeAsBytesSync(bytes, flush: true);

            if (entry.name.startsWith('books/') && entry.name.contains('/chapters/')) {
              final marker = '/chapters/';
              final idx = entry.name.indexOf(marker);
              final bookPrefix = entry.name.substring(0, idx);
              final fileName = entry.name.substring(idx + marker.length);
              if (fileName == 'manifest.json') {
                manifestDirs.add(bookPrefix);
              } else {
                modifiedChapters.putIfAbsent(
                  bookPrefix,
                  () => <String, ({int bytes, String sha256})>{},
                )[fileName] = (
                  bytes: bytes.length,
                  sha256: sha256.convert(bytes).toString(),
                );
              }
            }
          } else if (entry.name.startsWith('books/') &&
              entry.name.endsWith('/chapters/manifest.json')) {
            manifestDirs.add(entry.name.substring(0, entry.name.indexOf('/chapters/')));
          }
        }
      }

      for (final bookPrefix in modifiedChapters.keys) {
        final updates = modifiedChapters[bookPrefix]!;
        if (updates.isEmpty && !manifestDirs.contains(bookPrefix)) continue;
        final manifestFile = _resolveSafeAppDest(
          '$bookPrefix/chapters/manifest.json',
          normalizedRoot,
        );
        if (manifestFile == null || !manifestFile.existsSync()) continue;
        final decoded = jsonDecode(manifestFile.readAsStringSync());
        if (decoded is! Map || decoded['chapters'] is! List) continue;
        final chapters = decoded['chapters'] as List;
        var changed = false;
        for (final item in chapters) {
          if (item is! Map) continue;
          final name = item['file']?.toString();
          final stat = name != null ? updates[name] : null;
          if (stat != null) {
            item['bytes'] = stat.bytes;
            item['sha256'] = stat.sha256;
            changed = true;
          }
        }
        if (changed) {
          manifestFile.writeAsStringSync(jsonEncode(decoded), flush: true);
        }
      }
    } finally {
      input.closeSync();
    }
  });
}

Object? _rewritePathsInJson(
  Object? node, {
  required String appRoot,
  required bool toToken,
}) {
  const token = '{{READVIBE_ROOT}}';
  if (node is String) {
    if (toToken) {
      final slashRoot = appRoot.replaceAll('\\', '/');
      if (node == appRoot || node == slashRoot) return token;
      if (node.startsWith('$appRoot/') || node.startsWith('$appRoot\\')) {
        final rest = node.substring(appRoot.length + 1).replaceAll('\\', '/');
        return '$token/$rest';
      }
      if (node.startsWith('$slashRoot/')) {
        final rest = node.substring(slashRoot.length + 1);
        return '$token/$rest';
      }
      return node;
    } else {
      if (node == token) return appRoot;
      if (node.startsWith('$token/')) {
        final rest = node.substring(token.length + 1).split('/');
        return p.normalize(p.joinAll([appRoot, ...rest]));
      }
      return node;
    }
  }
  if (node is List) {
    return [
      for (final item in node)
        _rewritePathsInJson(item, appRoot: appRoot, toToken: toToken),
    ];
  }
  if (node is Map) {
    return <String, Object?>{
      for (final entry in node.entries)
        entry.key.toString(): _rewritePathsInJson(
          entry.value,
          appRoot: appRoot,
          toToken: toToken,
        ),
    };
  }
  return node;
}
