import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/reader_bookmark.dart';
import '../models/reader_note.dart';
import '../models/reader_settings.dart';

const _settingsKey = 'readvibe_settings';
const _progressPrefix = 'readvibe_progress_';
const _pdfProgressPrefix = 'readvibe_pdf_progress_';
const _pdfBookmarksPrefix = 'readvibe_pdf_bookmarks_';
const _pdfNotesPrefix = 'readvibe_pdf_notes_';
const _pdfDisplayThemePrefix = 'readvibe_pdf_display_theme_';
const _tocCollapsedPrefix = 'readvibe_toc_collapsed_';
const _bookmarksPrefix = 'readvibe_bookmarks_';
const _notesPrefix = 'readvibe_notes_';
const _notesMigratedPrefix = 'readvibe_notes_migrated_';
const _shelfGroupsKey = 'readvibe_shelf_groups';
const _privateShelfGroupsKey = 'readvibe_private_shelf_groups';

/// Owns the small reader-state records stored in SharedPreferences.
///
/// This store deliberately excludes shelf metadata and chapter payloads. Its
/// keyed queues guarantee that an older save cannot overtake a newer save or
/// recreate state after the owning book has been deleted.
class ReaderPreferencesStore {
  ReaderPreferencesStore(this._isBookDeleted, this._deleteManagedFont);

  final bool Function(String bookId) _isBookDeleted;
  final Future<void> Function(String path) _deleteManagedFont;

  static final Map<String, int> _writeVersions = <String, int>{};
  static final Map<String, Future<void>> _writeQueues =
      <String, Future<void>>{};
  static int _nextWriteVersion = 0;

