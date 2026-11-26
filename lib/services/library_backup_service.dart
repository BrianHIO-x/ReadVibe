import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/reader_bookmark.dart';
import '../models/reader_note.dart';
import '../models/reader_settings.dart';
import 'archive_safety.dart';
import 'book_export_service.dart';
import 'book_id.dart';
import 'storage/chapter_disk_store.dart';
import 'storage_service.dart';
import 'update_service.dart';

const readvibeBackupFormat = 'readvibe-backup';
const readvibeBackupSchemaVersion = 2;
const _readvibeRootToken = '{{READVIBE_ROOT}}';

const _progressPrefix = 'readvibe_progress_';
const _pdfProgressPrefix = 'readvibe_pdf_progress_';
const _pdfBookmarksPrefix = 'readvibe_pdf_bookmarks_';
const _pdfNotesPrefix = 'readvibe_pdf_notes_';
const _pdfDisplayThemePrefix = 'readvibe_pdf_display_theme_';
const _tocCollapsedPrefix = 'readvibe_toc_collapsed_';
const _bookmarksPrefix = 'readvibe_bookmarks_';
const _notesPrefix = 'readvibe_notes_';

class BackupOptions {
  const BackupOptions({
    this.includeBookFiles = true,
    this.includePrivate = false,
    this.includeSettings = true,
  });

  final bool includeBookFiles;
  final bool includePrivate;
  final bool includeSettings;
}

class BackupPreview {
  const BackupPreview({
    required this.schemaVersion,
    required this.createdAt,
    required this.appVersion,
    required this.includeBookFiles,
    required this.includesPrivate,
    required this.bookCount,
    required this.privateBookCount,
    required this.bookmarkCount,
    required this.noteCount,
    required this.hasSettings,
    required this.groupCount,
  });

  final int schemaVersion;
  final DateTime? createdAt;
  final String appVersion;
  final bool includeBookFiles;
  final bool includesPrivate;
  final int bookCount;
  final int privateBookCount;
  final int bookmarkCount;
  final int noteCount;
  final bool hasSettings;
  final int groupCount;
}

class BackupExportResult {
  const BackupExportResult({
    required this.fileName,
    required this.bookCount,
    required this.privateBookCount,
    required this.sizeBytes,
  });

  final String fileName;
  final int bookCount;
  final int privateBookCount;
  final int sizeBytes;
}

class BackupRestoreResult {
  const BackupRestoreResult({
    required this.restoredBooks,
    required this.mergedBooks,
    required this.skippedMissingFiles,
    required this.restoredSettings,
    required this.restoredGroups,
  });

  final int restoredBooks;
  final int mergedBooks;
  final int skippedMissingFiles;
  final bool restoredSettings;
  final int restoredGroups;
}

/// Exports and restores local ReadVibe backup packages (.zip) cleanly.
class LibraryBackupService {
  LibraryBackupService(
    this._storage, {
    this._exportDestination = const AndroidBookExportDestination(),
    Future<String> Function()? readAppVersion,
  }) : _readAppVersion = readAppVersion ?? UpdateService().currentVersion;

  final StorageService _storage;
  final BookExportDestination _exportDestination;
  final Future<String> Function() _readAppVersion;

  Future<BackupExportResult?> exportBackup(BackupOptions options) async {
    final appRoot = p.normalize(
      (await _storage.getAppDataDirectory()).absolute.path,
    );
    final prefs = await SharedPreferences.getInstance();
    final allRecords = await _storage.getAllBookMetadataRecords();
    final selectedRecords = options.includePrivate
        ? allRecords
        : allRecords.where((item) => item['private'] != true).toList();

    final exportedBooks = <Map<String, dynamic>>[];
    final bookStates = <String, Map<String, dynamic>>{};
    final payloadFiles = <String, (String sourcePath, bool rewriteJson)>{};

    void queueManagedFile(String? rawPath, {bool rewriteJson = false}) {
      if (rawPath == null || rawPath.trim().isEmpty) return;
      final file = File(p.normalize(rawPath.trim())).absolute;
      if (!_isSameOrWithin(appRoot, file.path) || !file.existsSync()) return;
      final rel = _toPosixRelative(appRoot, file.path);
      if (rel == null || rel.isEmpty) return;
      payloadFiles['payload/$rel'] = (file.path, rewriteJson);
    }

    void queueManagedDirectory(String? rawDirPath, {bool isBooksDir = false}) {
      if (rawDirPath == null || rawDirPath.trim().isEmpty) return;
      final dir = Directory(p.normalize(rawDirPath.trim())).absolute;
      if (!_isSameOrWithin(appRoot, dir.path) || !dir.existsSync()) return;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = _toPosixRelative(appRoot, entity.absolute.path);
        if (rel == null || rel.isEmpty) continue;
        if (isBooksDir && _isTransientBookBackupArtifact(rel)) continue;
        final isChapterJson =
            isBooksDir &&
            rel.contains('/chapters/') &&
            rel.toLowerCase().endsWith('.json');
        payloadFiles['payload/$rel'] = (entity.absolute.path, isChapterJson);
      }
    }

