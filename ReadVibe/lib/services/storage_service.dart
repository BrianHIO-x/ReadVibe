import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import 'txt_parser.dart';

const _kBooksKey = 'readvibe_books';
const _kSettingsKey = 'readvibe_settings';
const _kProgressPrefix = 'readvibe_progress_';
const _kTocCollapsedPrefix = 'readvibe_toc_collapsed_';
const _kChapterPrefix = 'readvibe_chapters_';
// Large novels can exceed 10 MB. A two-second deadline was too aggressive on
// slower phones and could make a valid saved book appear unreadable.
const _kChapterIoTimeout = Duration(seconds: 30);
const _kLegacyMigrationTimeout = Duration(milliseconds: 250);

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

  Future<void> saveBook(Book book) async {
    if (book.chapters.isEmpty) {
      throw const FormatException('书籍没有可保存的章节');
    }

    await _enqueueLibraryMutation(() async {
      // Save the large payload first. The shelf metadata is only committed
      // after the chapter file is safely in place.
      await _saveChapters(book.id, book.chapters);
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

  Future<void> saveBookWordCount(String bookId, int wordCount) async {
    if (bookId.isEmpty || wordCount < 0) return;
    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs);
      final index = metadata.indexWhere((book) => book['id'] == bookId);
      // A background count may finish after the user deletes the book. Never
      // recreate deleted metadata just to save a stale result.
      if (index < 0) return;
      metadata[index]['wordCount'] = wordCount.clamp(0, 0x7fffffffffffffff);
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
    });
  }

  Future<void> saveChapterWordCounts(
    Book sourceBook,
    List<int> chapterWordCounts,
  ) async {
    if (sourceBook.id.isEmpty ||
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
      final currentFileSize = current['fileSize'];
      final currentParserVersion = current['txtParserVersion'];
      final currentChapterCount = current['chapterCount'];
      // Do not let a count from an older parse overwrite a newly re-imported
      // or migrated directory that happens to reuse the same book ID.
      if (currentFileSize is! num ||
          currentFileSize.toInt() != sourceBook.fileSize ||
          currentParserVersion is! num ||
          currentParserVersion.toInt() != sourceBook.txtParserVersion ||
          currentChapterCount is! num ||
          currentChapterCount.toInt() != sourceBook.chapterCount) {
        return;
      }
      current['chapterWordCounts'] = safeCounts;
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
    });
  }

  Future<void> deleteBook(String bookId) async {
    await _enqueueLibraryMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final metadata = _readBookMetadata(prefs)
        ..removeWhere((book) => book['id'] == bookId);
      await _setString(prefs, _kBooksKey, jsonEncode(metadata));
      final progressKey = '$_kProgressPrefix$bookId';
      final tocCollapsedKey = '$_kTocCollapsedPrefix$bookId';
      _invalidatePreferenceWrite(progressKey);
      _invalidatePreferenceWrite(tocCollapsedKey);
      await prefs.remove(progressKey);
      await prefs.remove(tocCollapsedKey);
      await prefs.remove('$_kChapterPrefix$bookId');

      final file = await _chapterFile(bookId);
      for (final candidate in [
        file,
        File('${file.path}.tmp'),
        File('${file.path}.bak'),
      ]) {
        try {
          if (await candidate.exists()) await candidate.delete();
        } on FileSystemException {
          // Metadata has already been removed. A stale private payload is less
          // harmful than making the deleted book reappear or crashing the UI.
        }
      }
    });
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
        return chapters;
      } on Object {
        // Try the temporary/backup copy left by an interrupted atomic write.
      }
    }

    return [];
  }

  Future<void> _saveChapters(String bookId, List<Chapter> chapters) async {
    final file = await _chapterFile(bookId);
    return _enqueueChapterWrite(file.path, () async {
      await _writeChapters(file, chapters);
    });
  }

  Future<void> _writeChapters(File file, List<Chapter> chapters) async {
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    // JSON encoding briefly allocates another string about as large as the
    // novel. Keep that CPU and allocation pressure off the UI isolate.
    final payload = await Isolate.run(() => _chaptersToJson(chapters));

    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsString(payload, encoding: utf8, flush: true);

    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    }
    try {
      await temporary.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (await backup.exists() && !await file.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }

  Future<ReadingProgress?> getProgress(String bookId) async {
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
    if (progress.bookId.isEmpty) return;
    await _setLatestString(
      '$_kProgressPrefix${progress.bookId}',
      jsonEncode(progress.toJson()),
    );
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
    if (bookId.isEmpty) return;
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

    final currentImportedFontPath = settings.importedFontPath;
    if (previousImportedFontPath != null &&
        previousImportedFontPath != currentImportedFontPath) {
      await _deleteManagedFont(previousImportedFontPath);
    }
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
    final safeId = base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');
    return File(p.join(directory.path, '$safeId.json'));
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

  static Future<void> _setLatestString(String key, String value) async {
    final version = ++_nextPreferenceWriteVersion;
    _preferenceWriteVersions[key] = version;
    final prefs = await SharedPreferences.getInstance();
    if (_preferenceWriteVersions[key] != version) return;
    await _setString(prefs, key, value);
  }

  static void _invalidatePreferenceWrite(String key) {
    _preferenceWriteVersions[key] = ++_nextPreferenceWriteVersion;
  }
}

List<Chapter> _chaptersFromJson(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List || decoded.isEmpty) {
    throw const FormatException('章节数据为空或格式错误');
  }
  return decoded.indexed.map((entry) {
    final (index, value) = entry;
    final map = Map<String, dynamic>.from(value as Map);
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
    return Chapter(
      index: index,
      title: title,
      content: content,
      volumeTitle: volumeTitle,
    );
  }).toList();
}

String _chaptersToJson(List<Chapter> chapters) {
  return jsonEncode(
    chapters
        .map(
          (chapter) => {
            'index': chapter.index,
            'title': chapter.title,
            'content': chapter.content,
            if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle,
          },
        )
        .toList(),
  );
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
