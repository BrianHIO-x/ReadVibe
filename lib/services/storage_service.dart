import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import 'pdf_renderer_service.dart';
import 'txt_parser.dart';

const _kBooksKey = 'readvibe_books';
const _kSettingsKey = 'readvibe_settings';
const _kProgressPrefix = 'readvibe_progress_';
const _kPdfProgressPrefix = 'readvibe_pdf_progress_';
const _kPdfBookmarksPrefix = 'readvibe_pdf_bookmarks_';
const _kPdfNotesPrefix = 'readvibe_pdf_notes_';
const _kTocCollapsedPrefix = 'readvibe_toc_collapsed_';
const _kChapterPrefix = 'readvibe_chapters_';
// Large novels can exceed 10 MB. A two-second deadline was too aggressive on
// slower phones and could make a valid saved book appear unreadable.
const _kChapterIoTimeout = Duration(seconds: 30);
const _kLegacyMigrationTimeout = Duration(milliseconds: 250);

class StorageCleanupResult {
  final int removedFiles;
  final int removedDirectories;

  const StorageCleanupResult({
    required this.removedFiles,
    required this.removedDirectories,
  });

  int get removedEntries => removedFiles + removedDirectories;
}

class _LazyChapterStore {
  final String chaptersDirectoryPath;
  final List<String> fileNames;
  final List<int?> expectedBytes;
  final LinkedHashMap<int, Chapter> _cache = LinkedHashMap<int, Chapter>();

  _LazyChapterStore({
    required this.chaptersDirectoryPath,
    required this.fileNames,
    required this.expectedBytes,
  });

  Chapter load(int index) {
    final cached = _cache.remove(index);
    if (cached != null) {
      _cache[index] = cached;
      return cached;
    }
    if (index < 0 || index >= fileNames.length) {
      throw const FormatException('章节索引超出范围');
    }
    final file = File(p.join(chaptersDirectoryPath, fileNames[index]));
    final expected = expectedBytes[index];
    if (!file.existsSync() ||
        (expected != null && file.lengthSync() != expected)) {
      throw FormatException('章节 ${index + 1} 文件缺失或不完整');
    }
    final chapter = _chapterFromValue(
      jsonDecode(file.readAsStringSync(encoding: utf8)),
      index,
    );
    _cache[index] = chapter;
    while (_cache.length > 8) {
      _cache.remove(_cache.keys.first);
    }
    return chapter;
  }
}

class _LazyChapter extends Chapter {
  final _LazyChapterStore store;
  final bool richContent;

  _LazyChapter({
    required super.index,
    required super.title,
    required super.volumeTitle,
    required this.store,
    required this.richContent,
  }) : super(content: '');

  @override
  String get content => store.load(index).content;

  @override
  List<EpubContentBlock> get epubBlocks => store.load(index).epubBlocks;

  @override
  bool get hasRichEpubContent => richContent;
}

/// Persists small preferences in SharedPreferences and book content in files.
///
/// Storing an entire novel in SharedPreferences is slow and can exceed platform
/// limits. Chapter files therefore live in the app's documents directory. The
/// legacy preference key is still read once so early Flutter builds migrate
/// without losing imported books.
class StorageService {
  StorageService({Directory? documentsDirectory})
    : _providedDocumentsDirectory = documentsDirectory;

  final Directory? _providedDocumentsDirectory;
  Future<Directory>? _appDataDirectory;

  static Future<void> _libraryMutationQueue = Future<void>.value();
  static final Map<String, Future<void>> _chapterWriteQueues =
      <String, Future<void>>{};
  static final Map<String, int> _preferenceWriteVersions = <String, int>{};
  static final Map<String, Future<void>> _preferenceWriteQueues =
      <String, Future<void>>{};
  static final Set<String> _deletedBookIds = <String>{};
  static int _nextPreferenceWriteVersion = 0;

  Future<List<Book>> getBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final metadata = _readBookMetadata(prefs);
    final books = <Book>[];