    var privateBookCount = 0;
    for (final rawRecord in selectedRecords) {
      final bookId = rawRecord['id'] as String?;
      if (bookId == null || bookId.isEmpty) continue;
      if (rawRecord['private'] == true) privateBookCount++;

      exportedBooks.add(
        Map<String, dynamic>.from(
          _rewritePathsInJson(rawRecord, appRoot: appRoot, toToken: true)
              as Map,
        ),
      );

      final state = _collectBookState(prefs, bookId);
      if (options.includeBookFiles) {
        final safeId = safeBookId(bookId);
        final chapterDir = Directory(p.join(appRoot, 'books', safeId));
        final legacyFile = File(p.join(appRoot, 'books', '$safeId.json'));
        if (chapterDir.existsSync()) {
          queueManagedDirectory(chapterDir.path, isBooksDir: true);
        } else if (legacyFile.existsSync()) {
          queueManagedFile(legacyFile.path, rewriteJson: true);
        } else {
          final legacyPref = prefs.getString('$kLegacyChapterPrefPrefix$bookId');
          if (legacyPref != null && legacyPref.isNotEmpty) {
            state['legacyChapters'] = legacyPref;
          }
        }

        final sourcePath = rawRecord['sourcePath'] as String?;
        if (sourcePath != null && sourcePath.trim().isNotEmpty) {
          final format = rawRecord['format'];
          if (format == BookFormat.pdf.name) {
            queueManagedFile(sourcePath);
          } else {
            queueManagedDirectory(sourcePath);
          }
        }
        queueManagedFile(rawRecord['coverImagePath'] as String?);
        final embeddedFonts = rawRecord['embeddedFonts'];
        if (embeddedFonts is Map) {
          for (final fontPath in embeddedFonts.values) {
            if (fontPath is String) queueManagedFile(fontPath);
          }
        }
      }
      if (state.isNotEmpty) {
        bookStates[bookId] = state;
      }
    }

    Map<String, dynamic>? settingsJson;
    if (options.includeSettings) {
      final settings = await _storage.getSettings();
      settingsJson = Map<String, dynamic>.from(
        _rewritePathsInJson(settings.toJson(), appRoot: appRoot, toToken: true)
            as Map,
      );
      if (options.includeBookFiles) {
        queueManagedFile(settings.importedFontPath);
      }
    }

    final shelfGroups = await _storage.getShelfGroups(private: false);
    final privateShelfGroups = options.includePrivate
        ? await _storage.getShelfGroups(private: true)
        : const <String>[];

    String appVersion = '';
    try {
      appVersion = await _readAppVersion();
    } on Object {
      // Version string is informational inside backup metadata.
    }

    final backupManifest = <String, dynamic>{
      'format': readvibeBackupFormat,
      'schemaVersion': readvibeBackupSchemaVersion,
      'createdAt': DateTime.now().toIso8601String(),
      if (appVersion.isNotEmpty) 'appVersion': appVersion,
      'includeBookFiles': options.includeBookFiles,
      'includesPrivate': options.includePrivate,
      'settings': ?settingsJson,
      'shelfGroups': shelfGroups,
      if (options.includePrivate) 'privateShelfGroups': privateShelfGroups,
      'books': exportedBooks,
      'bookStates': bookStates,
    };

    final tempDir = await getTemporaryDirectory();
    final stagingDir = Directory(p.join(tempDir.path, 'readvibe_exports'));
    await stagingDir.create(recursive: true);
    final now = DateTime.now();
    final timestamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final fileName = options.includeBookFiles
        ? 'ReadVibe-Backup-$timestamp.zip'
        : 'ReadVibe-Backup-$timestamp-meta.zip';
    final stagedZip = File(p.join(stagingDir.path, fileName));

    final specs = <(String, String, bool)>[
      for (final entry in payloadFiles.entries)
        (entry.key, entry.value.$1, entry.value.$2),
    ];

