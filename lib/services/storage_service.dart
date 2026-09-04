import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';
import 'managed_book_resources.dart';
import 'storage/chapter_payload_codec.dart';
import 'reader_preferences_store.dart';
import 'txt_parser.dart';

export '../repositories/reader_repositories.dart' show StorageCleanupResult;

const _kBooksKey = 'readvibe_books';
const _kChapterPrefix = 'readvibe_chapters_';
// Large novels can exceed 10 MB. A two-second deadline was too aggressive on
// slower phones and could make a valid saved book appear unreadable.
const _kChapterIoTimeout = Duration(seconds: 30);
const _kLegacyMigrationTimeout = Duration(milliseconds: 250);

class _LazyChapterStore {
  final String chaptersDirectoryPath;
  final List<String> fileNames;
  final List<int?> expectedBytes;
  final List<String?> expectedDigests;
  final LinkedHashMap<int, Chapter> _cache = LinkedHashMap<int, Chapter>();

  _LazyChapterStore({
    required this.chaptersDirectoryPath,
    required this.fileNames,
    required this.expectedBytes,
    required this.expectedDigests,
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
    final raw = file.readAsStringSync(encoding: utf8);
    final expectedDigest = expectedDigests[index];
    if (expectedDigest != null &&
        sha256.convert(utf8.encode(raw)).toString() != expectedDigest) {
      throw FormatException('章节 ${index + 1} 校验失败');
    }
    final chapter = decodeChapterPayload(jsonDecode(raw), index);
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
  final int? richBlockCount;
  final bool? semanticHeading;

  _LazyChapter({
    required super.index,
    required super.title,
    required super.volumeTitle,
    required this.store,
    required this.richContent,
    required this.richBlockCount,
    required this.semanticHeading,
  }) : super(
         content: '',
         epubBlockCount: richBlockCount,
         hasSemanticHeading: semanticHeading,
       );

  @override
  String get content => store.load(index).content;

  @override
  List<EpubContentBlock> get epubBlocks => store.load(index).epubBlocks;

  @override
  bool get hasRichEpubContent => richContent;

  @override
  int get epubBlockCount =>
      richBlockCount ?? store.load(index).epubBlocks.length;

  @override
  bool get hasKnownEpubBlockCount => richBlockCount != null;

  @override
  bool get hasSemanticHeading =>
      semanticHeading ?? store.load(index).hasSemanticHeading;

  @override
  bool get hasKnownSemanticHeading => semanticHeading != null;
}

/// Persists small preferences in SharedPreferences and book content in files.
///
/// Storing an entire novel in SharedPreferences is slow and can exceed platform
/// limits. Chapter files therefore live in the app's documents directory. The
/// legacy preference key is still read once so early Flutter builds migrate
/// without losing imported books.
class StorageService
    implements LibraryRepository, ReaderRepository, PdfReaderRepository {
  StorageService({Directory? documentsDirectory, BookResourceStore? resources})
    : _providedDocumentsDirectory = documentsDirectory,
      _providedResources = resources;

  final Directory? _providedDocumentsDirectory;
  final BookResourceStore? _providedResources;
  late final BookResourceStore _resources =
      _providedResources ?? ManagedBookResources(this);
  Future<Directory>? _appDataDirectory;

  static Future<void> _libraryMutationQueue = Future<void>.value();
  static final Map<String, Future<void>> _chapterWriteQueues =
      <String, Future<void>>{};
  static final Set<String> _deletedBookIds = <String>{};
  late final ReaderPreferencesStore _readerPreferences = ReaderPreferencesStore(
    _deletedBookIds.contains,
    _resources.deleteFont,
  );

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
  @override
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

  @override
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
  @override
  Future<BookAvailability> checkBookAvailability(
    Book book, {
    bool deep = false,
  }) async {
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
          if (await _chapterDirectoryLooksPlausible(
            candidate,
            verifyContents: deep,
          )) {
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
          if (await _chapterPayloadLooksPlausible(
            candidate,
            verifyContents: deep,
          )) {
            hasReadablePayload = true;
            break;
          }
        }
      }
      if (!hasReadablePayload) return BookAvailability.payloadMissing;

      if (book.format == BookFormat.epub || book.format == BookFormat.docx) {
        final sourcePath = book.sourcePath;
        if (sourcePath != null && !await Directory(sourcePath).exists()) {
          return BookAvailability.resourceMissing;
        }
        for (final fontPath in book.embeddedFonts.values) {
          if (!await File(fontPath).exists()) {
            return BookAvailability.resourceMissing;
          }
        }
      }
      return BookAvailability.available;
    } on Object {
      // A transient stat/read failure is not enough evidence to label a book
      // damaged and invite deletion from the shelf.
      return BookAvailability.available;
    }
  }

