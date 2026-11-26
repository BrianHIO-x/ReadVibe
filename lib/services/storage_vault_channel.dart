import 'package:flutter/services.dart';

class VaultTreeAccess {
  const VaultTreeAccess({
    required this.treeUri,
    required this.displayName,
    required this.valid,
    required this.freeBytes,
  });

  final String treeUri;
  final String displayName;
  final bool valid;
  final int freeBytes;

  static VaultTreeAccess? fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return null;
    final uri = raw['treeUri'];
    if (uri is! String || uri.isEmpty) return null;
    final name = raw['displayName'];
    final free = raw['freeBytes'];
    return VaultTreeAccess(
      treeUri: uri,
      displayName: name is String && name.trim().isNotEmpty
          ? name.trim()
          : '守护目录',
      valid: raw['valid'] == true,
      freeBytes: free is num ? free.toInt() : 0,
    );
  }
}

class VaultFileEntry {
  const VaultFileEntry({
    required this.relativePath,
    required this.sizeBytes,
    required this.lastModifiedMs,
  });

  final String relativePath;
  final int sizeBytes;
  final int lastModifiedMs;
}

class VaultListing {
  const VaultListing({
    required this.exists,
    required this.totalBytes,
    required this.files,
    required this.staleTmpCount,
  });

  final bool exists;
  final int totalBytes;
  final List<VaultFileEntry> files;
  final int staleTmpCount;
}

/// Typed Dart bridge over `com.readvibe.app/storage_vault`.
class StorageVaultChannel {
  static const _channel = MethodChannel('com.readvibe.app/storage_vault');

  static Future<VaultTreeAccess?> pickTree() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('pickTree');
    return VaultTreeAccess.fromMap(raw);
  }

  static Future<VaultTreeAccess?> checkTree(String treeUri) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'checkTree',
      {'treeUri': treeUri},
    );
    return VaultTreeAccess.fromMap(raw);
  }

  static Future<void> releaseTree(String treeUri) async {
    await _channel.invokeMethod<bool>('releaseTree', {'treeUri': treeUri});
  }

  static Future<int> deviceFreeBytes() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'deviceStorageInfo',
    );
    final free = raw?['freeBytes'];
    return free is num ? free.toInt() : 0;
  }

  static Future<VaultListing> listVaultFiles(String treeUri) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'listVaultFiles',
      {'treeUri': treeUri},
    );
    final filesRaw = raw?['files'];
    final files = <VaultFileEntry>[];
    if (filesRaw is List) {
      for (final item in filesRaw) {
        if (item is! Map) continue;
        final path = item['relativePath'];
        if (path is! String || path.isEmpty) continue;
        final size = item['sizeBytes'];
        final mod = item['lastModifiedMs'];
        files.add(
          VaultFileEntry(
            relativePath: path,
            sizeBytes: size is num ? size.toInt() : 0,
            lastModifiedMs: mod is num ? mod.toInt() : 0,
          ),
        );
      }
    }
    return VaultListing(
      exists: raw?['exists'] == true,
      totalBytes: raw?['totalBytes'] is num
          ? (raw!['totalBytes'] as num).toInt()
          : 0,
      files: files,
      staleTmpCount: raw?['staleTmpCount'] is num
          ? (raw!['staleTmpCount'] as num).toInt()
          : 0,
    );
  }

  static Future<String?> readVaultFileToCache({
    required String treeUri,
    required String relativePath,
    int? maxBytes,
  }) {
    return _channel.invokeMethod<String>('readVaultFileToCache', {
      'treeUri': treeUri,
      'relativePath': relativePath,
      'maxBytes': ?maxBytes,
    });
  }

  static Future<int> writeCacheFileToVault({
    required String treeUri,
    required String sourcePath,
    required String relativePath,
    int maxVaultBytes = 0,
  }) async {
    final written = await _channel.invokeMethod<num>('writeCacheFileToVault', {
      'treeUri': treeUri,
      'sourcePath': sourcePath,
      'relativePath': relativePath,
      'maxVaultBytes': maxVaultBytes,
    });
    return written?.toInt() ?? 0;
  }

  static Future<bool> deleteVaultFile({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _channel.invokeMethod<bool>('deleteVaultFile', {
          'treeUri': treeUri,
          'relativePath': relativePath,
        }) ??
        false;
  }

  static Future<({int deletedCount, int freedBytes})> purgeVault(
    String treeUri,
  ) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'purgeVault',
      {'treeUri': treeUri},
    );
    return (
      deletedCount: raw?['deletedCount'] is num
          ? (raw!['deletedCount'] as num).toInt()
          : 0,
      freedBytes: raw?['freedBytes'] is num
          ? (raw!['freedBytes'] as num).toInt()
          : 0,
    );
  }

  static Future<void> cancelOperations() async {
    try {
      await _channel.invokeMethod<void>('cancelOperations');
    } on Object {
      // Best-effort cancellation.
    }
  }
}