    try {
      await Isolate.run(
        () => _writeBackupZipWorker(
          zipPath: stagedZip.path,
          backupManifestJson: jsonEncode(backupManifest),
          appRoot: appRoot,
          fileSpecs: specs,
        ),
      );
      final sizeBytes = await stagedZip.length();
      final saved = await _exportDestination.save(
        sourcePath: stagedZip.path,
        fileName: fileName,
        mimeType: 'application/zip',
      );
      if (!saved) return null;
      return BackupExportResult(
        fileName: fileName,
        bookCount: exportedBooks.length,
        privateBookCount: privateBookCount,
        sizeBytes: sizeBytes,
      );
    } finally {
      try {
        if (await stagedZip.exists()) await stagedZip.delete();
      } on FileSystemException {
        // Staged backup cleanup is best-effort.
      }
    }
  }

  Future<BackupPreview> inspectBackup(String zipPath) {
    return Isolate.run(() => _inspectBackupWorker(zipPath));
  }

  Future<BackupRestoreResult> restoreBackup(
    String zipPath, {
    required bool allowPrivateRestore,
    bool restorePrivateAsNormal = false,
    bool restoreSettings = true,
  }) async {
    final appRoot = p.normalize(
      (await _storage.getAppDataDirectory()).absolute.path,
    );
    final decodedPayload = await Isolate.run(
      () => _readAndValidateManifestWorker(zipPath),
    );
    final manifest = _parseValidatedBackupManifest(decodedPayload);

    final rawBooks = (manifest['books'] as List)
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final existingRecords = await _storage.getAllBookMetadataRecords();
    final existingById = <String, Map<String, dynamic>>{
      for (final record in existingRecords)
        if (record['id'] is String && (record['id'] as String).isNotEmpty)
          record['id'] as String: record,
    };

    final extractableBookIds = <String>{};
    for (final rawBook in rawBooks) {
      final id = rawBook['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final isPrivate = rawBook['private'] == true;
      if (isPrivate && !allowPrivateRestore && !restorePrivateAsNormal) {
        continue;
      }
      if (!existingById.containsKey(id)) {
        extractableBookIds.add(id);
      }
    }

    final allowedExactPaths = <String>{};
    final allowedDirPrefixes = <String>{};
    for (final rawBook in rawBooks) {
      final id = rawBook['id'] as String?;
      if (id == null || !extractableBookIds.contains(id)) continue;
      final safeId = safeBookId(id);
      allowedDirPrefixes.add('payload/books/$safeId/');
      allowedExactPaths.add('payload/books/$safeId.json');

      final srcToken = rawBook['sourcePath'] as String?;
      final srcPayload = _payloadEntryForToken(srcToken);
      if (srcPayload != null) {
        if (rawBook['format'] == BookFormat.pdf.name) {
          allowedExactPaths.add(srcPayload);
        } else {
          allowedDirPrefixes.add('$srcPayload/');
        }
      }
      final coverPayload = _payloadEntryForToken(
        rawBook['coverImagePath'] as String?,
      );
      if (coverPayload != null) allowedExactPaths.add(coverPayload);
      final fonts = rawBook['embeddedFonts'];
      if (fonts is Map) {
        for (final val in fonts.values) {
          if (val is String) {
            final fontPayload = _payloadEntryForToken(val);
            if (fontPayload != null) allowedExactPaths.add(fontPayload);
          }
        }
      }
    }
    if (restoreSettings && manifest['settings'] is Map) {
      final settingsMap = manifest['settings'] as Map;
      final fontToken = settingsMap['importedFontPath'];
      if (fontToken is String) {
        final fontPayload = _payloadEntryForToken(fontToken);
        if (fontPayload != null) allowedExactPaths.add(fontPayload);
      }
    }

    if (allowedExactPaths.isNotEmpty || allowedDirPrefixes.isNotEmpty) {
      await Isolate.run(
        () => _extractPayloadFilesWorker(
          zipPath: zipPath,
          appRoot: appRoot,
          allowedExactPaths: allowedExactPaths.toList(growable: false),
          allowedDirPrefixes: allowedDirPrefixes.toList(growable: false),
        ),
      );
    }

    var restoredGroupsCount = 0;
    final currentNormalGroups = await _storage.getShelfGroups(private: false);
    final incomingNormalGroups = _readStringList(manifest['shelfGroups']);
    final mergedNormal = normalizeBookGroups(<String>[
      ...currentNormalGroups,
      ...incomingNormalGroups,
      if (restorePrivateAsNormal)
        ..._readStringList(manifest['privateShelfGroups']),
    ], maxGroups: 64);
    if (mergedNormal.length > currentNormalGroups.length) {
      restoredGroupsCount += mergedNormal.length - currentNormalGroups.length;
      await _storage.saveShelfGroups(mergedNormal, private: false);
    }

    if (allowPrivateRestore && !restorePrivateAsNormal) {
      final currentPrivateGroups = await _storage.getShelfGroups(private: true);
      final incomingPrivateGroups = _readStringList(
        manifest['privateShelfGroups'],
      );
      final mergedPrivate = normalizeBookGroups(<String>[
        ...currentPrivateGroups,
        ...incomingPrivateGroups,
      ], maxGroups: 64);
      if (mergedPrivate.length > currentPrivateGroups.length) {
        restoredGroupsCount +=
            mergedPrivate.length - currentPrivateGroups.length;
        await _storage.saveShelfGroups(mergedPrivate, private: true);
      }
    }

    var restoredSettings = false;
    if (restoreSettings && manifest['settings'] is Map) {
      final remappedSettingsMap = Map<String, dynamic>.from(
        _rewritePathsInJson(
              manifest['settings'],
              appRoot: appRoot,
              toToken: false,
            )
            as Map,
      );
      var parsedSettings = ReaderSettings.fromJson(remappedSettingsMap);
      final fontPath = parsedSettings.importedFontPath;
      if (fontPath != null && !await File(fontPath).exists()) {
        parsedSettings = parsedSettings.copyWith(
          fontFamily: ReaderSettings.systemFontFamily,
          clearImportedFont: true,
        );
      }
      await _storage.saveSettings(parsedSettings);
      restoredSettings = true;
    }

    final rawStates = manifest['bookStates'] is Map
        ? Map<String, dynamic>.from(manifest['bookStates'] as Map)
        : const <String, dynamic>{};

    var restoredBooks = 0;
    var mergedBooks = 0;
    var skippedMissingFiles = 0;

    final existingTitlesNormal = <String>{
      for (final item in existingRecords)
        if (item['title'] is String && item['private'] != true)
          item['title'] as String,
    };
    final existingTitlesPrivate = <String>{
      for (final item in existingRecords)
        if (item['title'] is String && item['private'] == true)
          item['title'] as String,
    };

    for (final rawBook in rawBooks) {
      final id = rawBook['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final isBackupPrivate = rawBook['private'] == true;
      if (isBackupPrivate && !allowPrivateRestore && !restorePrivateAsNormal) {
        continue;
      }

      final remappedRecord = Map<String, dynamic>.from(
        _rewritePathsInJson(rawBook, appRoot: appRoot, toToken: false) as Map,
      );
      final stateRaw = rawStates[id] is Map
          ? Map<String, dynamic>.from(rawStates[id] as Map)
          : const <String, dynamic>{};

      final existing = existingById[id];
      if (existing != null) {
        final groups = _readStringList(remappedRecord['groups']);
        if (groups.isNotEmpty) {
          await _storage.updateBooksGroups(<String>[id], add: groups);
        }
        final pageCount = existing['pageCount'] is num
            ? (existing['pageCount'] as num).toInt()
            : 0;
        await _mergeAndSaveBookState(
          id,
          stateRaw,
          pageCount: pageCount,
          isExisting: true,
        );
        mergedBooks++;
        continue;
      }

      if (restorePrivateAsNormal) {
        remappedRecord.remove('private');
      }
      final targetPrivate = remappedRecord['private'] == true;
      final hasPayload = await _hasRestoredBookPayload(
        id,
        remappedRecord,
        stateRaw,
        appRoot,
      );
      if (!hasPayload) {
        skippedMissingFiles++;
        continue;
      }

      final rawTitle = (remappedRecord['title'] as String?)?.trim() ?? '未命名书籍';
      final titlePool = targetPrivate
          ? existingTitlesPrivate
          : existingTitlesNormal;
      if (titlePool.contains(rawTitle)) {
        remappedRecord['title'] = uniqueLibraryTitle(rawTitle, titlePool);
      }
      titlePool.add(remappedRecord['title'] as String);

      _storage.clearDeletedBookMarker(id);
      if (stateRaw['legacyChapters'] is String) {
        final legacyJson = stateRaw['legacyChapters'] as String;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('$kLegacyChapterPrefPrefix$id', legacyJson);
      }
      await _storage.upsertRestoredBookRecord(remappedRecord);
      existingById[id] = remappedRecord;

      final pageCount = remappedRecord['pageCount'] is num
          ? (remappedRecord['pageCount'] as num).toInt()
          : 0;
      await _mergeAndSaveBookState(
        id,
        stateRaw,
        pageCount: pageCount,
        isExisting: false,
      );
      final groups = _readStringList(remappedRecord['groups']);
      if (groups.isNotEmpty) {
        await _storage.updateBooksGroups(<String>[id], add: groups);
      }
      restoredBooks++;
    }

    return BackupRestoreResult(
      restoredBooks: restoredBooks,
      mergedBooks: mergedBooks,
      skippedMissingFiles: skippedMissingFiles,
      restoredSettings: restoredSettings,
      restoredGroups: restoredGroupsCount,
    );
  }

  Future<bool> _hasRestoredBookPayload(
    String bookId,
    Map<String, dynamic> record,
    Map<String, dynamic> state,
    String appRoot,
  ) async {
    final format = record['format'];
    if (format == BookFormat.pdf.name) {
      final src = record['sourcePath'] as String?;
      return src != null && src.isNotEmpty && await File(src).exists();
    }
    final safeId = safeBookId(bookId);
    final manifest = File(p.join(appRoot, 'books', safeId, 'manifest.json'));
    if (await manifest.exists()) return true;
    final legacyFile = File(p.join(appRoot, 'books', '$safeId.json'));
    if (await legacyFile.exists()) return true;
    final legacyChapters = state['legacyChapters'];
    return legacyChapters is String && legacyChapters.trim().isNotEmpty;
  }

  Future<void> _mergeAndSaveBookState(
    String bookId,
    Map<String, dynamic> state, {
    required int pageCount,
    required bool isExisting,
  }) async {
    if (state.isEmpty) return;

    final rawProgress = state['progress'];
    if (rawProgress is Map) {
      try {
        final incoming = ReadingProgress.fromJson(
          Map<String, dynamic>.from(rawProgress)..['bookId'] = bookId,
        );
        final current = isExisting ? await _storage.getProgress(bookId) : null;
        if (current == null ||
            incoming.lastReadDate.isAfter(current.lastReadDate)) {
          await _storage.saveProgress(incoming);
        }
      } on Object {
        // Ignore malformed progress entry.
      }
    }

    final rawPdfProgress = state['pdfProgress'];
    if (rawPdfProgress is Map && pageCount > 0) {
      try {
        final incoming = PdfReadingProgress.fromJson(
          Map<String, dynamic>.from(rawPdfProgress)
            ..['bookId'] = bookId
            ..['pageCount'] = pageCount,
        );
        final current = isExisting
            ? await _storage.getPdfProgress(
                bookId,
                pageCount: pageCount,
                migrateLegacy: false,
              )
            : null;
        if (current == null ||
            incoming.lastReadDate.isAfter(current.lastReadDate)) {
          await _storage.savePdfProgress(incoming);
        }
      } on Object {
        // Ignore malformed PDF progress entry.
      }
    }

    final rawBookmarks = state['bookmarks'];
    if (rawBookmarks is List) {
      final parsed = <ReaderBookmark>[
        for (final entry in rawBookmarks) ?ReaderBookmark.fromJson(entry),
      ];
      if (parsed.isNotEmpty) {
        if (isExisting) {
          final current = await _storage.getBookmarks(bookId);
          final seen = <String>{for (final mark in current) mark.id};
          final merged = <ReaderBookmark>[
            ...current,
            for (final mark in parsed)
              if (seen.add(mark.id)) mark,
          ];
          await _storage.saveBookmarks(bookId, merged);
        } else {
          await _storage.saveBookmarks(bookId, parsed);
        }
      }
    }

    final rawPdfBookmarks = state['pdfBookmarks'];
    if (rawPdfBookmarks is List && pageCount > 0) {
      final incomingPages = <int>{
        for (final item in rawPdfBookmarks)
          if (item is num && item.toInt() >= 0 && item.toInt() < pageCount)
            item.toInt(),
      };
      if (incomingPages.isNotEmpty) {
        final currentPages = isExisting
            ? await _storage.getPdfBookmarks(bookId, pageCount)
            : const <int>{};
        await _storage.savePdfBookmarks(
          bookId,
          <int>{...currentPages, ...incomingPages},
          pageCount,
        );
      }
    }

    final rawPdfNotes = state['pdfNotes'];
    if (rawPdfNotes is Map && pageCount > 0) {
      final incomingNotes = <int, String>{};
      for (final entry in rawPdfNotes.entries) {
        final page = int.tryParse(entry.key.toString());
        final value = entry.value;
        if (page == null ||
            page < 0 ||
            page >= pageCount ||
            value is! String ||
            value.trim().isEmpty) {
          continue;
        }
        incomingNotes[page] = value.trim();
      }
      if (incomingNotes.isNotEmpty) {
        final currentNotes = isExisting
            ? await _storage.getPdfNotes(bookId, pageCount)
            : const <int, String>{};
        await _storage.savePdfNotes(
          bookId,
          <int, String>{...incomingNotes, ...currentNotes},
          pageCount,
        );
      }
    }

    final rawTheme = state['pdfDisplayTheme'];
    if (!isExisting && rawTheme is String) {
      final theme = PdfDisplayTheme.values.asNameMap()[rawTheme];
      if (theme != null) {
        await _storage.savePdfDisplayTheme(bookId, theme);
      }
    }

    final rawToc = state['tocCollapsed'];
    if (rawToc is List) {
      final incomingGroups = <String>{
        for (final entry in rawToc)
          if (entry is String && entry.trim().isNotEmpty) entry.trim(),
      };
      if (incomingGroups.isNotEmpty) {
        final currentGroups = isExisting
            ? await _storage.getCollapsedTocGroups(bookId)
            : const <String>{};
        await _storage.saveCollapsedTocGroups(
          bookId,
          <String>{...currentGroups, ...incomingGroups},
        );
      }
    }

    final rawNotes = state['notes'];
    if (rawNotes is List) {
      final parsed = <ReaderNote>[
        for (final entry in rawNotes)
          ?ReaderNote.fromJson(entry, fallbackBookId: bookId),
      ];
      if (parsed.isNotEmpty) {
        final existingNotes = isExisting
            ? await _storage.getNotes(bookId)
            : const <ReaderNote>[];
        final byId = <String, ReaderNote>{
          for (final note in existingNotes) note.id: note,
        };
        for (final incoming in parsed) {
          final current = byId[incoming.id];
          if (current == null || incoming.updatedAt.isAfter(current.updatedAt)) {
            byId[incoming.id] = incoming;
          }
        }
        await _storage.saveNotes(bookId, byId.values.toList());
      }
    }
  }
}

Map<String, dynamic> _collectBookState(
  SharedPreferences prefs,
  String bookId,
) {
  final state = <String, dynamic>{};

  void copyJson(String key, String outField) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded != null) state[outField] = decoded;
    } on Object {
      // Skip malformed entry instead of aborting full backup.
    }
  }

  copyJson('$_progressPrefix$bookId', 'progress');
  copyJson('$_pdfProgressPrefix$bookId', 'pdfProgress');
  copyJson('$_bookmarksPrefix$bookId', 'bookmarks');
  copyJson('$_notesPrefix$bookId', 'notes');
  copyJson('$_pdfBookmarksPrefix$bookId', 'pdfBookmarks');
  copyJson('$_pdfNotesPrefix$bookId', 'pdfNotes');
  copyJson('$_tocCollapsedPrefix$bookId', 'tocCollapsed');
  final theme = prefs.getString('$_pdfDisplayThemePrefix$bookId');
  if (theme != null && theme.isNotEmpty) {
    state['pdfDisplayTheme'] = theme;
  }
  return state;
}