  @override
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

  /// Replaces one chapter without decoding or rewriting the rest of the book.
  ///
  /// A revisioned payload is flushed before the manifest is swapped. The
  /// manifest is the commit point, so a crash can leave only an unreferenced
  /// chapter file, never a manifest that points at a half-written payload.
  @override
  Future<void> replaceChapter(Book sourceBook, Chapter replacement) async {
    if (sourceBook.isPdf ||
        sourceBook.id.isEmpty ||
        replacement.index < 0 ||
        replacement.index >= sourceBook.chapterCount ||
        replacement.title.trim().isEmpty ||
        replacement.content.trim().isEmpty) {
      throw const FormatException('章节标题和正文不能为空');
    }
    if (_deletedBookIds.contains(sourceBook.id)) {
      throw StateError('书籍不存在或已删除');
    }

    final directory = await _chapterDirectory(sourceBook.id);
    await _enqueueChapterWrite(directory.path, () async {
      if (!await directory.exists()) {
        final chapters = List<Chapter>.of(sourceBook.chapters);
        chapters[replacement.index] = replacement;
        await _writeChapterDirectory(directory, chapters);
        return;
      }

      final manifestFile = await _resolveChapterManifestFile(directory);
      if (manifestFile == null) {
        throw const FormatException('章节清单缺失或损坏');
      }
      final rawManifest = await manifestFile.readAsString(encoding: utf8);
      final manifest = await _decodeChapterManifestInBackground(rawManifest);
      final rawEntries = manifest['chapters'];
      if (manifest['version'] != 2 ||
          rawEntries is! List ||
          manifest['chapterCount'] is! num ||
          (manifest['chapterCount'] as num).toInt() != rawEntries.length ||
          rawEntries.length != sourceBook.chapterCount) {
        throw const FormatException('章节清单版本或数量不一致');
      }

      final entries = rawEntries
          .map((entry) {
            if (entry is! Map) {
              throw const FormatException('章节清单条目格式错误');
            }
            return Map<String, dynamic>.from(entry);
          })
          .toList(growable: false);
      final oldFileName = entries[replacement.index]['file'];
      if (oldFileName is! String || !_isStoredChapterFileName(oldFileName)) {
        throw const FormatException('章节清单条目格式错误');
      }

      final payload = await _encodeEditedChapter(replacement);
      final payloadBytes = utf8.encode(payload);
      final revision = DateTime.now().microsecondsSinceEpoch;
      final fileName =
          '${replacement.index.toString().padLeft(6, '0')}-$revision.json';
      final chaptersDirectory = Directory(p.join(directory.path, 'chapters'));
      if (!await chaptersDirectory.exists()) {
        throw const FormatException('章节目录不存在');
      }
      final targetFile = File(p.join(chaptersDirectory.path, fileName));
      await targetFile.writeAsString(payload, encoding: utf8, flush: true);

      entries[replacement.index] = <String, dynamic>{
        'file': fileName,
        'bytes': payloadBytes.length,
        'sha256': sha256.convert(payloadBytes).toString(),
        'title': replacement.title,
        if (replacement.volumeTitle != null)
          'volumeTitle': replacement.volumeTitle,
        'hasRichContent': replacement.hasRichEpubContent,
        'richBlockCount': replacement.epubBlockCount,
        'hasSemanticHeading': replacement.hasSemanticHeading,
      };
      final committedManifest = <String, dynamic>{
        ...manifest,
        'version': 2,
        'chapterCount': entries.length,
        'chapters': entries,
      };
      final liveManifest = File(p.join(directory.path, 'manifest.json'));
      final temporaryManifest = File('${liveManifest.path}.edit.tmp');
      final backupManifest = File('${liveManifest.path}.edit.bak');
      await temporaryManifest.writeAsString(
        jsonEncode(committedManifest),
        encoding: utf8,
        flush: true,
      );
      if (await backupManifest.exists()) await backupManifest.delete();
      if (await liveManifest.exists()) {
        await liveManifest.rename(backupManifest.path);
      } else if (manifestFile.path != liveManifest.path) {
        await manifestFile.rename(backupManifest.path);
      }
      try {
        await temporaryManifest.rename(liveManifest.path);
      } on Object {
        if (await backupManifest.exists() && !await liveManifest.exists()) {
          await backupManifest.rename(liveManifest.path);
        }
        if (await targetFile.exists()) await targetFile.delete();
        rethrow;
      }

      try {
        if (await backupManifest.exists()) await backupManifest.delete();
        final oldFile = File(p.join(chaptersDirectory.path, oldFileName));
        if (oldFile.path != targetFile.path && await oldFile.exists()) {
          await oldFile.delete();
        }
      } on FileSystemException {
        // The new manifest is authoritative. Stale private files are harmless
        // because no manifest references them.
      }
    });

    // The old statistics describe the pre-edit payload. Clear them in the
    // same public operation so a process restart between editing and recount
    // never presents stale values as authoritative.
    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final index = metadata.indexWhere((book) => book['id'] == sourceBook.id);
      if (index < 0 || _deletedBookIds.contains(sourceBook.id)) {
        throw StateError('书籍不存在或已删除');
      }
      metadata[index].remove('wordCount');
      metadata[index].remove('chapterWordCounts');
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
      await prefs.remove('$_kChapterPrefix${sourceBook.id}');
    });
  }

  Future<void> renameBook(String bookId, String title) async {
    await updateBookDetails(bookId, title: title);
  }

  @override
  Future<void> updateBookDetails(
    String bookId, {
    required String title,
    String? author,
  }) async {
    final normalizedTitle = title.trim();
    final normalizedAuthor = author?.trim();
    if (bookId.isEmpty || normalizedTitle.isEmpty) {
      throw const FormatException('书籍名称不能为空');
    }
    if (normalizedTitle.length > 120) {
      throw const FormatException('书籍名称不能超过 120 个字符');
    }
    if (normalizedAuthor != null && normalizedAuthor.length > 120) {
      throw const FormatException('作者名称不能超过 120 个字符');
    }

    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final index = metadata.indexWhere((book) => book['id'] == bookId);
      if (index < 0) throw StateError('书籍不存在或已删除');
      metadata[index]['title'] = normalizedTitle;
      if (normalizedAuthor != null) {
        metadata[index]['author'] = normalizedAuthor;
      }
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
    });
  }

  /// Persists the shelf order without rewriting chapter payloads. Unknown
  /// metadata is retained so a concurrent background update cannot make a book
  /// disappear merely because it was not present in the drag snapshot.
  @override
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
  @override
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

  @override
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
      await _readerPreferences.clearBookState(bookId);
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
      await _resources.deleteSource(removedMetadata?['sourcePath']);
    });
  }

  /// Removes files left by an import that failed before its metadata commit.
  @override
  Future<void> discardImportedBook(Book book) async {
    await deleteBook(book.id);
    await _resources.deleteSource(book.sourcePath);
  }

  /// Reclaims private payloads that are no longer referenced by shelf
  /// metadata. A grace period protects imports that wrote their files but have
  /// not committed metadata yet, as well as recoverable interrupted writes.
  @override
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

    if (await wordDirectory.exists()) {
      try {
        await for (final entity in wordDirectory.list(followLinks: false)) {
          if (entity is! Directory ||
              !_isManagedChild(wordDirectory.path, entity.absolute.path) ||
              _pathsContain(referencedWordPaths, entity.absolute.path) ||
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
    final manifestFile = await _resolveChapterManifestFile(directory);
    if (manifestFile == null) {
      throw const FormatException('章节清单不存在');
    }
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
    final expectedDigests = <String?>[];
    final titles = <String>[];
    final volumeTitles = <String?>[];
    final richContent = <bool>[];
    final richBlockCounts = <int?>[];
    final semanticHeadings = <bool?>[];
    for (final rawEntry in entries) {
      if (rawEntry is! Map) throw const FormatException('章节清单条目格式错误');
      final entry = Map<String, dynamic>.from(rawEntry);
      final fileName = entry['file'];
      final title = entry['title'];
      if (fileName is! String ||
          !_isStoredChapterFileName(fileName) ||
          title is! String ||
          title.trim().isEmpty) {
        throw const FormatException('章节清单条目格式错误');
      }
      fileNames.add(fileName);
      expectedBytes.add(
        entry['bytes'] is num ? (entry['bytes'] as num).toInt() : null,
      );
      final digest = entry['sha256'];
      expectedDigests.add(
        digest is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)
            ? digest
            : null,
      );
      titles.add(title);
      final volumeTitle = entry['volumeTitle'];
      volumeTitles.add(
        volumeTitle is String && volumeTitle.trim().isNotEmpty
            ? volumeTitle.trim()
            : null,
      );
      richContent.add(entry['hasRichContent'] == true);
      final blockCount = entry['richBlockCount'];
      richBlockCounts.add(
        blockCount is num
            ? blockCount.toInt().clamp(0, 0x7fffffff)
            : (entry['hasRichContent'] == true ? null : 0),
      );
      semanticHeadings.add(
        entry.containsKey('hasSemanticHeading')
            ? entry['hasSemanticHeading'] == true
            : null,
      );
    }
    final store = _LazyChapterStore(
      chaptersDirectoryPath: chaptersDirectory.path,
      fileNames: fileNames,
      expectedBytes: expectedBytes,
      expectedDigests: expectedDigests,
    );
    return List<Chapter>.generate(
      entries.length,
      (index) => _LazyChapter(
        index: index,
        title: titles[index],
        volumeTitle: volumeTitles[index],
        store: store,
        richContent: richContent[index],
        richBlockCount: richBlockCounts[index],
        semanticHeading: semanticHeadings[index],
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
          'bytes': utf8.encode(payloads[offset]).length,
          'sha256': sha256.convert(utf8.encode(payloads[offset])).toString(),
          'title': chapter.title,
          if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle,
          'hasRichContent': chapter.hasRichEpubContent,
          'richBlockCount': chapter.epubBlockCount,
          'hasSemanticHeading': chapter.hasSemanticHeading,
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

  @override
  Future<ReadingProgress?> getProgress(String bookId) =>
      _readerPreferences.getProgress(bookId);

  @override
  Future<void> saveProgress(ReadingProgress progress) =>
      _readerPreferences.saveProgress(progress);

  @override
  Future<PdfReadingProgress?> getPdfProgress(
    String bookId, {
    required int pageCount,
    bool migrateLegacy = true,
  }) => _readerPreferences.getPdfProgress(
    bookId,
    pageCount: pageCount,
    migrateLegacy: migrateLegacy,
  );

  @override
  Future<void> savePdfProgress(PdfReadingProgress progress) =>
      _readerPreferences.savePdfProgress(progress);

  @override
  Future<ReadingProgress?> getShelfProgress(Book book) =>
      _readerPreferences.getShelfProgress(book);

  @override
  Future<Set<int>> getPdfBookmarks(String bookId, int pageCount) =>
      _readerPreferences.getPdfBookmarks(bookId, pageCount);

  @override
  Future<void> savePdfBookmarks(String bookId, Set<int> pages, int pageCount) =>
      _readerPreferences.savePdfBookmarks(bookId, pages, pageCount);

  @override
  Future<Map<int, String>> getPdfNotes(String bookId, int pageCount) =>
      _readerPreferences.getPdfNotes(bookId, pageCount);

  @override
  Future<void> savePdfNotes(
    String bookId,
    Map<int, String> notes,
    int pageCount,
  ) => _readerPreferences.savePdfNotes(bookId, notes, pageCount);

  @override
  Future<PdfDisplayTheme> getPdfDisplayTheme(String bookId) =>
      _readerPreferences.getPdfDisplayTheme(bookId);

  @override
  Future<void> savePdfDisplayTheme(String bookId, PdfDisplayTheme theme) =>
      _readerPreferences.savePdfDisplayTheme(bookId, theme);

  @override
  Future<Set<String>> getCollapsedTocGroups(String bookId) =>
      _readerPreferences.getCollapsedTocGroups(bookId);

  @override
  Future<void> saveCollapsedTocGroups(String bookId, Set<String> groupIds) =>
      _readerPreferences.saveCollapsedTocGroups(bookId, groupIds);

  @override
  Future<ReaderSettings> getSettings() => _readerPreferences.getSettings();

  @override
  Future<void> saveSettings(ReaderSettings settings) =>
      _readerPreferences.saveSettings(settings);

  @override
  Future<File> saveImportedFont(String sourcePath, String fileName) =>
      _resources.saveImportedFont(sourcePath, fileName);

  @override
  Future<File> saveImportedPdf(String sourcePath, String bookId) =>
      _resources.saveImportedPdf(sourcePath, bookId);

  @override
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

  static Future<void> _setString(
    SharedPreferences prefs,
    String key,
    String value,
  ) async {
    final saved = await prefs.setString(key, value);
    if (!saved) throw FileSystemException('无法保存本地数据', key);
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
  } on Object {
    return false;
  }
}

Future<bool> _chapterPayloadLooksPlausible(
  File file, {
  bool verifyContents = false,
}) async {
  RandomAccessFile? input;
  try {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size < 2) return false;
    input = await file.open(mode: FileMode.read);
    final first = await input.readByte();
    await input.setPosition(stat.size - 1);
    final last = await input.readByte();
    if (first != 0x5b || last != 0x5d) return false;
    if (verifyContents) {
      final raw = await file.readAsString(encoding: utf8);
      await Isolate.run(() => _chaptersFromJson(raw));
    }
    return true;
  } on Object {
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
      .map((entry) => decodeChapterPayload(entry.$2, entry.$1))
      .toList();
}

Future<bool> _chapterDirectoryLooksPlausible(
  Directory directory, {
  bool verifyContents = false,
}) async {
  try {
    if (!await directory.exists()) return false;
    final chapters = Directory(p.join(directory.path, 'chapters'));
    if (!await chapters.exists()) return false;
    final manifest = await _resolveChapterManifestFile(directory);
    if (manifest == null) return false;
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
      if (first != 0x7b || last != 0x7d) return false;
    } finally {
      await input.close();
    }
    final rawManifest = await manifest.readAsString(encoding: utf8);
    final parsed = _chapterManifestFromJson(rawManifest);
    final entries = parsed['chapters'];
    final chapterCount = parsed['chapterCount'];
    if (parsed['version'] != 2 ||
        entries is! List ||
        entries.isEmpty ||
        chapterCount is! num ||
        chapterCount.toInt() != entries.length) {
      return false;
    }
    for (var index = 0; index < entries.length; index++) {
      final rawEntry = entries[index];
      if (rawEntry is! Map) return false;
      final entry = Map<String, dynamic>.from(rawEntry);
      final fileName = entry['file'];
      final expectedBytes = entry['bytes'];
      if (fileName is! String ||
          !_isStoredChapterFileName(fileName) ||
          expectedBytes is! num ||
          expectedBytes.toInt() < 2) {
        return false;
      }
      final chapterFile = File(p.join(chapters.path, fileName));
      final chapterStat = await chapterFile.stat();
      if (chapterStat.type != FileSystemEntityType.file ||
          chapterStat.size != expectedBytes.toInt()) {
        return false;
      }
      if (!verifyContents) continue;
      final raw = await chapterFile.readAsString(encoding: utf8);
      final expectedDigest = entry['sha256'];
      if (expectedDigest is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedDigest)) {
        if (sha256.convert(utf8.encode(raw)).toString() != expectedDigest) {
          return false;
        }
      } else {
        await Isolate.run(() => decodeChapterPayload(jsonDecode(raw), index));
      }
    }
    return true;
  } on Object {
    return false;
  }
}

bool _isStoredChapterFileName(String value) =>
    RegExp(r'^\d{6,}(?:-[A-Za-z0-9_-]+)?\.json$').hasMatch(value);

/// Recovers the tiny manifest swap used by chapter editing.
///
/// The chapter payload is written first, therefore a staged manifest is safe
/// to promote. If staging never completed, the previous manifest remains the
/// fallback. Returning a candidate even when rename is unavailable keeps the
/// book readable on restrictive filesystems.
Future<File?> _resolveChapterManifestFile(Directory directory) async {
  final live = File(p.join(directory.path, 'manifest.json'));
  if (await live.exists()) return live;
  final staged = File('${live.path}.edit.tmp');
  final backup = File('${live.path}.edit.bak');
  // Prefer the last known committed manifest. A background shelf scan can
  // enter this recovery path during the tiny rename window of an active edit;
  // promoting the staged manifest there would race the writer's commit.
  for (final candidate in <File>[backup, staged]) {
    if (!await candidate.exists()) continue;
    try {
      return await candidate.rename(live.path);
    } on FileSystemException {
      return candidate;
    }
  }
  return null;
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
    .map((chapter) => jsonEncode(encodeChapterPayload(chapter)))
    .toList(growable: false);

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

// Worker closures capture only their explicit input, not the write-queue owner.
Future<Map<String, dynamic>> _decodeChapterManifestInBackground(String raw) =>
    Isolate.run(() => _chapterManifestFromJson(raw));

Future<String> _encodeEditedChapter(Chapter chapter) =>
    Isolate.run(() => jsonEncode(encodeChapterPayload(chapter)));
