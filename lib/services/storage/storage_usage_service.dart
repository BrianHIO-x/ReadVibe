import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/book.dart';
import '../../repositories/reader_repositories.dart';
import 'chapter_disk_store.dart';
import 'chapter_revision_cleanup.dart';

/// Measures disk occupancy, cleans regenerable caches, and reclaims orphans.
class StorageUsageService {
  StorageUsageService(
    this._getAppDataDirectory,
    this._readBookMetadata,
    this._readBookMetadataForCleanup,
    this._chapterDirectory,
    this._enqueueLibraryMutation,
    this._enqueueChapterWrite,
  );

  final Future<Directory> Function() _getAppDataDirectory;
  final Future<List<Map<String, dynamic>>> Function() _readBookMetadata;
  final Future<List<Map<String, dynamic>>?> Function()
  _readBookMetadataForCleanup;
  final Future<Directory> Function(String) _chapterDirectory;
  final Future<T> Function<T>(Future<T> Function()) _enqueueLibraryMutation;
  final Future<T> Function<T>(String, Future<T> Function())
  _enqueueChapterWrite;

  Future<StorageUsageReport> measureStorageUsage() async {
    final root = (await _getAppDataDirectory()).absolute.path;
    final caches = await cacheDirectoryPaths();
    final bookCount = (await _readBookMetadata()).length;
    final sizes = await _measureDirectoriesInIsolate(<String>[
      p.join(root, 'books'),
      p.join(root, 'epub'),
      p.join(root, 'word'),
      p.join(root, 'pdf'),
      p.join(root, 'fonts'),
      ...caches,
    ]);
    return StorageUsageReport(
      bookPayloadBytes: sizes[0],
      epubResourceBytes: sizes[1],
      wordResourceBytes: sizes[2],
      pdfCopyBytes: sizes[3],
      fontBytes: sizes[4],
      cacheBytes: sizes.skip(5).fold(0, (sum, value) => sum + value),
      bookCount: bookCount,
    );
  }

  Future<int> clearTemporaryCaches() async {
    final caches = await cacheDirectoryPaths();
    return _clearCachesInIsolate(caches);
  }

  Future<List<String>> cacheDirectoryPaths() async {
    final Directory temporary;
    try {
      temporary = await getTemporaryDirectory();
    } on Object {
      return const <String>[];
    }
    return <String>[
      p.join(temporary.path, 'readvibe_pdf_pages'),
      p.join(temporary.path, 'readvibe_pdf_ocr'),
      p.join(temporary.path, 'readvibe_updates'),
      p.join(temporary.path, 'readvibe_picked_fonts'),
      p.join(temporary.path, 'readvibe_backup_import'),
      p.join(temporary.path, 'readvibe_vault_staging'),
      p.join(temporary.path, 'readvibe_picked'),
      p.join(temporary.path, 'readvibe_incoming'),
      p.join(temporary.path, 'readvibe_exports'),
    ];
  }