Future<void> _writeBackupZipWorker({
  required String zipPath,
  required String backupManifestJson,
  required String appRoot,
  required List<(String, String, bool)> fileSpecs,
}) async {
  final encoder = ZipFileEncoder();
  encoder.create(zipPath, level: ZipFileEncoder.gzip);
  try {
    encoder.addArchiveFile(
      ArchiveFile.bytes('backup.json', utf8.encode(backupManifestJson)),
    );
    for (final (entryPath, sourcePath, rewriteJson) in fileSpecs) {
      final file = File(sourcePath);
      if (!file.existsSync()) continue;
      if (rewriteJson) {
        final rawText = file.readAsStringSync(encoding: utf8);
        if (_containsRootReference(rawText, appRoot)) {
          final decoded = jsonDecode(rawText);
          final rewritten = _rewritePathsInJson(
            decoded,
            appRoot: appRoot,
            toToken: true,
          );
          final encoded = utf8.encode(jsonEncode(rewritten));
          encoder.addArchiveFile(ArchiveFile.bytes(entryPath, encoded));
          continue;
        }
      }
      await encoder.addFile(file, entryPath, ZipFileEncoder.gzip);
    }
  } finally {
    await encoder.close();
  }
}

BackupPreview _inspectBackupWorker(String zipPath) {
  final decoded = _readAndValidateManifestWorker(zipPath);
  final manifest = _parseValidatedBackupManifest(decoded);
  final books = (manifest['books'] as List)
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList();
  var privateBookCount = 0;
  final groups = <String>{};
  for (final group in _readStringList(manifest['shelfGroups'])) {
    groups.add(group);
  }
  for (final group in _readStringList(manifest['privateShelfGroups'])) {
    groups.add(group);
  }
  for (final book in books) {
    if (book['private'] == true) privateBookCount++;
    groups.addAll(_readStringList(book['groups']));
  }

  var bookmarkCount = 0;
  var noteCount = 0;
  final states = manifest['bookStates'];
  if (states is Map) {
    for (final rawState in states.values) {
      if (rawState is! Map) continue;
      final bookmarks = rawState['bookmarks'];
      if (bookmarks is List) {
        for (final entry in bookmarks) {
          if (entry is! Map) continue;
          bookmarkCount++;
          final note = entry['note'];
          if (note is String && note.trim().isNotEmpty) {
            noteCount++;
          }
        }
      }
      final notes = rawState['notes'];
      if (notes is List) {
        for (final entry in notes) {
          if (entry is! Map) continue;
          final quote = entry['quote'];
          final content = entry['content'];
          if ((quote is String && quote.trim().isNotEmpty) ||
              (content is String && content.trim().isNotEmpty)) {
            noteCount++;
          }
        }
      }
      final pdfBookmarks = rawState['pdfBookmarks'];
      if (pdfBookmarks is List) {
        bookmarkCount += pdfBookmarks.length;
      }
      final pdfNotes = rawState['pdfNotes'];
      if (pdfNotes is Map) {
        for (final value in pdfNotes.values) {
          if (value is String && value.trim().isNotEmpty) {
            noteCount++;
          }
        }
      }
    }
  }

  final createdRaw = manifest['createdAt'];
  return BackupPreview(
    schemaVersion: (manifest['schemaVersion'] as num).toInt(),
    createdAt: createdRaw is String ? DateTime.tryParse(createdRaw) : null,
    appVersion: manifest['appVersion'] is String
        ? (manifest['appVersion'] as String)
        : '',
    includeBookFiles: manifest['includeBookFiles'] == true,
    includesPrivate: manifest['includesPrivate'] == true,
    bookCount: books.length,
    privateBookCount: privateBookCount,
    bookmarkCount: bookmarkCount,
    noteCount: noteCount,
    hasSettings: manifest['settings'] is Map,
    groupCount: groups.length,
  );
}