  Future<ReadingProgress?> getProgress(String bookId) async {
    if (_isBookDeleted(bookId)) return null;
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_progressPrefix$bookId',
    );
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
    if (progress.bookId.isEmpty || _isBookDeleted(progress.bookId)) return;
    await _setLatestString(
      '$_progressPrefix${progress.bookId}',
      jsonEncode(progress.toJson()),
    );
  }

  Future<PdfReadingProgress?> getPdfProgress(
    String bookId, {
    required int pageCount,
    bool migrateLegacy = true,
  }) async {
    if (bookId.isEmpty || _isBookDeleted(bookId) || pageCount <= 0) {
      return null;
    }
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_pdfProgressPrefix$bookId',
    );
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
        // Fall through to one-time legacy progress migration.
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
        _isBookDeleted(progress.bookId)) {
      return;
    }
    final safe = PdfReadingProgress(
      bookId: progress.bookId,
      pageIndex: progress.pageIndex.clamp(0, progress.pageCount - 1),
      pageCount: progress.pageCount,
      lastReadDate: progress.lastReadDate,
    );
    await _setLatestString(
      '$_pdfProgressPrefix${progress.bookId}',
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
    if (bookId.isEmpty || pageCount <= 0 || _isBookDeleted(bookId)) {
      return <int>{};
    }
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_pdfBookmarksPrefix$bookId',
    );
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
    if (bookId.isEmpty || pageCount <= 0 || _isBookDeleted(bookId)) return;
    final safePages =
        pages.where((page) => page >= 0 && page < pageCount).take(2000).toList()
          ..sort();
    await _setLatestString(
      '$_pdfBookmarksPrefix$bookId',
      jsonEncode(safePages),
    );
  }

  Future<Map<int, String>> getPdfNotes(String bookId, int pageCount) async {
    if (bookId.isEmpty || pageCount <= 0 || _isBookDeleted(bookId)) {
      return <int, String>{};
    }
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_pdfNotesPrefix$bookId',
    );
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
        final normalized = note.trim();
        notes[page] = normalized.substring(
          0,
          math.min(4000, normalized.length),
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
    if (bookId.isEmpty || pageCount <= 0 || _isBookDeleted(bookId)) return;
    final safe = <String, String>{};
    for (final entry in notes.entries.take(2000)) {
      final note = entry.value.trim();
      if (entry.key < 0 || entry.key >= pageCount || note.isEmpty) continue;
      safe[entry.key.toString()] = note.substring(
        0,
        math.min(4000, note.length),
      );
    }
    await _setLatestString('$_pdfNotesPrefix$bookId', jsonEncode(safe));
  }

  Future<PdfDisplayTheme> getPdfDisplayTheme(String bookId) async {
    if (bookId.isEmpty || _isBookDeleted(bookId)) {
      return PdfDisplayTheme.original;
    }
    final stored = (await SharedPreferences.getInstance()).getString(
      '$_pdfDisplayThemePrefix$bookId',
    );
    return PdfDisplayTheme.values.firstWhere(
      (theme) => theme.name == stored,
      orElse: () => PdfDisplayTheme.original,
    );
  }

  Future<void> savePdfDisplayTheme(String bookId, PdfDisplayTheme theme) async {
    if (bookId.isEmpty || _isBookDeleted(bookId)) return;
    await _setLatestString('$_pdfDisplayThemePrefix$bookId', theme.name);
  }

  Future<List<ReaderBookmark>> getBookmarks(String bookId) async {
    if (bookId.isEmpty || _isBookDeleted(bookId)) return const <ReaderBookmark>[];
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_bookmarksPrefix$bookId',
    );
    if (raw == null) return const <ReaderBookmark>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ReaderBookmark>[];
      final marks = <ReaderBookmark>[];
      final seenIds = <String>{};
      for (final entry in decoded.take(maxReaderBookmarksPerBook)) {
        final mark = ReaderBookmark.fromJson(entry);
        if (mark == null || !seenIds.add(mark.id)) continue;
        marks.add(mark);
      }
      return sortedReaderBookmarks(marks);
    } on Object {
      return const <ReaderBookmark>[];
    }
  }

  Future<void> saveBookmarks(
    String bookId,
    List<ReaderBookmark> bookmarks,
  ) async {
    if (bookId.isEmpty || _isBookDeleted(bookId)) return;
    // Keep the newest marks when a book runs past the cap, then store them in
    // reading order so a later read needs no second sort.
    final capped = bookmarks.length <= maxReaderBookmarksPerBook
        ? bookmarks
        : (bookmarks.toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
              .take(maxReaderBookmarksPerBook)
              .toList();
    await _setLatestString(
      '$_bookmarksPrefix$bookId',
      jsonEncode([
        for (final mark in sortedReaderBookmarks(capped)) mark.toJson(),
      ]),
    );
  }

  Future<List<ReaderNote>> getNotes(
    String bookId, {
    bool isPdf = false,
    int? pdfPageCount,
  }) async {
    if (bookId.isEmpty || _isBookDeleted(bookId)) return const <ReaderNote>[];
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_notesPrefix$bookId');
    var notes = <ReaderNote>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final seenIds = <String>{};
          for (final entry in decoded.take(maxReaderNotesPerBook)) {
            final parsed = ReaderNote.fromJson(entry, fallbackBookId: bookId);
            if (parsed != null && seenIds.add(parsed.id)) {
              notes.add(parsed);
            }
          }
        }
      } on Object {
        // Fall through to migration check.
      }
    }

    if (prefs.getBool('$_notesMigratedPrefix$bookId') != true) {
      final migrated = await _migrateLegacyNotesIfNeeded(
        prefs,
        bookId,
        existing: notes,
        isPdf: isPdf,
        pdfPageCount: pdfPageCount,
      );
      notes = migrated;
    }

    return sortedReaderNotes(notes);
  }

  Future<List<ReaderNote>> _migrateLegacyNotesIfNeeded(
    SharedPreferences prefs,
    String bookId, {
    required List<ReaderNote> existing,
    required bool isPdf,
    int? pdfPageCount,
  }) async {
    final seenIds = <String>{for (final n in existing) n.id};
    final combined = List<ReaderNote>.of(existing);
    var changed = false;

    if (!isPdf) {
      final legacyMarks = await getBookmarks(bookId);
      final remainingMarks = <ReaderBookmark>[];
      for (final mark in legacyMarks) {
        if (!mark.hasNote) {
          remainingMarks.add(mark);
          continue;
        }
        final legacyId = 'legacy_${mark.id}';
        if (seenIds.add(legacyId)) {
          combined.add(
            ReaderNote(
              id: legacyId,
              bookId: bookId,
              chapterIndex: mark.chapterIndex,
              chapterTitle: mark.chapterTitle,
              paragraphIndex: mark.paragraphIndex,
              startOffset: 0,
              endOffset: 0,
              quote: clampNoteText(mark.excerpt, maxReaderNoteQuote),
              content: clampNoteText(mark.note, maxReaderNoteContent),
              color: NoteColor.amber,
              style: NoteStyle.underline,
              category: NoteCategory.thought,
              chapterProgress: mark.chapterProgress,
              isPdf: false,
              createdAt: mark.createdAt,
              updatedAt: mark.createdAt,
            ),
          );
          changed = true;
        }
      }
      if (remainingMarks.length != legacyMarks.length) {
        await saveBookmarks(bookId, remainingMarks);
      }
    }

    final rawPdfNotes = prefs.getString('$_pdfNotesPrefix$bookId');
    if (rawPdfNotes != null && rawPdfNotes.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPdfNotes);
        if (decoded is Map) {
          final now = DateTime.now();
          for (final entry in decoded.entries.take(2000)) {
            final page = int.tryParse(entry.key.toString());
            final value = entry.value;
            if (page == null || page < 0 || value is! String) continue;
            if (pdfPageCount != null && pdfPageCount > 0 && page >= pdfPageCount) {
              continue;
            }
            final normalized = value.trim();
            if (normalized.isEmpty) continue;
            final legacyId = 'legacy_pdf_${bookId}_$page';
            if (seenIds.add(legacyId)) {
              combined.add(
                ReaderNote(
                  id: legacyId,
                  bookId: bookId,
                  chapterIndex: page,
                  chapterTitle: '第 ${page + 1} 页',
                  paragraphIndex: -1,
                  quote: '',
                  content: clampNoteText(normalized, maxReaderNoteContent),
                  color: NoteColor.amber,
                  style: NoteStyle.highlight,
                  category: NoteCategory.thought,
                  chapterProgress: pdfPageCount != null && pdfPageCount > 1
                      ? (page / (pdfPageCount - 1)).clamp(0.0, 1.0)
                      : 0.0,
                  isPdf: true,
                  createdAt: now,
                  updatedAt: now,
                ),
              );
              changed = true;
            }
          }
        }
      } on Object {
        // Ignore malformed legacy PDF notes map.
      }
    }

    if (changed) {
      await saveNotes(bookId, combined);
    }
    await prefs.setBool('$_notesMigratedPrefix$bookId', true);
    return combined;
  }

  Future<void> saveNotes(String bookId, List<ReaderNote> notes) async {
    if (bookId.isEmpty || _isBookDeleted(bookId)) return;
    final capped = notes.length <= maxReaderNotesPerBook
        ? notes
        : (notes.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
              .take(maxReaderNotesPerBook)
              .toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_notesMigratedPrefix$bookId', true);
    await _setLatestString(
      '$_notesPrefix$bookId',
      jsonEncode([
        for (final note in sortedReaderNotes(capped)) note.toJson(),
      ]),
    );
  }

  Future<Set<String>> getCollapsedTocGroups(String bookId) async {
    if (bookId.isEmpty) return <String>{};
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_tocCollapsedPrefix$bookId',
    );
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
    if (bookId.isEmpty || _isBookDeleted(bookId)) return;
    final values =
        groupIds
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty && value.length <= 256)
            .take(512)
            .toList()
          ..sort();
    await _setLatestString('$_tocCollapsedPrefix$bookId', jsonEncode(values));
  }

  Future<ReaderSettings> getSettings() async {
    final raw = (await SharedPreferences.getInstance()).getString(_settingsKey);
    if (raw == null) return const ReaderSettings();
    try {
      return ReaderSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      return const ReaderSettings();
    }
  }

  Future<void> saveSettings(ReaderSettings settings) async {
    final version = ++_nextWriteVersion;
    _writeVersions[_settingsKey] = version;
    await _enqueueWrite(_settingsKey, () async {
      if (_writeVersions[_settingsKey] != version) return;
      final prefs = await SharedPreferences.getInstance();
      if (_writeVersions[_settingsKey] != version) return;

      String? previousImportedFontPath;
      final previousRaw = prefs.getString(_settingsKey);
      if (previousRaw != null) {
        try {
          previousImportedFontPath = ReaderSettings.fromJson(
            Map<String, dynamic>.from(jsonDecode(previousRaw) as Map),
          ).importedFontPath;
        } on Object {
          // A damaged old record must not block a valid settings write.
        }
      }
      await _setString(prefs, _settingsKey, jsonEncode(settings.toJson()));
      if (_writeVersions[_settingsKey] != version) return;
      if (previousImportedFontPath != null &&
          previousImportedFontPath != settings.importedFontPath) {
        await _deleteManagedFont(previousImportedFontPath);
      }
    });
  }

  Future<List<String>> getShelfGroups({required bool private}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = private ? _privateShelfGroupsKey : _shelfGroupsKey;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Iterable) return const <String>[];
      return normalizeBookGroups(decoded.cast<Object?>(), maxGroups: 64);
    } on Object {
      return const <String>[];
    }
  }

  Future<void> saveShelfGroups(
    Iterable<String> groups, {
    required bool private,
  }) async {
    final key = private ? _privateShelfGroupsKey : _shelfGroupsKey;
    final normalized = normalizeBookGroups(groups, maxGroups: 64);
    await _setLatestString(key, jsonEncode(normalized));
  }

  Future<void> clearBookState(String bookId) async {
    if (bookId.isEmpty) return;
    final keys = <String>[
      '$_progressPrefix$bookId',
      '$_pdfProgressPrefix$bookId',
      '$_pdfBookmarksPrefix$bookId',
      '$_pdfNotesPrefix$bookId',
      '$_pdfDisplayThemePrefix$bookId',
      '$_tocCollapsedPrefix$bookId',
      '$_bookmarksPrefix$bookId',
      '$_notesPrefix$bookId',
      '$_notesMigratedPrefix$bookId',
    ];
    final versions = <String, int>{
      for (final key in keys) key: _invalidateWrite(key),
    };
    final prefs = await SharedPreferences.getInstance();
    for (final key in keys) {
      await _enqueueWrite(key, () async {
        if (_writeVersions[key] != versions[key]) return;
        await prefs.remove(key);
      });
    }
  }

  static Future<void> _setLatestString(String key, String value) async {
    final version = ++_nextWriteVersion;
    _writeVersions[key] = version;
    await _enqueueWrite(key, () async {
      if (_writeVersions[key] != version) return;
      final prefs = await SharedPreferences.getInstance();
      if (_writeVersions[key] != version) return;
      await _setString(prefs, key, value);
    });
  }

  static int _invalidateWrite(String key) {
    final version = ++_nextWriteVersion;
    _writeVersions[key] = version;
    return version;
  }

  static Future<void> _enqueueWrite(
    String key,
    Future<void> Function() action,
  ) {
    final previous = _writeQueues[key] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    late final Future<void> safeTail;
    safeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _writeQueues[key] = safeTail;
    return operation.whenComplete(() {
      if (identical(_writeQueues[key], safeTail)) _writeQueues.remove(key);
    });
  }

  static Future<void> _setString(
    SharedPreferences prefs,
    String key,
    String value,
  ) async {
    final saved = await prefs.setString(key, value);
    if (!saved) throw StateError('无法保存本地阅读状态：$key');
  }
}
