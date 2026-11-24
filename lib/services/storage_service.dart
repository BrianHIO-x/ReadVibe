import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/book_content_revision.dart';
import '../models/reader_bookmark.dart';
import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';
import 'book_id.dart';
import 'managed_book_resources.dart';
import 'reader_preferences_store.dart';
import 'storage/chapter_disk_store.dart';
import 'storage/storage_usage_service.dart';
import 'txt_parser.dart';

export '../repositories/reader_repositories.dart' show StorageCleanupResult;

const _kBooksKey = 'readvibe_books';
const _kLibraryFileName = 'library.json';

/// Persists small preferences in SharedPreferences and book content in files.
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

  static final Map<String, List<Map<String, dynamic>>> _libraryCache =
      <String, List<Map<String, dynamic>>>{};

  static Future<void> _libraryMutationQueue = Future<void>.value();
  static final Map<String, Future<void>> _chapterWriteQueues =
      <String, Future<void>>{};
  static final Set<String> _deletedBookIds = <String>{};

  late final ReaderPreferencesStore _readerPreferences = ReaderPreferencesStore(
    _deletedBookIds.contains,
    _resources.deleteFont,
  );
  late final ChapterDiskStore _chapterStore = ChapterDiskStore(
    getAppDataDirectory,
    _enqueueLibraryMutation,
    _enqueueChapterWrite,
    _deletedBookIds.contains,
  );
  late final StorageUsageService _usageService = StorageUsageService(
    getAppDataDirectory,
    _readBookMetadata,
    _readBookMetadataForCleanup,
    _chapterStore.chapterDirectory,
    _enqueueLibraryMutation,
    _enqueueChapterWrite,
  );

  Future<List<Book>> getBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final metadata = await _readBookMetadata();
    final books = <Book>[];

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
            final chapters = await _chapterStore.loadChapters(id, prefs);
            if (chapters.isEmpty) return null;
            return upgradeLegacyTxtBook(_bookWithStoredChapters(map, chapters));
          } on Object {
            return null;
          }
        }),
      );
      books.addAll(batch.whereType<Book>());
    }
    return books;
  }

  @override
  Future<List<Book>> getBookSummaries() async {
    final summaries = <Book>[];
    for (final map in await _readBookMetadata()) {
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
    final metadata = (await _readBookMetadata()).where(
      (map) => map['id'] == bookId,
    );
    if (metadata.isEmpty) return null;
    try {
      if (metadata.first['format'] == BookFormat.pdf.name) {
        final pdfBook = Book.fromJson(metadata.first, const <Chapter>[]);
        final sourcePath = pdfBook.sourcePath;
        if (sourcePath == null || !await File(sourcePath).exists()) return null;
        return pdfBook;
      }
      final chapters = await _chapterStore.loadChapters(bookId, prefs);
      if (chapters.isEmpty) return null;
      final storedBook = _bookWithStoredChapters(metadata.first, chapters);
      var readableBook = upgradeLegacyTxtBook(storedBook);
      if (!identical(readableBook, storedBook)) {
        try {
          final storedProgress = await getProgress(bookId);
          final remappedProgress = storedProgress == null
              ? null
              : _remapProgressAfterReparse(
                  storedProgress,
                  storedBook.chapters,
                  readableBook.chapters,
                );
          await saveBook(readableBook);
          final committedChapters = await _chapterStore.loadChapterDirectory(
            await _chapterStore.chapterDirectory(bookId),
          );
          readableBook = _bookWithStoredChapters(
            readableBook.toJson(),
            committedChapters,
          );
          if (remappedProgress != null) {
            await saveProgress(remappedProgress);
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
      if (!await _chapterStore.hasReadableBookPayload(book, prefs, deep: deep)) {
        return BookAvailability.payloadMissing;
      }

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
      return BookAvailability.available;
    }
  }

  @override
  Future<Book> saveBook(
    Book book, {
    ChapterWriteProgress? onChapterProgress,
  }) async {
    if (book.isPdf &&
        (book.sourcePath == null ||
            book.pageCount == null ||
            book.pageCount! <= 0)) {
      throw const FormatException('PDF 文件路径或页数无效');
    }
    if (!book.isPdf && book.chapters.isEmpty) {
      throw const FormatException('书籍没有可保存的章节');
    }

    late Book committed;
    await _enqueueLibraryMutation(() async {
      onChapterProgress?.call(0, book.chapterCount);
      final metadata = await _readBookMetadata();
      final existingIndex = metadata.indexWhere(
        (item) => item['id'] == book.id,
      );
      final revision = existingIndex < 0
          ? book.contentRevision
          : math.max(
              book.contentRevision,
              readContentRevision(metadata[existingIndex]['contentRevision']) +
                  1,
            );
      final isPrivate = existingIndex >= 0
          ? metadata[existingIndex]['private'] == true
          : book.isPrivate;
      final groups = existingIndex >= 0
          ? _readGroupsFromRecord(metadata[existingIndex])
          : book.groups;
      final displayTitle = existingIndex >= 0
          ? book.title
          : uniqueLibraryTitle(book.title, <String>{
              for (final item in metadata)
                if (item['title'] is String &&
                    (item['private'] == true) == isPrivate)
                  item['title'] as String,
            });
      final committedBook = book.copyWith(
        contentRevision: revision,
        title: displayTitle == book.title ? null : displayTitle,
        isPrivate: isPrivate,
        groups: groups,
      );
      if (!book.isPdf) {
        await _chapterStore.saveChapters(
          book.id,
          book.chapters,
          contentRevision: revision,
          onProgress: onChapterProgress,
        );
      }
      if (existingIndex >= 0) {
        metadata[existingIndex] = committedBook.toJson();
      } else {
        metadata.insert(0, committedBook.toJson());
      }
      await _writeBookMetadata(metadata);
      if (groups.isNotEmpty) {
        await _syncShelfGroupCatalog(groups, private: isPrivate);
      }
      _deletedBookIds.remove(book.id);
      committed = committedBook;
    });
    return committed;
  }

  @override
  Future<Book> replaceChapter(Book sourceBook, Chapter replacement) async {
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

    return _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = await _readBookMetadata();
      final index = metadata.indexWhere((book) => book['id'] == sourceBook.id);
      if (index < 0 || _deletedBookIds.contains(sourceBook.id)) {
        throw StateError('书籍不存在或已删除');
      }
      final directory = await _chapterStore.chapterDirectory(sourceBook.id);
      final storedRevision =
          await _chapterStore.readStoredContentRevision(sourceBook.id) ??
          readContentRevision(metadata[index]['contentRevision']);
      if (!_matchesBookRevision({
        ...metadata[index],
        'contentRevision': storedRevision,
      }, sourceBook)) {
        throw BookEditConflict();
      }
      final nextRevision = storedRevision + 1;
      metadata[index].remove('wordCount');
      metadata[index].remove('chapterWordCounts');
      await _writeBookMetadata(metadata);
      await _chapterStore.replaceSingleChapter(
        directory: directory,
        sourceBook: sourceBook,
        replacement: replacement,
        nextRevision: nextRevision,
      );
      final chapters = List<Chapter>.of(sourceBook.chapters);
      chapters[replacement.index] = replacement;
      final committedBook = Book.fromJson(metadata[index], chapters).copyWith(
        contentRevision: nextRevision,
        chapters: List<Chapter>.unmodifiable(chapters),
        clearWordCounts: true,
      );
      metadata[index]['contentRevision'] = nextRevision;
      try {
        await _writeBookMetadata(metadata);
        await prefs.remove('$kLegacyChapterPrefPrefix${sourceBook.id}');
      } on Object {
        // The manifest already committed. Reopening reconciles its revision.
      }
      return committedBook;
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
      final metadata = await _readBookMetadata();
      final index = metadata.indexWhere((book) => book['id'] == bookId);
      if (index < 0) throw StateError('书籍不存在或已删除');
      metadata[index]['title'] = normalizedTitle;
      if (normalizedAuthor != null) {
        metadata[index]['author'] = normalizedAuthor;
      }
      await _writeBookMetadata(metadata);
    });
  }

  @override
  Future<void> saveBookOrder(List<String> bookIds) async {
    final seen = <String>{};
    final requested = bookIds
        .where((id) => id.isNotEmpty && seen.add(id))
        .toList(growable: false);
    if (requested.isEmpty) return;

    await _enqueueLibraryMutation(() async {
      final metadata = await _readBookMetadata();
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
      await _writeBookMetadata(reordered);
    });
  }

  @override
  Future<void> setBooksPrivate(
    Iterable<String> bookIds, {
    required bool private,
  }) async {
    final ids = bookIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    await _enqueueLibraryMutation(() async {
      final metadata = await _readBookMetadata();
      var changed = false;
      final movedGroups = <String>[];
      for (final book in metadata) {
        if (!ids.contains(book['id'])) continue;
        final groups = _readGroupsFromRecord(book);
        if (private) {
          final moved = book['private'] != true;
          changed |= moved;
          book['private'] = true;
          if (moved && groups.isNotEmpty) movedGroups.addAll(groups);
        } else {
          final moved = book.remove('private') != null;
          changed |= moved;
          if (moved && groups.isNotEmpty) movedGroups.addAll(groups);
        }
      }
      if (changed) {
        await _writeBookMetadata(metadata);
        if (movedGroups.isNotEmpty) {
          await _syncShelfGroupCatalog(movedGroups, private: private);
        }
      }
    });
  }

  @override
  Future<void> setBooksGroups(
    Iterable<String> bookIds,
    Iterable<String> groups,
  ) async {
    final ids = bookIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final normalized = normalizeBookGroups(groups);
    await _enqueueLibraryMutation(() async {
      final metadata = await _readBookMetadata();
      var changed = false;
      var updatedNormal = false;
      var updatedPrivate = false;
      for (final book in metadata) {
        if (!ids.contains(book['id'])) continue;
        final current = _readGroupsFromRecord(book);
        if (!_listEquals(current, normalized)) {
          changed = true;
          if (normalized.isEmpty) {
            book.remove('groups');
          } else {
            book['groups'] = normalized;
          }
        }
        if (book['private'] == true) {
          updatedPrivate = true;
        } else {
          updatedNormal = true;
        }
      }
      if (changed) await _writeBookMetadata(metadata);
      if (normalized.isNotEmpty) {
        if (updatedNormal) {
          await _syncShelfGroupCatalog(normalized, private: false);
        }
        if (updatedPrivate) {
          await _syncShelfGroupCatalog(normalized, private: true);
        }
      }
    });
  }

  @override
  Future<void> updateBooksGroups(
    Iterable<String> bookIds, {
    Iterable<String> add = const <String>[],
    Iterable<String> remove = const <String>[],
  }) async {
    final ids = bookIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final toAdd = normalizeBookGroups(add, maxGroups: 64);
    final toRemove = normalizeBookGroups(remove, maxGroups: 64).toSet();
    if (toAdd.isEmpty && toRemove.isEmpty) return;
    await _enqueueLibraryMutation(() async {
      final metadata = await _readBookMetadata();
      var changed = false;
      final normalAdded = <String>[];
      final privateAdded = <String>[];
      for (final book in metadata) {
        if (!ids.contains(book['id'])) continue;
        final existing = _readGroupsFromRecord(book);
        final next = normalizeBookGroups(<String>[
          for (final g in existing)
            if (!toRemove.contains(g)) g,
          ...toAdd,
        ]);
        if (!_listEquals(existing, next)) {
          changed = true;
          if (next.isEmpty) {
            book.remove('groups');
          } else {
            book['groups'] = next;
          }
          if (toAdd.isNotEmpty) {
            final addedToBook = next.where(toAdd.contains);
            if (book['private'] == true) {
              privateAdded.addAll(addedToBook);
            } else {
              normalAdded.addAll(addedToBook);
            }
          }
        }
      }
      if (changed) await _writeBookMetadata(metadata);
      if (normalAdded.isNotEmpty) {
        await _syncShelfGroupCatalog(normalAdded, private: false);
      }
      if (privateAdded.isNotEmpty) {
        await _syncShelfGroupCatalog(privateAdded, private: true);
      }
    });
  }

  @override
  Future<List<String>> getShelfGroups({required bool private}) async {
    final saved = await _readerPreferences.getShelfGroups(private: private);
    final metadata = await _readBookMetadata();
    final discovered = <String>[];
    for (final book in metadata) {
      if ((book['private'] == true) != private) continue;
      discovered.addAll(_readGroupsFromRecord(book));
    }
    return normalizeBookGroups(<String>[...saved, ...discovered], maxGroups: 64);
  }

  @override
  Future<void> saveShelfGroups(
    Iterable<String> groups, {
    required bool private,
  }) => _enqueueLibraryMutation(
    () => _readerPreferences.saveShelfGroups(groups, private: private),
  );

  @override
  Future<void> renameShelfGroup({
    required String oldName,
    required String newName,
    required bool private,
  }) async {
    final normalizedOld = normalizeBookGroups(<String>[oldName], maxGroups: 1);
    final normalizedNew = normalizeBookGroups(<String>[newName], maxGroups: 1);
    if (normalizedOld.isEmpty || normalizedNew.isEmpty) {
      throw const FormatException('分组名称不能为空');
    }
    final oldGroup = normalizedOld.first;
    final newGroup = normalizedNew.first;
    if (oldGroup == newGroup) return;

    await _enqueueLibraryMutation(() async {
      final metadata = await _readBookMetadata();
      var metadataChanged = false;
      for (final book in metadata) {
        if ((book['private'] == true) != private) continue;
        final existing = _readGroupsFromRecord(book);
        if (!existing.contains(oldGroup)) continue;
        final updated = normalizeBookGroups(<String>[
          for (final g in existing) g == oldGroup ? newGroup : g,
        ]);
        book['groups'] = updated;
        metadataChanged = true;
      }
      if (metadataChanged) await _writeBookMetadata(metadata);

      final saved = await _readerPreferences.getShelfGroups(private: private);
      final updatedCatalog = <String>[
        for (final g in saved) g == oldGroup ? newGroup : g,
        if (!saved.contains(oldGroup) && !saved.contains(newGroup)) newGroup,
      ];
      await _readerPreferences.saveShelfGroups(updatedCatalog, private: private);
    });
  }

  @override
  Future<void> deleteShelfGroup(
    String name, {
    required bool private,
  }) async {
    final target = normalizeBookGroups(<String>[name], maxGroups: 1).firstOrNull;
    if (target == null) return;
    await _enqueueLibraryMutation(() async {
      final metadata = await _readBookMetadata();
      var metadataChanged = false;
      for (final book in metadata) {
        if ((book['private'] == true) != private) continue;
        final existing = _readGroupsFromRecord(book);
        if (!existing.contains(target)) continue;
        final remaining = existing.where((g) => g != target).toList();
        if (remaining.isEmpty) {
          book.remove('groups');
        } else {
          book['groups'] = remaining;
        }
        metadataChanged = true;
      }
      if (metadataChanged) await _writeBookMetadata(metadata);

      final saved = await _readerPreferences.getShelfGroups(private: private);
      await _readerPreferences.saveShelfGroups(
        saved.where((g) => g != target),
        private: private,
      );
    });
  }

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
      final metadata = await _readBookMetadata();
      final index = metadata.indexWhere((book) => book['id'] == sourceBook.id);
      if (index < 0) return;

      final current = metadata[index];
      final revision =
          await _chapterStore.readStoredContentRevision(sourceBook.id) ??
          readContentRevision(current['contentRevision']);
      if (_deletedBookIds.contains(sourceBook.id) ||
          !_matchesBookRevision({
            ...current,
            'contentRevision': revision,
          }, sourceBook)) {
        return;
      }
      current['contentRevision'] = revision;
      current['chapterWordCounts'] = safeCounts;
      var total = 0;
      for (final count in safeCounts) {
        total = (total + count).clamp(0, 0x7fffffffffffffff);
      }
      current['wordCount'] = total;
      await _writeBookMetadata(metadata);
    });
  }

  @override
  Future<void> deleteBook(String bookId) => deleteBooks(<String>[bookId]);

  @override
  Future<void> deleteBooks(Iterable<String> bookIds) async {
    final ids = bookIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    _deletedBookIds.addAll(ids);
    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = await _readBookMetadata();
      final removedRecords = <Map<String, dynamic>>[
        for (final book in metadata)
          if (ids.contains(book['id'])) book,
      ];
      metadata.removeWhere((book) => ids.contains(book['id']));
      await _writeBookMetadata(metadata);
      for (final id in ids) {
        await _readerPreferences.clearBookState(id);
        await prefs.remove('$kLegacyChapterPrefPrefix$id');
        await _chapterStore.deleteBookPayloads(id);
      }
      for (final removed in removedRecords) {
        await _resources.deleteSource(removed['sourcePath']);
      }
    });
  }

  @override
  Future<void> discardImportedBook(Book book) async {
    await deleteBook(book.id);
    await _resources.deleteSource(book.sourcePath);
  }

  Future<List<Map<String, dynamic>>> getAllBookMetadataRecords() =>
      _readBookMetadata();

  Future<void> upsertRestoredBookRecord(Map<String, dynamic> record) async {
    final id = record['id'];
    if (id is! String || id.isEmpty) return;
    await _enqueueLibraryMutation(() async {
      final metadata = await _readBookMetadata();
      final copy = Map<String, dynamic>.from(record);
      final existingIndex = metadata.indexWhere((item) => item['id'] == id);
      if (existingIndex >= 0) {
        metadata[existingIndex] = copy;
      } else {
        metadata.add(copy);
      }
      await _writeBookMetadata(metadata);
      _deletedBookIds.remove(id);
    });
  }

  void clearDeletedBookMarker(String bookId) {
    if (bookId.isNotEmpty) _deletedBookIds.remove(bookId);
  }

  Future<Directory> chapterDirectory(String bookId) =>
      _chapterStore.chapterDirectory(bookId);

  @override
  Future<StorageUsageReport> measureStorageUsage() =>
      _usageService.measureStorageUsage();

  @override
  Future<int> clearTemporaryCaches() => _usageService.clearTemporaryCaches();

  @override
  Future<StorageCleanupResult> collectOrphanedData({
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? referenceTime,
  }) => _usageService.collectOrphanedData(
    gracePeriod: gracePeriod,
    referenceTime: referenceTime,
  );

  @visibleForTesting
  static void resetLibraryCache() => _libraryCache.clear();

  Future<void> _syncShelfGroupCatalog(
    Iterable<String> additions, {
    required bool private,
  }) async {
    final existing = await _readerPreferences.getShelfGroups(private: private);
    final merged = normalizeBookGroups(<String>[
      ...existing,
      ...additions,
    ], maxGroups: 64);
    if (!_listEquals(existing, merged)) {
      await _readerPreferences.saveShelfGroups(merged, private: private);
    }
  }

  Future<File> _libraryFile() async =>
      File(p.join((await getAppDataDirectory()).path, _kLibraryFileName));

  Future<List<Object?>?> _readLibraryRecords() async {
    final live = await _libraryFile();
    final backup = File('${live.path}.bak');
    for (final candidate in <File>[live, backup]) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = jsonDecode(
          await candidate.readAsString(encoding: utf8),
        );
        if (decoded is List) return decoded;
        return null;
      } on Object {
        // Fall through to the backup, then to the legacy preference key.
      }
    }
    if (await live.exists() || await backup.exists()) return null;
    return _adoptLegacyLibraryRecords();
  }

  Future<List<Object?>?> _adoptLegacyLibraryRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kBooksKey);
    if (raw == null) return const <Object?>[];
    List<Object?> records;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      records = decoded;
    } on Object {
      return null;
    }
    try {
      await _writeLibraryFile(raw);
      await prefs.remove(_kBooksKey);
    } on Object {
      // Keep serving the legacy value; the next read retries the migration.
    }
    return records;
  }

  Future<void> _writeLibraryFile(String encoded) async {
    final live = await _libraryFile();
    final temporary = File('${live.path}.tmp');
    final backup = File('${live.path}.bak');
    await live.parent.create(recursive: true);
    await temporary.writeAsString(encoded, encoding: utf8, flush: true);
    if (await live.exists()) {
      if (await backup.exists()) await backup.delete();
      await live.rename(backup.path);
    }
    try {
      await temporary.rename(live.path);
    } on Object {
      if (await backup.exists() && !await live.exists()) {
        await backup.rename(live.path);
      }
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  }

  Future<List<Map<String, dynamic>>> _readBookMetadata() async {
    final root = (await getAppDataDirectory()).path;
    final cached = _libraryCache[root];
    if (cached != null) return _copyMetadata(cached);
    final records = await _readLibraryRecords();
    if (records == null) return <Map<String, dynamic>>[];
    final metadata = records
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .where((map) => map['id'] is String && (map['id'] as String).isNotEmpty)
        .toList();
    _libraryCache[root] = _copyMetadata(metadata);
    return metadata;
  }

  Future<void> _writeBookMetadata(List<Map<String, dynamic>> metadata) async {
    await _writeLibraryFile(jsonEncode(metadata));
    _libraryCache[(await getAppDataDirectory()).path] = _copyMetadata(metadata);
  }

  static List<Map<String, dynamic>> _copyMetadata(
    List<Map<String, dynamic>> source,
  ) => <Map<String, dynamic>>[
    for (final record in source) Map<String, dynamic>.from(record),
  ];

  Future<List<Map<String, dynamic>>?> _readBookMetadataForCleanup() async {
    try {
      final decoded = await _readLibraryRecords();
      if (decoded == null) return null;
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
  Future<List<ReaderBookmark>> getBookmarks(String bookId) =>
      _readerPreferences.getBookmarks(bookId);

  @override
  Future<void> saveBookmarks(String bookId, List<ReaderBookmark> bookmarks) =>
      _readerPreferences.saveBookmarks(bookId, bookmarks);

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

  static Future<T> _enqueueLibraryMutation<T>(Future<T> Function() action) {
    final operation = _libraryMutationQueue.then((_) => action());
    _libraryMutationQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<T> _enqueueChapterWrite<T>(
    String path,
    Future<T> Function() action,
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
}

List<String> _readGroupsFromRecord(Map<String, dynamic> record) {
  final raw = record['groups'];
  if (raw is! Iterable) return const <String>[];
  return normalizeBookGroups(raw.cast<Object?>());
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
      currentFormat == sourceBook.format.name &&
      readContentRevision(metadata['contentRevision']) ==
          sourceBook.contentRevision &&
      metadata['importDate'] == sourceBook.importDate.toIso8601String();
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

Book _bookWithStoredChapters(
  Map<String, dynamic> metadata,
  List<Chapter> chapters,
) {
  final book = Book.fromJson(metadata, chapters);
  final revision = chapterContentRevision(chapters) ?? book.contentRevision;
  return book.copyWith(
    contentRevision: revision,
    clearWordCounts: revision != book.contentRevision,
  );
}