String _readAndValidateManifestWorker(String zipPath) {
  final file = File(zipPath);
  if (!file.existsSync()) {
    throw const FormatException('找不到备份压缩包');
  }
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final budget = ArchiveExtractionBudget();
    ArchiveFile? manifestEntry;
    for (final entry in archive) {
      assertSafeArchiveEntry(entry);
      budget.recordHeader(entry);
      if (!entry.isDirectory && entry.name == 'backup.json') {
        if (entry.size > kMaxManifestBytes) {
          throw const FormatException('备份清单体积超出安全上限');
        }
        manifestEntry = entry;
      }
    }
    if (manifestEntry == null) {
      throw const FormatException('备份文件缺少 backup.json 清单');
    }
    final bytes = manifestEntry.readBytes();
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('备份清单内容为空');
    }
    return utf8.decode(bytes);
  } finally {
    input.closeSync();
  }
}

void _extractPayloadFilesWorker({
  required String zipPath,
  required String appRoot,
  required List<String> allowedExactPaths,
  required List<String> allowedDirPrefixes,
}) {
  final exactSet = allowedExactPaths.toSet();
  final input = InputFileStream(zipPath);
  final modifiedChaptersByBookDir =
      <String, Map<String, ({int bytes, String sha256})>>{};
  final extractedManifestDirs = <String>{};

  try {
    final archive = ZipDecoder().decodeStream(input);
    final budget = ArchiveExtractionBudget();
    for (final entry in archive) {
      assertSafeArchiveEntry(entry);
      budget.recordHeader(entry);
      if (entry.isDirectory) continue;
      final normalized = _normalizeZipEntryName(entry.name);
      if (!normalized.startsWith('payload/')) continue;

      final allowed =
          exactSet.contains(normalized) ||
          allowedDirPrefixes.any(normalized.startsWith);
      if (!allowed) continue;

      final destFile = _resolveSafePayloadDest(normalized, appRoot);
      destFile.parent.createSync(recursive: true);
      final out = OutputFileStream(destFile.path);
      try {
        entry.writeContent(out, freeMemory: true);
      } finally {
        out.closeSync();
      }

      final segments = normalized.split('/');
      if (segments.length >= 4 &&
          segments[1] == 'books' &&
          segments[3] == 'manifest.json') {
        extractedManifestDirs.add(segments[2]);
      } else if (segments.length >= 5 &&
          segments[1] == 'books' &&
          segments[3] == 'chapters' &&
          normalized.toLowerCase().endsWith('.json')) {
        final rawText = destFile.readAsStringSync(encoding: utf8);
        if (rawText.contains(_readvibeRootToken)) {
          final rewritten = _rewritePathsInJson(
            jsonDecode(rawText),
            appRoot: appRoot,
            toToken: false,
          );
          final bytes = utf8.encode(jsonEncode(rewritten));
          destFile.writeAsBytesSync(bytes, flush: true);
          final chapterFileName = segments.sublist(4).join('/');
          modifiedChaptersByBookDir.putIfAbsent(
            segments[2],
            () => <String, ({int bytes, String sha256})>{},
          )[chapterFileName] = (
            bytes: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          );
        }
      } else if (segments.length == 3 &&
          segments[1] == 'books' &&
          normalized.toLowerCase().endsWith('.json')) {
        final rawText = destFile.readAsStringSync(encoding: utf8);
        if (rawText.contains(_readvibeRootToken)) {
          final rewritten = _rewritePathsInJson(
            jsonDecode(rawText),
            appRoot: appRoot,
            toToken: false,
          );
          destFile.writeAsStringSync(
            jsonEncode(rewritten),
            encoding: utf8,
            flush: true,
          );
        }
      }
    }
  } finally {
    input.closeSync();
  }

  for (final safeBookDir in extractedManifestDirs) {
    final modified = modifiedChaptersByBookDir[safeBookDir];
    if (modified == null || modified.isEmpty) continue;
    final manifestFile = File(
      p.join(appRoot, 'books', safeBookDir, 'manifest.json'),
    );
    if (!manifestFile.existsSync()) continue;
    final decoded = jsonDecode(manifestFile.readAsStringSync(encoding: utf8));
    if (decoded is! Map) continue;
    final manifest = Map<String, dynamic>.from(decoded);
    final chapters = manifest['chapters'];
    if (chapters is! List) continue;
    final updatedChapters = <Object?>[];
    for (final rawEntry in chapters) {
      if (rawEntry is Map) {
        final entry = Map<String, dynamic>.from(rawEntry);
        final file = entry['file'];
        final info = file is String ? modified[file] : null;
        if (info != null) {
          entry['bytes'] = info.bytes;
          entry['sha256'] = info.sha256;
        }
        updatedChapters.add(entry);
      } else {
        updatedChapters.add(rawEntry);
      }
    }
    manifest['chapters'] = updatedChapters;
    manifestFile.writeAsStringSync(
      jsonEncode(manifest),
      encoding: utf8,
      flush: true,
    );
  }
}