  Future<StorageCleanupResult> collectOrphanedData({
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? referenceTime,
  }) async {
    if (gracePeriod.isNegative) {
      throw ArgumentError.value(gracePeriod, 'gracePeriod', '不能为负数');
    }
    final metadata = await _readBookMetadataForCleanup();
    if (metadata == null) {
      return const StorageCleanupResult(removedFiles: 0, removedDirectories: 0);
    }
    final root = (await _getAppDataDirectory()).absolute;
    final cutoff = (referenceTime ?? DateTime.now()).subtract(gracePeriod);
    var removedFiles = 0;
    var removedDirectories = 0;

    final booksDirectory = Directory(p.join(root.path, 'books')).absolute;
    final referencedChapterPaths = <String>{};
    final referencedChapterDirectories = <String>{};
    for (final book in metadata) {
      final id = book['id'];
      if (id is! String || id.isEmpty) continue;
      final file = File(
        p.join(booksDirectory.path, '${safeBookId(id)}.json'),
      ).absolute;
      referencedChapterPaths.addAll(<String>{
        file.path,
        '${file.path}.tmp',
        '${file.path}.bak',
        '${file.path}.presplit',
      });
      final directory = Directory(
        p.join(booksDirectory.path, safeBookId(id)),
      ).absolute;
      referencedChapterDirectories.addAll(<String>{
        directory.path,
        '${directory.path}.tmp',
        '${directory.path}.bak',
      });
    }
    if (await booksDirectory.exists()) {
      try {
        await for (final entity in booksDirectory.list(followLinks: false)) {
          if (!_isManagedChild(booksDirectory.path, entity.absolute.path) ||
              !await isOlderThan(entity, cutoff)) {
            continue;
          }
          if (entity is File &&
              isChapterPayloadName(p.basename(entity.path)) &&
              !_pathsContain(referencedChapterPaths, entity.absolute.path)) {
            try {
              await entity.delete();
              removedFiles++;
            } on FileSystemException {
              // Best-effort cleanup; a later maintenance pass can retry.
            }
          } else if (entity is Directory &&
              isChapterDirectoryName(p.basename(entity.path)) &&
              !_pathsContain(
                referencedChapterDirectories,
                entity.absolute.path,
              )) {
            try {
              await entity.delete(recursive: true);
              removedDirectories++;
            } on FileSystemException {
              // Best-effort cleanup; a later maintenance pass can retry.
            }
          }
        }
      } on FileSystemException {
        // One inaccessible managed directory must not block other cleanup.
      }
    }

    final epubDirectory = Directory(p.join(root.path, 'epub')).absolute;
    final wordDirectory = Directory(p.join(root.path, 'word')).absolute;
    final pdfDirectory = Directory(p.join(root.path, 'pdf')).absolute;
    final referencedEpubPaths = <String>{};
    final referencedWordPaths = <String>{};
    final referencedPdfPaths = <String>{};
    for (final book in metadata) {
      final sourcePath = book['sourcePath'];
      if (sourcePath is! String || sourcePath.trim().isEmpty) continue;
      final absolutePath = p.normalize(File(sourcePath.trim()).absolute.path);
      if (book['format'] == BookFormat.epub.name &&
          _isManagedChild(epubDirectory.path, absolutePath)) {
        referencedEpubPaths.add(absolutePath);
      } else if (book['format'] == BookFormat.docx.name &&
          _isManagedChild(wordDirectory.path, absolutePath)) {
        referencedWordPaths.add(absolutePath);
      } else if (book['format'] == BookFormat.pdf.name &&
          _isManagedChild(pdfDirectory.path, absolutePath)) {
        referencedPdfPaths.add(absolutePath);
      }
    }

    for (final entry in <(Directory, Set<String>)>[
      (epubDirectory, referencedEpubPaths),
      (wordDirectory, referencedWordPaths),
    ]) {
      final targetDir = entry.$1;
      final referenced = entry.$2;
      if (!await targetDir.exists()) continue;
      try {
        await for (final entity in targetDir.list(followLinks: false)) {
          if (entity is! Directory ||
              !_isManagedChild(targetDir.path, entity.absolute.path) ||
              _pathsContain(referenced, entity.absolute.path) ||
              !await isOlderThan(entity, cutoff)) {
            continue;
          }
          try {
            await entity.delete(recursive: true);
            removedDirectories++;
          } on FileSystemException {
            // Best-effort cleanup; a later maintenance pass can retry.
          }
        }
      } on FileSystemException {
        // Continue with remaining resource cleanup.
      }
    }

    if (await pdfDirectory.exists()) {
      try {
        await for (final entity in pdfDirectory.list(followLinks: false)) {
          if (entity is! File ||
              !_isManagedChild(pdfDirectory.path, entity.absolute.path) ||
              _pathsContain(referencedPdfPaths, entity.absolute.path) ||
              !await isOlderThan(entity, cutoff)) {
            continue;
          }
          try {
            await entity.delete();
            removedFiles++;
          } on FileSystemException {
            // Best-effort cleanup; a later maintenance pass can retry.
          }
        }
      } on FileSystemException {
        // Cleanup is intentionally non-fatal.
      }
    }

    for (final book in metadata) {
      final id = book['id'];
      if (id is! String ||
          id.isEmpty ||
          book['format'] == BookFormat.pdf.name) {
        continue;
      }
      final directory = await _chapterDirectory(id);
      removedFiles += await _enqueueLibraryMutation(
        () => _enqueueChapterWrite(
          directory.path,
          () => collectObsoleteChapterPayloads(directory, cutoff),
        ),
      );
    }

    // Reclaim abandoned import/export/vault staging files older than 1 hour.
    final stagingCutoff = (referenceTime ?? DateTime.now()).subtract(
      const Duration(hours: 1),
    );
    try {
      final temporary = await getTemporaryDirectory();
      for (final dirName in const <String>[
        'readvibe_vault_staging',
        'readvibe_picked',
        'readvibe_incoming',
        'readvibe_exports',
      ]) {
        final target = Directory(p.join(temporary.path, dirName)).absolute;
        if (!await target.exists()) continue;
        await for (final entity in target.list(followLinks: false)) {
          if (!await isOlderThan(entity, stagingCutoff)) continue;
          try {
            if (entity is File) {
              await entity.delete();
              removedFiles++;
            } else if (entity is Directory) {
              await entity.delete(recursive: true);
              removedDirectories++;
            }
          } on FileSystemException {
            // Best-effort cleanup of stale staging temp entries.
          }
        }
      }
    } on Object {
      // Temporary directory cleanup never fails library maintenance.
    }

    return StorageCleanupResult(
      removedFiles: removedFiles,
      removedDirectories: removedDirectories,
    );
  }
}

bool _isManagedChild(String parentPath, String candidatePath) =>
    p.isWithin(p.normalize(parentPath), p.normalize(candidatePath));

bool _pathsContain(Set<String> paths, String candidate) =>
    paths.any((path) => p.equals(path, candidate));

List<int> _measureDirectories(List<String> paths) => <int>[
  for (final path in paths) _measureDirectory(Directory(path)),
];

Future<List<int>> _measureDirectoriesInIsolate(List<String> paths) =>
    Isolate.run(() => _measureDirectories(paths));

Future<int> _clearCachesInIsolate(List<String> caches) => Isolate.run(() {
  var freed = 0;
  for (final path in caches) {
    final directory = Directory(path);
    if (!directory.existsSync()) continue;
    freed += _measureDirectory(directory);
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // A file the platform still holds open is retried by a later sweep.
    }
  }
  return freed;
});

int _measureDirectory(Directory directory) {
  if (!directory.existsSync()) return 0;
  var total = 0;
  try {
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        total += entity.lengthSync();
      } on FileSystemException {
        // A file removed mid-walk simply does not count toward the total.
      }
    }
  } on FileSystemException {
    // An unreadable directory reports what was measured before the failure.
  }
  return total;
}
