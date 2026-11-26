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

  bool get isDirectMode => treeUri.startsWith('file://');

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

class VaultAllFilesStatus {
  const VaultAllFilesStatus({
    required this.supported,
    required this.granted,
    required this.rootPath,
    required this.defaultPath,
  });

  final bool supported;
  final bool granted;
  final String rootPath;
  final String defaultPath;
}

class LocalDirectoryItem {
  const LocalDirectoryItem({
    required this.path,
    required this.name,
    required this.hasVault,
  });

  final String path;
  final String name;
  final bool hasVault;
}

class LocalDirectoryListing {
  const LocalDirectoryListing({
    required this.currentPath,
    required this.parentPath,
    required this.relativePath,
    required this.displayName,
    required this.hasVault,
    required this.directories,
  });

  final String currentPath;
  final String? parentPath;
  final String relativePath;
  final String displayName;
  final bool hasVault;
  final List<LocalDirectoryItem> directories;
}

/// Typed Dart bridge over `com.readvibe.app/storage_vault`.
class StorageVaultChannel {
  static const _channel = MethodChannel('com.readvibe.app/storage_vault');

  static Future<VaultTreeAccess?> pickTree() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('pickTree');
    return VaultTreeAccess.fromMap(raw);
  }

  static Future<VaultAllFilesStatus> allFilesAccessStatus() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'allFilesAccessStatus',
    );
    return VaultAllFilesStatus(
      supported: raw?['supported'] == true,
      granted: raw?['granted'] == true,
      rootPath: raw?['rootPath'] as String? ?? '',
      defaultPath: raw?['defaultPath'] as String? ?? '',
    );
  }

  static Future<bool> requestAllFilesAccess() async {
    return await _channel.invokeMethod<bool>('requestAllFilesAccess') ?? false;
  }

  static Future<LocalDirectoryListing> listLocalDirectories({
    String? path,
  }) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'listLocalDirectories',
      {'path': ?path},
    );
    final rawDirs = raw?['directories'];
    final directories = <LocalDirectoryItem>[];
    if (rawDirs is List) {
      for (final item in rawDirs) {
        if (item is! Map) continue;
        final itemPath = item['path'];
        final itemName = item['name'];
        if (itemPath is! String || itemName is! String) continue;
        directories.add(
          LocalDirectoryItem(
            path: itemPath,
            name: itemName,
            hasVault: item['hasVault'] == true,
          ),
        );
      }
    }
    return LocalDirectoryListing(
      currentPath: raw?['currentPath'] as String? ?? '',
      parentPath: raw?['parentPath'] as String?,
      relativePath: raw?['relativePath'] as String? ?? '',
      displayName: raw?['displayName'] as String? ?? '内部存储',
      hasVault: raw?['hasVault'] == true,
      directories: directories,
    );
  }

  static Future<String> createLocalDirectory({
    required String parentPath,
    required String name,
  }) async {
    final created = await _channel.invokeMethod<String>(
      'createLocalDirectory',
      {'parentPath': parentPath, 'name': name},
    );
    return created ?? '';
  }

  static Future<VaultTreeAccess?> bindLocalDirectory(String path) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'bindLocalDirectory',
      {'path': path},
    );
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