Map<String, dynamic> _parseValidatedBackupManifest(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('备份清单格式无效');
  }
  final map = Map<String, dynamic>.from(decoded);
  if (map['format'] != readvibeBackupFormat) {
    throw const FormatException('不是有效的 ReadVibe 备份文件');
  }
  final version = map['schemaVersion'];
  if (version is! num || version.toInt() > readvibeBackupSchemaVersion) {
    throw const FormatException('备份版本不受当前应用支持，请更新应用后重试');
  }
  if (map['books'] is! List) {
    throw const FormatException('备份文件缺少书籍列表');
  }
  return map;
}

String _normalizeZipEntryName(String name) =>
    name.endsWith('/') ? name.substring(0, name.length - 1) : name;

File _resolveSafePayloadDest(String normalizedEntry, String appRoot) {
  final segments = normalizedEntry.split('/');
  if (segments.length < 3 || segments[0] != 'payload') {
    throw const FormatException('备份载荷路径无效');
  }
  const allowedRoots = <String>{'books', 'epub', 'word', 'pdf', 'fonts'};
  final subSegments = segments.sublist(1);
  if (!allowedRoots.contains(subSegments.first) ||
      subSegments.any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw const FormatException('备份载荷包含未授权目录');
  }
  final dest = p.normalize(p.joinAll(<String>[appRoot, ...subSegments]));
  if (!p.isWithin(p.normalize(appRoot), dest)) {
    throw const FormatException('备份载荷路径越界');
  }
  return File(dest);
}