    // A small batch keeps shelf startup responsive without reading every large
    // chapter file at once and briefly doubling the app's memory usage.
    const batchSize = 4;
    for (var start = 0; start < metadata.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, metadata.length);
      final batch = await Future.wait(
        metadata.sublist(start, end).map((map) async {
          try {
            final id = map['id'] as String;
            if (map['format'] == BookFormat.pdf.name) {
              return Book.fromJson(map, const <Chapter>[]);
            }
            final chapters = await _loadChapters(id, prefs);
            if (chapters.isEmpty) return null;
            return upgradeLegacyTxtBook(Book.fromJson(map, chapters));
          } on Object {
            // One damaged entry should not prevent the rest of the shelf loading.
            return null;
          }
        }),
      );
      books.addAll(batch.whereType<Book>());
    }
    return books;
  }

  /// Loads only shelf metadata. Chapter payloads stay on disk until a book is
  /// opened, keeping startup time and resident memory stable as the shelf grows.
  Future<List<Book>> getBookSummaries() async {
    final prefs = await SharedPreferences.getInstance();
    final summaries = <Book>[];
    for (final map in _readBookMetadata(prefs)) {
      try {
        summaries.add(Book.fromJson(map, const <Chapter>[]));
      } on Object {
        // Keep other shelf entries usable if one metadata record is damaged.
      }
    }
    return summaries;
  }

  Future<Book?> getBook(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final metadata = _readBookMetadata(
      prefs,
    ).where((map) => map['id'] == bookId);
    if (metadata.isEmpty) return null;
    try {
      if (metadata.first['format'] == BookFormat.pdf.name) {
        final pdfBook = Book.fromJson(metadata.first, const <Chapter>[]);
        final sourcePath = pdfBook.sourcePath;
        if (sourcePath == null || !await File(sourcePath).exists()) return null;
        return pdfBook;
      }
      final chapters = await _loadChapters(bookId, prefs);
      if (chapters.isEmpty) return null;
      final storedBook = Book.fromJson(metadata.first, chapters);
      final readableBook = upgradeLegacyTxtBook(storedBook);
      if (!identical(readableBook, storedBook)) {
        try {
          final storedProgress = await getProgress(bookId);
          // Persist the upgraded directory so subsequent opens and shelf
          // summaries use the new parser result without repeating the work.
          await saveBook(readableBook);
          if (storedProgress != null) {
            await saveProgress(
              _remapProgressAfterReparse(
                storedProgress,
                storedBook.chapters,
                readableBook.chapters,
              ),
            );
          }
        } on Object {
          // The reparsed in-memory copy is still safe to read this session.
        }
      }
      return readableBook;
    } on Object {
      return null;
    }
  }

  /// Performs a bounded shelf health check without decoding the full chapter
  /// payload. It catches missing files and obvious interrupted/truncated JSON
  /// while preserving getBookSummaries()'s low-memory startup behavior.
  Future<BookAvailability> checkBookAvailability(Book book) async {
    try {
      if (book.isPdf) {
        final sourcePath = book.sourcePath;
        return sourcePath != null && await File(sourcePath).exists()
            ? BookAvailability.available
            : BookAvailability.sourceMissing;
      }

      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString('$_kChapterPrefix${book.id}');
      var hasReadablePayload = legacy != null && legacy.trim().isNotEmpty;
      if (!hasReadablePayload) {
        final directory = await _chapterDirectory(book.id);
        for (final candidate in <Directory>[
          directory,
          Directory('${directory.path}.tmp'),
          Directory('${directory.path}.bak'),
        ]) {
          if (await _chapterDirectoryLooksPlausible(candidate)) {
            hasReadablePayload = true;
            break;
          }
        }
      }
      if (!hasReadablePayload) {
        final file = await _chapterFile(book.id);
        for (final candidate in <File>[
          file,
          File('${file.path}.tmp'),
          File('${file.path}.bak'),
        ]) {
          if (await _chapterPayloadLooksPlausible(candidate)) {
            hasReadablePayload = true;
            break;
          }
        }
      }
      if (!hasReadablePayload) return BookAvailability.payloadMissing;

      if (book.format == BookFormat.epub) {
        final sourcePath = book.sourcePath;
        if (sourcePath != null && !await Directory(sourcePath).exists()) {
          return BookAvailability.resourceMissing;
        }
      }
      return BookAvailability.available;
    } on Object {
      // A transient stat/read failure is not enough evidence to label a book
      // damaged and invite deletion from the shelf.
      return BookAvailability.available;
    }
  }

  Future<void> saveBook(Book book) async {
    if (book.isPdf &&
        (book.sourcePath == null ||
            book.pageCount == null ||
            book.pageCount! <= 0)) {
      throw const FormatException('PDF 文件路径或页数无效');
    }
    if (!book.isPdf && book.chapters.isEmpty) {
      throw const FormatException('书籍没有可保存的章节');
    }

    await _enqueueLibraryMutation(() async {
      // Save the large payload first. The shelf metadata is only committed
      // after the chapter file is safely in place.
      if (!book.isPdf) {
        await _saveChapters(book.id, book.chapters);
      }
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final existingIndex = metadata.indexWhere(
        (item) => item['id'] == book.id,
      );
      if (existingIndex >= 0) {
        metadata[existingIndex] = book.toJson();
      } else {
        metadata.insert(0, book.toJson());
      }
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
      _deletedBookIds.remove(book.id);
    });
  }

  Future<void> renameBook(String bookId, String title) async {
    final normalizedTitle = title.trim();
    if (bookId.isEmpty || normalizedTitle.isEmpty) {
      throw const FormatException('书籍名称不能为空');
    }
    if (normalizedTitle.length > 120) {
      throw const FormatException('书籍名称不能超过 120 个字符');
    }

    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final index = metadata.indexWhere((book) => book['id'] == bookId);
      if (index < 0) throw StateError('书籍不存在或已删除');
      metadata[index]['title'] = normalizedTitle;
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
    });
  }

  /// Persists the shelf order without rewriting chapter payloads. Unknown
  /// metadata is retained so a concurrent background update cannot make a book
  /// disappear merely because it was not present in the drag snapshot.
  Future<void> saveBookOrder(List<String> bookIds) async {
    final seen = <String>{};
    final requested = bookIds
        .where((id) => id.isNotEmpty && seen.add(id))
        .toList(growable: false);
    if (requested.isEmpty) return;

    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final byId = <String, Map<String, dynamic>>{
        for (final book in metadata) book['id'] as String: book,
      };
      final reordered = <Map<String, dynamic>>[];
      for (final id in requested) {
        final book = byId.remove(id);
        if (book != null) reordered.add(book);
      }
      for (final book in metadata) {
        final id = book['id'] as String;
        final remaining = byId.remove(id);
        if (remaining != null) reordered.add(remaining);
      }
      await _setString(prefs, _kBooksKey, jsonEncode(reordered));
    });
  }

  /// Persists per-chapter counts and their sum in one metadata transaction.
  /// A single chapter-body scan is therefore authoritative for both displays.
  Future<void> saveWordCounts(
    Book sourceBook,
    List<int> chapterWordCounts,
  ) async {
    if (sourceBook.id.isEmpty ||
        sourceBook.isPdf ||
        chapterWordCounts.length != sourceBook.chapterCount ||
        chapterWordCounts.any((count) => count < 0)) {
      return;
    }
    final safeCounts = <int>[
      for (final count in chapterWordCounts) count.clamp(0, 0x7fffffffffffffff),
    ];
    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final index = metadata.indexWhere((book) => book['id'] == sourceBook.id);
      if (index < 0) return;

      final current = metadata[index];
      // Do not let a count from an older parse overwrite a newly re-imported
      // or migrated directory that happens to reuse the same book ID.
      if (!_matchesBookRevision(current, sourceBook)) return;
      current['chapterWordCounts'] = safeCounts;
      var total = 0;
      for (final count in safeCounts) {
        total = (total + count).clamp(0, 0x7fffffffffffffff);
      }
      current['wordCount'] = total;
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
    });
  }

  Future<void> deleteBook(String bookId) async {
    if (bookId.isEmpty) return;
    _deletedBookIds.add(bookId);
    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final removedMetadata = metadata
          .where((book) => book['id'] == bookId)
          .firstOrNull;
      metadata.removeWhere((book) => book['id'] == bookId);
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
      final progressKey = '$_kProgressPrefix$bookId';
      final pdfProgressKey = '$_kPdfProgressPrefix$bookId';
      final pdfBookmarksKey = '$_kPdfBookmarksPrefix$bookId';
      final pdfNotesKey = '$_kPdfNotesPrefix$bookId';
      final tocCollapsedKey = '$_kTocCollapsedPrefix$bookId';
      final progressVersion = _invalidatePreferenceWrite(progressKey);
      final pdfProgressVersion = _invalidatePreferenceWrite(pdfProgressKey);
      final pdfBookmarksVersion = _invalidatePreferenceWrite(pdfBookmarksKey);
      final pdfNotesVersion = _invalidatePreferenceWrite(pdfNotesKey);
      final tocVersion = _invalidatePreferenceWrite(tocCollapsedKey);
      await _enqueuePreferenceWrite(progressKey, () async {
        if (_preferenceWriteVersions[progressKey] != progressVersion) return;
        await prefs.remove(progressKey);
      });
      await _enqueuePreferenceWrite(tocCollapsedKey, () async {
        if (_preferenceWriteVersions[tocCollapsedKey] != tocVersion) return;
        await prefs.remove(tocCollapsedKey);
      });
      await _enqueuePreferenceWrite(pdfProgressKey, () async {
        if (_preferenceWriteVersions[pdfProgressKey] != pdfProgressVersion) {
          return;
        }
        await prefs.remove(pdfProgressKey);
      });
      await _enqueuePreferenceWrite(pdfBookmarksKey, () async {
        if (_preferenceWriteVersions[pdfBookmarksKey] != pdfBookmarksVersion) {
          return;
        }
        await prefs.remove(pdfBookmarksKey);
      });
      await _enqueuePreferenceWrite(pdfNotesKey, () async {
        if (_preferenceWriteVersions[pdfNotesKey] != pdfNotesVersion) return;
        await prefs.remove(pdfNotesKey);
      });
      await prefs.remove('$_kChapterPrefix$bookId');

      final file = await _chapterFile(bookId);
      for (final candidate in [
        file,
        File('${file.path}.tmp'),
        File('${file.path}.bak'),
        File('${file.path}.presplit'),
      ]) {
        try {
          if (await candidate.exists()) await candidate.delete();
        } on FileSystemException {
          // Metadata has already been removed. A stale private payload is less
          // harmful than making the deleted book reappear or crashing the UI.
        }
      }
      final directory = await _chapterDirectory(bookId);
      for (final candidate in <Directory>[
        directory,
        Directory('${directory.path}.tmp'),
        Directory('${directory.path}.bak'),
      ]) {
        try {
          if (await candidate.exists()) await candidate.delete(recursive: true);
        } on FileSystemException {
          // Metadata remains authoritative; maintenance can retry the payload.
        }
      }
      await _deleteManagedSourcePath(removedMetadata?['sourcePath']);
    });
  }

  /// Removes files left by an import that failed before its metadata commit.
  Future<void> discardImportedBook(Book book) async {
    await deleteBook(book.id);
    await _deleteManagedSourcePath(book.sourcePath);
  }

  /// Reclaims private payloads that are no longer referenced by shelf
  /// metadata. A grace period protects imports that wrote their files but have
  /// not committed metadata yet, as well as recoverable interrupted writes.
  Future<StorageCleanupResult> collectOrphanedData({
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? referenceTime,
  }) async {
    if (gracePeriod.isNegative) {
      throw ArgumentError.value(gracePeriod, 'gracePeriod', '不能为负数');
    }
    final prefs = await SharedPreferences.getInstance();
    final metadata = _readBookMetadataForCleanup(prefs);
    // A malformed shelf record is not proof that every private payload is an
    // orphan. Preserve all data and retry after the metadata issue is resolved.
    if (metadata == null) {
      return const StorageCleanupResult(removedFiles: 0, removedDirectories: 0);
    }
    final root = (await getAppDataDirectory()).absolute;
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
        p.join(booksDirectory.path, '${_safeBookId(id)}.json'),
      ).absolute;
      referencedChapterPaths.addAll(<String>{
        file.path,
        '${file.path}.tmp',
        '${file.path}.bak',
        '${file.path}.presplit',
      });
      final directory = Directory(
        p.join(booksDirectory.path, _safeBookId(id)),
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
              !await _isOlderThan(entity, cutoff)) {
            continue;
          }
          if (entity is File &&
              _isChapterPayloadName(p.basename(entity.path)) &&
              !_pathsContain(referencedChapterPaths, entity.absolute.path)) {
            try {
              await entity.delete();
              removedFiles++;
            } on FileSystemException {
              // Best-effort cleanup; a later maintenance pass can retry.
            }
          } else if (entity is Directory &&
              _isChapterDirectoryName(p.basename(entity.path)) &&
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
    final pdfDirectory = Directory(p.join(root.path, 'pdf')).absolute;
    final referencedEpubPaths = <String>{};
    final referencedPdfPaths = <String>{};
    for (final book in metadata) {
      final sourcePath = book['sourcePath'];
      if (sourcePath is! String || sourcePath.trim().isEmpty) continue;
      final absolutePath = p.normalize(File(sourcePath.trim()).absolute.path);
      if (book['format'] == BookFormat.epub.name &&
          _isManagedChild(epubDirectory.path, absolutePath)) {
        referencedEpubPaths.add(absolutePath);
      } else if (book['format'] == BookFormat.pdf.name &&
          _isManagedChild(pdfDirectory.path, absolutePath)) {
        referencedPdfPaths.add(absolutePath);
      }
    }

    if (await epubDirectory.exists()) {
      try {
        await for (final entity in epubDirectory.list(followLinks: false)) {
          if (entity is! Directory ||
              !_isManagedChild(epubDirectory.path, entity.absolute.path) ||
              _pathsContain(referencedEpubPaths, entity.absolute.path) ||
              !await _isOlderThan(entity, cutoff)) {
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
        // Continue with PDF cleanup.
      }
    }

    if (await pdfDirectory.exists()) {
      try {
        await for (final entity in pdfDirectory.list(followLinks: false)) {
          if (entity is! File ||
              !_isManagedChild(pdfDirectory.path, entity.absolute.path) ||
              _pathsContain(referencedPdfPaths, entity.absolute.path) ||
              !await _isOlderThan(entity, cutoff)) {
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

    return StorageCleanupResult(
      removedFiles: removedFiles,
      removedDirectories: removedDirectories,
    );
  }

  List<Map<String, dynamic>> _readBookMetadata(SharedPreferences prefs) {
    final raw = prefs.getString(_kBooksKey);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .where(
            (map) => map['id'] is String && (map['id'] as String).isNotEmpty,
          )
          .toList();
    } on Object {
      return <Map<String, dynamic>>[];
    }
  }

  List<Map<String, dynamic>>? _readBookMetadataForCleanup(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString(_kBooksKey);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final metadata = <Map<String, dynamic>>[];
      for (final value in decoded) {
        if (value is! Map) return null;
        final map = Map<String, dynamic>.from(value);
        final id = map['id'];
        if (id is! String || id.isEmpty) return null;
        metadata.add(map);
      }
      return metadata;
    } on Object {
      return null;
    }
  }

  Future<List<Chapter>> _loadChapters(
    String bookId,
    SharedPreferences prefs,
  ) async {
    final legacyKey = '$_kChapterPrefix$bookId';
    final legacyRaw = prefs.getString(legacyKey);
    if (legacyRaw != null) {
      final chapters = _chaptersFromJson(legacyRaw);
      try {
        // Best-effort one-time migration from SharedPreferences to a normal
        // file. Opening the book must not wait indefinitely for platform
        // storage channels, so the legacy payload remains available if the
        // migration cannot finish quickly.
        await _saveChapters(bookId, chapters).timeout(_kLegacyMigrationTimeout);
        await prefs.remove(legacyKey);
      } on Object {
        // Reading must win over migration. If file storage is unavailable, keep
        // the legacy payload in preferences and let the user open the book.
      }
      return chapters;
    }

    final directory = await _chapterDirectory(
      bookId,
    ).timeout(_kChapterIoTimeout);
    for (final candidate in <Directory>[
      directory,
      Directory('${directory.path}.tmp'),
      Directory('${directory.path}.bak'),
    ]) {
      try {
        if (!await candidate.exists().timeout(_kChapterIoTimeout)) continue;
        final chapters = await _loadChapterDirectory(
          candidate,
        ).timeout(_kChapterIoTimeout);
        if (candidate.path != directory.path) {
          final recovered = _materializeChapters(chapters);
          try {
            await _saveChapters(bookId, recovered).timeout(_kChapterIoTimeout);
            return await _loadChapterDirectory(
              directory,
            ).timeout(_kChapterIoTimeout);
          } on Object {
            // The eager recovered copy remains readable for this session.
            return recovered;
          }
        }
        return chapters;
      } on Object {
        // Try a temporary/backup directory, then the legacy monolithic file.
      }
    }

    final file = await _chapterFile(bookId).timeout(_kChapterIoTimeout);
    final candidates = <File>[
      file,
      File('${file.path}.tmp'),
      File('${file.path}.bak'),
    ];
    for (final candidate in candidates) {
      try {
        if (!await candidate.exists().timeout(_kChapterIoTimeout)) continue;
        final raw = await candidate
            .readAsString(encoding: utf8)
            .timeout(_kChapterIoTimeout);
        // Decoding a multi-megabyte JSON payload on the UI isolate makes the
        // reader look frozen. Parse it in a worker isolate instead.
        final chapters = await Isolate.run(
          () => _chaptersFromJson(raw),
        ).timeout(_kChapterIoTimeout);
        if (candidate.path != file.path) {
          try {
            await _saveChapters(bookId, chapters).timeout(_kChapterIoTimeout);
          } on Object {
            // The recovered in-memory copy is still readable for this session.
          }
        }
        unawaited(
          _saveChapters(
            bookId,
            chapters,
          ).catchError((Object _, StackTrace _) {}),
        );
        return chapters;
      } on Object {
        // Try the temporary/backup copy left by an interrupted atomic write.
      }
    }

    return [];
  }

  Future<void> _saveChapters(String bookId, List<Chapter> chapters) async {
    final directory = await _chapterDirectory(bookId);
    return _enqueueChapterWrite(directory.path, () async {
      await _writeChapterDirectory(directory, chapters);
      final legacyFile = await _chapterFile(bookId);
      for (final candidate in <File>[
        legacyFile,
        File('${legacyFile.path}.tmp'),
        File('${legacyFile.path}.bak'),
        File('${legacyFile.path}.presplit'),
      ]) {
        try {
          if (await candidate.exists()) await candidate.delete();
        } on FileSystemException {
          // The new directory is authoritative; old cleanup can retry later.
        }
      }
    });
  }

  Future<List<Chapter>> _loadChapterDirectory(Directory directory) async {
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    final rawManifest = await manifestFile.readAsString(encoding: utf8);
    final manifest = await Isolate.run(
      () => _chapterManifestFromJson(rawManifest),
    );
    if (manifest['version'] != 2 || manifest['chapters'] is! List) {
      throw const FormatException('章节清单版本不受支持');
    }
    final entries = manifest['chapters'] as List;
    if (entries.isEmpty || entries.length > 1000000) {
      throw const FormatException('章节清单为空或过大');
    }
    if (manifest['chapterCount'] is! num ||
        (manifest['chapterCount'] as num).toInt() != entries.length) {
      throw const FormatException('章节清单数量不一致');
    }
    final chaptersDirectory = Directory(p.join(directory.path, 'chapters'));
    if (!await chaptersDirectory.exists()) {
      throw const FormatException('章节目录不存在');
    }
    final fileNames = <String>[];
    final expectedBytes = <int?>[];
    final titles = <String>[];
    final volumeTitles = <String?>[];
    final richContent = <bool>[];
    for (final rawEntry in entries) {
      if (rawEntry is! Map) throw const FormatException('章节清单条目格式错误');
      final entry = Map<String, dynamic>.from(rawEntry);
      final fileName = entry['file'];
      final title = entry['title'];
      if (fileName is! String ||
          !RegExp(r'^\d{6,}\.json$').hasMatch(fileName) ||
          title is! String ||
          title.trim().isEmpty) {
        throw const FormatException('章节清单条目格式错误');
      }
      fileNames.add(fileName);
      expectedBytes.add(
        entry['bytes'] is num ? (entry['bytes'] as num).toInt() : null,
      );
      titles.add(title);
      final volumeTitle = entry['volumeTitle'];
      volumeTitles.add(
        volumeTitle is String && volumeTitle.trim().isNotEmpty
            ? volumeTitle.trim()
            : null,
      );
      richContent.add(entry['hasRichContent'] == true);
    }
    final store = _LazyChapterStore(
      chaptersDirectoryPath: chaptersDirectory.path,
      fileNames: fileNames,
      expectedBytes: expectedBytes,
    );
    return List<Chapter>.generate(
      entries.length,
      (index) => _LazyChapter(
        index: index,
        title: titles[index],
        volumeTitle: volumeTitles[index],
        store: store,
        richContent: richContent[index],
      ),
      growable: false,
    );
  }

  Future<void> _writeChapterDirectory(
    Directory directory,
    List<Chapter> chapters,
  ) async {
    final temporary = Directory('${directory.path}.tmp');
    final backup = Directory('${directory.path}.bak');
    if (await temporary.exists()) await temporary.delete(recursive: true);
    final temporaryChapters = Directory(p.join(temporary.path, 'chapters'));
    await temporaryChapters.create(recursive: true);

    final manifestEntries = <Map<String, dynamic>>[];
    const batchSize = 16;
    for (var start = 0; start < chapters.length; start += batchSize) {
      final end = math.min(chapters.length, start + batchSize);
      final batch = chapters.sublist(start, end);
      final payloads = await Isolate.run(() => _chapterBatchToJson(batch));
      for (var offset = 0; offset < payloads.length; offset++) {
        final index = start + offset;
        final fileName = '${index.toString().padLeft(6, '0')}.json';
        final chapterFile = File(p.join(temporaryChapters.path, fileName));
        await chapterFile.writeAsString(
          payloads[offset],
          encoding: utf8,
          flush: true,
        );
        final chapter = chapters[index];
        manifestEntries.add(<String, dynamic>{
          'file': fileName,
          'bytes': await chapterFile.length(),
          'title': chapter.title,
          if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle,
          'hasRichContent': chapter.hasRichEpubContent,
        });
      }
    }
    await File(p.join(temporary.path, 'manifest.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'version': 2,
        'chapterCount': chapters.length,
        'chapters': manifestEntries,
      }),
      encoding: utf8,
      flush: true,
    );

    if (await directory.exists()) {
      if (await backup.exists()) await backup.delete(recursive: true);
      await directory.rename(backup.path);
    }
    try {
      await temporary.rename(directory.path);
      if (await backup.exists()) await backup.delete(recursive: true);
    } on Object {
      if (await backup.exists() && !await directory.exists()) {
        await backup.rename(directory.path);
      }
      rethrow;
    }
  }

  Future<ReadingProgress?> getProgress(String bookId) async {
    if (_deletedBookIds.contains(bookId)) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kProgressPrefix$bookId');
    if (raw == null) return null;
    try {
      return ReadingProgress.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      return null;
    }
  }

  Future<void> saveProgress(ReadingProgress progress) async {
    if (progress.bookId.isEmpty || _deletedBookIds.contains(progress.bookId)) {
      return;
    }
    await _setLatestString(
      '$_kProgressPrefix${progress.bookId}',
      jsonEncode(progress.toJson()),
    );
  }

  Future<PdfReadingProgress?> getPdfProgress(
    String bookId, {
    required int pageCount,
    bool migrateLegacy = true,
  }) async {
    if (bookId.isEmpty || _deletedBookIds.contains(bookId) || pageCount <= 0) {
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kPdfProgressPrefix$bookId');
    if (raw != null) {
      try {
        final stored = PdfReadingProgress.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        if (stored.bookId == bookId) {
          return PdfReadingProgress(
            bookId: bookId,
            pageIndex: stored.pageIndex.clamp(0, pageCount - 1),
            pageCount: pageCount,
            lastReadDate: stored.lastReadDate,
          );
        }
      } on Object {
        // Fall through to the legacy ReadingProgress migration below.
      }
    }

    final legacy = await getProgress(bookId);
    if (legacy == null) return null;
    final migrated = PdfReadingProgress(
      bookId: bookId,
      pageIndex: legacy.chapterIndex.clamp(0, pageCount - 1),
      pageCount: pageCount,
      lastReadDate: legacy.lastReadDate,
    );
    if (migrateLegacy) await savePdfProgress(migrated);
    return migrated;
  }

  Future<void> savePdfProgress(PdfReadingProgress progress) async {
    if (progress.bookId.isEmpty ||
        progress.pageCount <= 0 ||
        _deletedBookIds.contains(progress.bookId)) {
      return;
    }
    final safe = PdfReadingProgress(
      bookId: progress.bookId,
      pageIndex: progress.pageIndex.clamp(0, progress.pageCount - 1),
      pageCount: progress.pageCount,
      lastReadDate: progress.lastReadDate,
    );
    await _setLatestString(
      '$_kPdfProgressPrefix${progress.bookId}',
      jsonEncode(safe.toJson()),
    );
  }

  Future<ReadingProgress?> getShelfProgress(Book book) async {
    if (!book.isPdf) return getProgress(book.id);
    final pageCount = book.pageCount;
    if (pageCount == null || pageCount <= 0) return null;
    return (await getPdfProgress(
      book.id,
      pageCount: pageCount,
      migrateLegacy: false,
    ))?.toShelfProgress();
  }

  Future<Set<int>> getPdfBookmarks(String bookId, int pageCount) async {
    if (bookId.isEmpty || pageCount <= 0 || _deletedBookIds.contains(bookId)) {
      return <int>{};
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kPdfBookmarksPrefix$bookId');
    if (raw == null) return <int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <int>{};
      return decoded
          .whereType<num>()
          .map((value) => value.toInt())
          .where((page) => page >= 0 && page < pageCount)
          .take(2000)
          .toSet();
    } on Object {
      return <int>{};
    }
  }

  Future<void> savePdfBookmarks(
    String bookId,
    Set<int> pages,
    int pageCount,
  ) async {
    if (bookId.isEmpty || pageCount <= 0 || _deletedBookIds.contains(bookId)) {
      return;
    }
    final safePages =
        pages.where((page) => page >= 0 && page < pageCount).take(2000).toList()
          ..sort();
    await _setLatestString(
      '$_kPdfBookmarksPrefix$bookId',
      jsonEncode(safePages),
    );
  }

  Future<Map<int, String>> getPdfNotes(String bookId, int pageCount) async {
    if (bookId.isEmpty || pageCount <= 0 || _deletedBookIds.contains(bookId)) {
      return <int, String>{};
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kPdfNotesPrefix$bookId');
    if (raw == null) return <int, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <int, String>{};
      final notes = <int, String>{};
      for (final entry in decoded.entries.take(2000)) {
        final page = int.tryParse(entry.key.toString());
        final note = entry.value;
        if (page == null ||
            page < 0 ||
            page >= pageCount ||
            note is! String ||
            note.trim().isEmpty) {
          continue;
        }
        notes[page] = note.trim().substring(
          0,
          math.min(4000, note.trim().length),
        );
      }
      return notes;
    } on Object {
      return <int, String>{};
    }
  }

  Future<void> savePdfNotes(
    String bookId,
    Map<int, String> notes,
    int pageCount,
  ) async {
    if (bookId.isEmpty || pageCount <= 0 || _deletedBookIds.contains(bookId)) {
      return;
    }
    final safe = <String, String>{};
    for (final entry in notes.entries.take(2000)) {
      final note = entry.value.trim();
      if (entry.key < 0 || entry.key >= pageCount || note.isEmpty) continue;
      safe[entry.key.toString()] = note.substring(
        0,
        math.min(4000, note.length),
      );
    }
    await _setLatestString('$_kPdfNotesPrefix$bookId', jsonEncode(safe));
  }

  Future<Set<String>> getCollapsedTocGroups(String bookId) async {
    if (bookId.isEmpty) return <String>{};
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kTocCollapsedPrefix$bookId');
    if (raw == null) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && value.length <= 256)
          .take(512)
          .toSet();
    } on Object {
      return <String>{};
    }
  }

  Future<void> saveCollapsedTocGroups(
    String bookId,
    Set<String> groupIds,
  ) async {
    if (bookId.isEmpty || _deletedBookIds.contains(bookId)) return;
    final values =
        groupIds
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty && value.length <= 256)
            .take(512)
            .toList()
          ..sort();
    await _setLatestString('$_kTocCollapsedPrefix$bookId', jsonEncode(values));
  }

  static const _defaultSettings = ReaderSettings();

  Future<ReaderSettings> getSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSettingsKey);
    if (raw == null) return _defaultSettings;
    try {
      return ReaderSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      return _defaultSettings;
    }
  }

  Future<void> saveSettings(ReaderSettings settings) async {
    final version = ++_nextPreferenceWriteVersion;
    _preferenceWriteVersions[_kSettingsKey] = version;
    await _enqueuePreferenceWrite(_kSettingsKey, () async {
      if (_preferenceWriteVersions[_kSettingsKey] != version) return;
      final prefs = await SharedPreferences.getInstance();
      if (_preferenceWriteVersions[_kSettingsKey] != version) return;

      String? previousImportedFontPath;
      final previousRaw = prefs.getString(_kSettingsKey);
      if (previousRaw != null) {
        try {
          previousImportedFontPath = ReaderSettings.fromJson(
            Map<String, dynamic>.from(jsonDecode(previousRaw) as Map),
          ).importedFontPath;
        } on Object {
          // A damaged old settings record should not block saving a valid one.
        }
      }
      await _setString(prefs, _kSettingsKey, jsonEncode(settings.toJson()));

      // A newer queued setting may still refer to the previous font. Only the
      // latest write is allowed to reclaim the old managed file.
      if (_preferenceWriteVersions[_kSettingsKey] != version) return;
      final currentImportedFontPath = settings.importedFontPath;
      if (previousImportedFontPath != null &&
          previousImportedFontPath != currentImportedFontPath) {
        await _deleteManagedFont(previousImportedFontPath);
      }
    });
  }

  Future<void> _deleteManagedFont(String fontPath) async {
    final root = await getAppDataDirectory();
    final fontsDirectory = Directory(p.join(root.path, 'fonts')).absolute.path;
    final font = File(fontPath).absolute;
    if (!p.isWithin(fontsDirectory, font.path)) return;
    try {
      if (await font.exists()) await font.delete();
    } on FileSystemException {
      // Font cleanup is best-effort and must not invalidate saved settings.
    }
  }

  Future<File> saveImportedFont(String sourcePath, String fileName) async {
    final extension = p.extension(fileName).toLowerCase();
    if (extension != '.ttf' && extension != '.otf') {
      throw const FormatException('仅支持 .ttf 或 .otf 字体文件');
    }
    final source = File(sourcePath);
    final stat = await source.stat();
    const maxFontBytes = 64 * 1024 * 1024;
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw const FormatException('所选字体文件为空或无法读取');
    }
    if (stat.size > maxFontBytes) {
      throw const FormatException('字体文件过大，请选择小于 64 MB 的字体');
    }

    final root = await getAppDataDirectory();
    final directory = Directory(p.join(root.path, 'fonts'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final safeName = p
        .basenameWithoutExtension(fileName)
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-\u4e00-\u9fa5]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    final baseName = safeName.isEmpty ? 'font' : safeName;
    final target = File(
      p.join(
        directory.path,
        '${DateTime.now().microsecondsSinceEpoch}_$baseName$extension',
      ),
    );

    return source.copy(target.path);
  }

  Future<File> saveImportedPdf(String sourcePath, String bookId) async {
    final source = File(sourcePath);
    final stat = await source.stat();
    const maxPdfBytes = 1024 * 1024 * 1024;
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw const FormatException('PDF 文件为空或无法读取');
    }
    if (stat.size > maxPdfBytes) {
      throw const FormatException('PDF 文件过大，请选择不超过 1 GB 的文件');
    }
    final root = await getAppDataDirectory();
    final directory = Directory(p.join(root.path, 'pdf'));
    if (!await directory.exists()) await directory.create(recursive: true);
    final safeId = base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');
    final target = File(p.join(directory.path, '$safeId.pdf'));
    final temporary = File('${target.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    await source.copy(temporary.path);
    if (await target.exists()) await target.delete();
    return temporary.rename(target.path);
  }

  Future<Directory> getAppDataDirectory() async {
    return _appDataDirectory ??= _createAppDataDirectory();
  }

  Future<Directory> _createAppDataDirectory() async {
    final documents =
        _providedDocumentsDirectory ?? await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'ReadVibe'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<File> _chapterFile(String bookId) async {
    final root = await getAppDataDirectory();
    final directory = Directory(p.join(root.path, 'books'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final safeId = _safeBookId(bookId);
    return File(p.join(directory.path, '$safeId.json'));
  }

  Future<Directory> _chapterDirectory(String bookId) async {
    final root = await getAppDataDirectory();
    final books = Directory(p.join(root.path, 'books'));
    if (!await books.exists()) await books.create(recursive: true);
    return Directory(p.join(books.path, _safeBookId(bookId)));
  }

  static Future<void> _enqueueLibraryMutation(Future<void> Function() action) {
    final operation = _libraryMutationQueue.then((_) => action());
    _libraryMutationQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<void> _enqueueChapterWrite(
    String path,
    Future<void> Function() action,
  ) {
    final previous = _chapterWriteQueues[path] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    late final Future<void> safeTail;
    safeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _chapterWriteQueues[path] = safeTail;
    return operation.whenComplete(() {
      if (identical(_chapterWriteQueues[path], safeTail)) {
        _chapterWriteQueues.remove(path);
      }
    });
  }

  static Future<void> _enqueuePreferenceWrite(
    String key,
    Future<void> Function() action,
  ) {
    final previous = _preferenceWriteQueues[key] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    late final Future<void> safeTail;
    safeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _preferenceWriteQueues[key] = safeTail;
    return operation.whenComplete(() {
      if (identical(_preferenceWriteQueues[key], safeTail)) {
        _preferenceWriteQueues.remove(key);
      }
    });
  }

  static Future<void> _setString(
    SharedPreferences prefs,
    String key,
    String value,
  ) async {
    final saved = await prefs.setString(key, value);
    if (!saved) throw FileSystemException('无法保存本地数据', key);
  }

  static Future<void> _setLatestString(String key, String value) async {
    final version = ++_nextPreferenceWriteVersion;
    _preferenceWriteVersions[key] = version;
    await _enqueuePreferenceWrite(key, () async {
      if (_preferenceWriteVersions[key] != version) return;
      final prefs = await SharedPreferences.getInstance();
      if (_preferenceWriteVersions[key] != version) return;
      await _setString(prefs, key, value);
    });
  }

  static int _invalidatePreferenceWrite(String key) {
    final version = ++_nextPreferenceWriteVersion;
    _preferenceWriteVersions[key] = version;
    return version;
  }

  Future<void> _deleteManagedSourcePath(Object? rawSourcePath) async {
    if (rawSourcePath is! String || rawSourcePath.trim().isEmpty) return;
    try {
      final root = await getAppDataDirectory();
      final pdfDirectory = Directory(p.join(root.path, 'pdf')).absolute.path;
      final epubDirectory = Directory(p.join(root.path, 'epub')).absolute.path;
      final sourcePath = rawSourcePath.trim();
      final sourceType = await FileSystemEntity.type(sourcePath);
      if (sourceType == FileSystemEntityType.file) {
        final source = File(sourcePath).absolute;
        if (!p.isWithin(pdfDirectory, source.path) || !await source.exists()) {
          return;
        }
        try {
          await PdfRendererService.clearFileCache(source.path);
        } on Object {
          // Cache cleanup is best-effort; the managed source remains deletable.
        }
        await source.delete();
      } else if (sourceType == FileSystemEntityType.directory) {
        final source = Directory(sourcePath).absolute;
        if (p.isWithin(epubDirectory, source.path) && await source.exists()) {
          await source.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Metadata remains authoritative if private resource cleanup is interrupted.
    }
  }
}

bool _matchesBookRevision(Map<String, dynamic> metadata, Book sourceBook) {
  final currentFileSize = metadata['fileSize'];
  final currentParserVersion = metadata['txtParserVersion'];
  final currentChapterCount = metadata['chapterCount'];
  final currentFormat = metadata['format'];
  return currentFileSize is num &&
      currentFileSize.toInt() == sourceBook.fileSize &&
      currentParserVersion is num &&
      currentParserVersion.toInt() == sourceBook.txtParserVersion &&
      currentChapterCount is num &&
      currentChapterCount.toInt() == sourceBook.chapterCount &&
      currentFormat == sourceBook.format.name;
}

String _safeBookId(String bookId) =>
    base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');

bool _isManagedChild(String parentPath, String candidatePath) =>
    p.isWithin(p.normalize(parentPath), p.normalize(candidatePath));

bool _pathsContain(Set<String> paths, String candidate) =>
    paths.any((path) => p.equals(path, candidate));

bool _isChapterPayloadName(String name) =>
    RegExp(r'^[A-Za-z0-9_-]+\.json(?:\.(?:tmp|bak|presplit))?$').hasMatch(name);

bool _isChapterDirectoryName(String name) =>
    RegExp(r'^[A-Za-z0-9_-]+(?:\.(?:tmp|bak))?$').hasMatch(name);

Future<bool> _isOlderThan(FileSystemEntity entity, DateTime cutoff) async {
  try {
    final stat = await entity.stat();
    return !stat.modified.isAfter(cutoff);
  } on FileSystemException {
    return false;
  }
}

Future<bool> _chapterPayloadLooksPlausible(File file) async {
  RandomAccessFile? input;
  try {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size < 2) return false;
    input = await file.open(mode: FileMode.read);
    final first = await input.readByte();
    await input.setPosition(stat.size - 1);
    final last = await input.readByte();
    return first == 0x5b && last == 0x5d;
  } on FileSystemException {
    return false;
  } finally {
    await input?.close();
  }
}

List<Chapter> _chaptersFromJson(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List || decoded.isEmpty) {
    throw const FormatException('章节数据为空或格式错误');
  }
  return decoded.indexed
      .map((entry) => _chapterFromValue(entry.$2, entry.$1))
      .toList();
}

Future<bool> _chapterDirectoryLooksPlausible(Directory directory) async {
  try {
    if (!await directory.exists()) return false;
    final chapters = Directory(p.join(directory.path, 'chapters'));
    if (!await chapters.exists()) return false;
    final manifest = File(p.join(directory.path, 'manifest.json'));
    final stat = await manifest.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size < 2 ||
        stat.size > 32 * 1024 * 1024) {
      return false;
    }
    final input = await manifest.open(mode: FileMode.read);
    try {
      final first = await input.readByte();
      await input.setPosition(stat.size - 1);
      final last = await input.readByte();
      return first == 0x7b && last == 0x7d;
    } finally {
      await input.close();
    }
  } on FileSystemException {
    return false;
  }
}

Map<String, dynamic> _chapterManifestFromJson(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('章节清单格式错误');
  return Map<String, dynamic>.from(decoded);
}

List<Chapter> _materializeChapters(List<Chapter> chapters) =>
    List<Chapter>.generate(chapters.length, (index) {
      final chapter = chapters[index];
      return Chapter(
        index: index,
        title: chapter.title,
        content: chapter.content,
        volumeTitle: chapter.volumeTitle,
        epubBlocks: chapter.epubBlocks,
      );
    }, growable: false);

List<String> _chapterBatchToJson(List<Chapter> chapters) => chapters
    .map((chapter) => jsonEncode(_chapterToJsonMap(chapter)))
    .toList(growable: false);

Chapter _chapterFromValue(Object? value, int index) {
  if (value is! Map) throw const FormatException('章节数据格式错误');
  final map = Map<String, dynamic>.from(value);
  final title = map['title'];
  final content = map['content'];
  if (title is! String || content is! String) {
    throw const FormatException('章节数据格式错误');
  }
  final rawVolumeTitle = map['volumeTitle'];
  final volumeTitle =
      rawVolumeTitle is String && rawVolumeTitle.trim().isNotEmpty
      ? rawVolumeTitle.trim()
      : null;
  final epubBlocks = _epubBlocksFromJson(map['epubBlocks']);
  final restoredContent = content.isNotEmpty || epubBlocks.isEmpty
      ? content
      : _plainContentFromEpubBlocks(epubBlocks);
  return Chapter(
    index: index,
    title: title,
    content: restoredContent,
    volumeTitle: volumeTitle,
    epubBlocks: epubBlocks,
  );
}

Map<String, dynamic> _chapterToJsonMap(Chapter chapter) => <String, dynamic>{
  'index': chapter.index,
  'title': chapter.title,
  // Rich EPUB blocks already contain the complete visible text. Avoid writing
  // a second full copy; plain text is rebuilt when the chapter is loaded.
  'content': chapter.epubBlocks.isEmpty ? chapter.content : '',
  if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle,
  if (chapter.epubBlocks.isNotEmpty)
    'epubBlocks': chapter.epubBlocks.map(_epubBlockToJson).toList(),
};

String _plainContentFromEpubBlocks(List<EpubContentBlock> blocks) {
  var body = blocks.where(
    (block) => block.isText && !block.isHeading && block.text.trim().isNotEmpty,
  );
  if (body.isEmpty) {
    body = blocks.where(
      (block) => block.isText && block.text.trim().isNotEmpty,
    );
  }
  return body.map((block) => block.text.trim()).join('\n');
}

List<EpubContentBlock> _epubBlocksFromJson(Object? raw) {
  if (raw is! List) return const <EpubContentBlock>[];
  final blocks = <EpubContentBlock>[];
  for (final value in raw) {
    if (value is! Map) continue;
    final map = Map<String, dynamic>.from(value);
    final kindName = map['kind'];
    final kind = EpubContentBlockKind.values
        .where((candidate) => candidate.name == kindName)
        .firstOrNull;
    if (kind == null) continue;
    final style = _epubStyleFromJson(map['style']);
    final runs = <EpubTextRun>[];
    final rawRuns = map['runs'];
    if (rawRuns is List) {
      for (final rawRun in rawRuns) {
        if (rawRun is! Map) continue;
        final run = Map<String, dynamic>.from(rawRun);
        final text = run['text'];
        if (text is! String || text.isEmpty) continue;
        runs.add(
          EpubTextRun(text: text, style: _epubStyleFromJson(run['style'])),
        );
      }
    }
    blocks.add(
      EpubContentBlock(
        kind: kind,
        text: map['text'] is String ? map['text'] as String : '',
        runs: List<EpubTextRun>.unmodifiable(runs),
        isHeading: map['isHeading'] == true,
        imagePath: map['imagePath'] is String
            ? map['imagePath'] as String
            : null,
        altText: map['altText'] is String ? map['altText'] as String : null,
        imageWidth: _jsonDouble(map['imageWidth']),
        imageHeight: _jsonDouble(map['imageHeight']),
        style: style,
      ),
    );
  }
  return List<EpubContentBlock>.unmodifiable(blocks);
}

Map<String, dynamic> _epubBlockToJson(EpubContentBlock block) => {
  'kind': block.kind.name,
  if (block.text.isNotEmpty) 'text': block.text,
  if (block.runs.isNotEmpty)
    'runs': block.runs
        .map((run) => {'text': run.text, 'style': _epubStyleToJson(run.style)})
        .toList(),
  if (block.isHeading) 'isHeading': true,
  if (block.imagePath != null) 'imagePath': block.imagePath,
  if (block.altText != null && block.altText!.isNotEmpty)
    'altText': block.altText,
  if (block.imageWidth != null) 'imageWidth': block.imageWidth,
  if (block.imageHeight != null) 'imageHeight': block.imageHeight,
  'style': _epubStyleToJson(block.style),
};

EpubContentStyle _epubStyleFromJson(Object? raw) {
  if (raw is! Map) return const EpubContentStyle();
  final map = Map<String, dynamic>.from(raw);
  return EpubContentStyle(
    fontScale: _jsonDouble(map['fontScale']) ?? 1,
    fontWeight: map['fontWeight'] is num
        ? (map['fontWeight'] as num).toInt().clamp(100, 900)
        : 400,
    italic: map['italic'] == true,
    underline: map['underline'] == true,
    textAlign: map['textAlign'] is String
        ? map['textAlign'] as String
        : 'start',
    lineHeightScale: _jsonDouble(map['lineHeightScale']) ?? 1,
    letterSpacingEm: _jsonDouble(map['letterSpacingEm']) ?? 0,
    textIndentEm: _jsonDouble(map['textIndentEm']) ?? 2,
    marginTopEm: _jsonDouble(map['marginTopEm']) ?? 0,
    marginBottomEm: _jsonDouble(map['marginBottomEm']) ?? 0,
    colorArgb: map['colorArgb'] is num
        ? (map['colorArgb'] as num).toInt()
        : null,
    backgroundColorArgb: map['backgroundColorArgb'] is num
        ? (map['backgroundColorArgb'] as num).toInt()
        : null,
    backgroundImagePath: map['backgroundImagePath'] is String
        ? map['backgroundImagePath'] as String
        : null,
  );
}

Map<String, dynamic> _epubStyleToJson(EpubContentStyle style) => {
  if (style.fontScale != 1) 'fontScale': style.fontScale,
  if (style.fontWeight != 400) 'fontWeight': style.fontWeight,
  if (style.italic) 'italic': true,
  if (style.underline) 'underline': true,
  if (style.textAlign != 'start') 'textAlign': style.textAlign,
  if (style.lineHeightScale != 1) 'lineHeightScale': style.lineHeightScale,
  if (style.letterSpacingEm != 0) 'letterSpacingEm': style.letterSpacingEm,
  if (style.textIndentEm != 2) 'textIndentEm': style.textIndentEm,
  if (style.marginTopEm != 0) 'marginTopEm': style.marginTopEm,
  if (style.marginBottomEm != 0) 'marginBottomEm': style.marginBottomEm,
  if (style.colorArgb != null) 'colorArgb': style.colorArgb,
  if (style.backgroundColorArgb != null)
    'backgroundColorArgb': style.backgroundColorArgb,
  if (style.backgroundImagePath != null)
    'backgroundImagePath': style.backgroundImagePath,
};

double? _jsonDouble(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}

ReadingProgress _remapProgressAfterReparse(
  ReadingProgress progress,
  List<Chapter> oldChapters,
  List<Chapter> newChapters,
) {
  if (oldChapters.isEmpty || newChapters.isEmpty) return progress;

  final oldIndex = progress.chapterIndex.clamp(0, oldChapters.length - 1);
  final oldLengths = oldChapters.map(_chapterReadingWeight).toList();
  final oldTotal = oldLengths.fold<double>(0, (sum, value) => sum + value);
  final localProgress =
      progress.chapterProgress[oldIndex] ?? progress.scrollProgress;
  final distanceBeforeOldChapter = oldLengths
      .take(oldIndex)
      .fold<double>(0, (sum, value) => sum + value);
  final overallProgress = oldTotal <= 0
      ? 0.0
      : (distanceBeforeOldChapter +
                localProgress.clamp(0.0, 1.0) * oldLengths[oldIndex]) /
            oldTotal;

  final newLengths = newChapters.map(_chapterReadingWeight).toList();
  final newTotal = newLengths.fold<double>(0, (sum, value) => sum + value);
  var remaining = overallProgress.clamp(0.0, 1.0) * newTotal;
  var newIndex = 0;
  while (newIndex < newLengths.length - 1 && remaining > newLengths[newIndex]) {
    remaining -= newLengths[newIndex];
    newIndex++;
  }
  final newLocalProgress = newLengths[newIndex] <= 0
      ? 0.0
      : (remaining / newLengths[newIndex]).clamp(0.0, 1.0).toDouble();

  return ReadingProgress(
    bookId: progress.bookId,
    chapterIndex: newIndex,
    scrollOffset: 0,
    scrollProgress: newLocalProgress,
    chapterOffsets: {newIndex: 0},
    chapterProgress: {newIndex: newLocalProgress},
    lastReadDate: progress.lastReadDate,
  );
}

double _chapterReadingWeight(Chapter chapter) {
  return (chapter.title.length + chapter.content.length)
      .clamp(1, 0x7fffffff)
      .toDouble();
}
