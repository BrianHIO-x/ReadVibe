import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';

const _settingsKey = 'readvibe_settings';
const _progressPrefix = 'readvibe_progress_';
const _pdfProgressPrefix = 'readvibe_pdf_progress_';
const _pdfBookmarksPrefix = 'readvibe_pdf_bookmarks_';
const _pdfNotesPrefix = 'readvibe_pdf_notes_';
const _pdfDisplayThemePrefix = 'readvibe_pdf_display_theme_';
const _tocCollapsedPrefix = 'readvibe_toc_collapsed_';

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

  Future<void> clearBookState(String bookId) async {
    if (bookId.isEmpty) return;
    final keys = <String>[
      '$_progressPrefix$bookId',
      '$_pdfProgressPrefix$bookId',
      '$_pdfBookmarksPrefix$bookId',
      '$_pdfNotesPrefix$bookId',
      '$_pdfDisplayThemePrefix$bookId',
      '$_tocCollapsedPrefix$bookId',
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