String? _payloadEntryForToken(String? tokenPath) {
  if (tokenPath == null || !tokenPath.startsWith('$_readvibeRootToken/')) {
    return null;
  }
  final rel = tokenPath.substring(_readvibeRootToken.length + 1);
  final segments = rel.split('/');
  if (segments.isEmpty ||
      segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
    return null;
  }
  return 'payload/${segments.join('/')}';
}

bool _isTransientBookBackupArtifact(String relPosix) {
  final parts = relPosix.split('/');
  for (final part in parts) {
    if (part.endsWith('.tmp') ||
        part.endsWith('.bak') ||
        part.endsWith('.presplit') ||
        part.endsWith('.edit.tmp') ||
        part.endsWith('.edit.bak')) {
      return true;
    }
  }
  return false;
}

bool _containsRootReference(String text, String appRoot) {
  if (text.contains(appRoot)) return true;
  final posixRoot = appRoot.replaceAll('\\', '/');
  return posixRoot != appRoot && text.contains(posixRoot);
}

bool _isSameOrWithin(String root, String candidate) {
  final normalizedRoot = p.normalize(root);
  final normalizedCandidate = p.normalize(candidate);
  return p.equals(normalizedRoot, normalizedCandidate) ||
      p.isWithin(normalizedRoot, normalizedCandidate);
}

String? _toPosixRelative(String root, String target) {
  if (!_isSameOrWithin(root, target)) return null;
  if (p.equals(p.normalize(root), p.normalize(target))) return '';
  return p.relative(p.normalize(target), from: p.normalize(root)).replaceAll(
    '\\',
    '/',
  );
}

Object? _rewritePathsInJson(
  Object? node, {
  required String appRoot,
  required bool toToken,
}) {
  if (node is String) {
    if (toToken) {
      if (p.equals(p.normalize(appRoot), p.normalize(node))) {
        return _readvibeRootToken;
      }
      if (p.isWithin(p.normalize(appRoot), p.normalize(node))) {
        final rel = _toPosixRelative(appRoot, node);
        if (rel != null && rel.isNotEmpty) {
          return '$_readvibeRootToken/$rel';
        }
      }
      return node;
    } else {
      if (node == _readvibeRootToken) return appRoot;
      if (node.startsWith('$_readvibeRootToken/')) {
        final rel = node.substring(_readvibeRootToken.length + 1);
        final segments = rel.split('/').where((s) => s.isNotEmpty).toList();
        if (segments.any((s) => s == '.' || s == '..')) {
          throw const FormatException('备份内路径不安全');
        }
        final resolved = p.normalize(
          p.joinAll(<String>[appRoot, ...segments]),
        );
        if (!p.isWithin(p.normalize(appRoot), resolved)) {
          throw const FormatException('备份内路径越界');
        }
        return resolved;
      }
      return node;
    }
  }
  if (node is List) {
    return <Object?>[
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

List<String> _readStringList(Object? raw) {
  if (raw is! Iterable) return const <String>[];
  return <String>[
    for (final item in raw)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ];
}
