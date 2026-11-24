import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../models/book_content_revision.dart';
import '../../repositories/reader_repositories.dart';
import 'chapter_payload_codec.dart';

const kLegacyChapterPrefPrefix = 'readvibe_chapters_';

// Chapter payloads are written in batches. These bound how often the import
// hands work to a worker isolate and how often it can report progress.
const _chapterWriteBatches = 48;
const _minChapterBatch = 32;
const _maxChapterBatch = 512;
const _kChapterIoTimeout = Duration(seconds: 30);
const _kLegacyMigrationTimeout = Duration(milliseconds: 250);

String safeBookId(String bookId) =>
    base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');

bool isStoredChapterFileName(String value) =>
    RegExp(r'^\d{6,}(?:-[A-Za-z0-9_-]+)?\.json$').hasMatch(value);

bool isChapterPayloadName(String name) =>
    RegExp(r'^[A-Za-z0-9_-]+\.json(?:\.(?:tmp|bak|presplit))?$').hasMatch(name);

bool isChapterDirectoryName(String name) =>
    RegExp(r'^[A-Za-z0-9_-]+(?:\.(?:tmp|bak))?$').hasMatch(name);

Future<bool> isOlderThan(FileSystemEntity entity, DateTime cutoff) async {
  try {
    final stat = await entity.stat();
    return !stat.modified.isAfter(cutoff);
  } on Object {
    return false;
  }
}

int? chapterContentRevision(List<Chapter> chapters) {
  final first = chapters.firstOrNull;
  return first is LazyChapter ? first.store.contentRevision : null;
}

class LazyChapterStore {
  final String chaptersDirectoryPath;
  final int contentRevision;
  final List<String> fileNames;
  final List<int?> expectedBytes;
  final List<String?> expectedDigests;
  final LinkedHashMap<int, Chapter> _cache = LinkedHashMap<int, Chapter>();

  /// Chapters whose digest already matched during this session.
  ///
  /// A chapter file is immutable for a given content revision, so verifying it
  /// twice cannot discover anything the first check missed. Remembering the
  /// result matters because this runs on the UI isolate: a book that has no
  /// detected chapters becomes one very large payload, and re-hashing it on
  /// every cache miss stalls the frame that asked for it.
  final Set<int> _verified = <int>{};

  LazyChapterStore({
    required this.chaptersDirectoryPath,
    required this.contentRevision,
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
    if (!file.existsSync()) {
      throw FormatException('章节 ${index + 1} 文件缺失或不完整');
    }
    // Read the bytes once. Decoding first and re-encoding the string to hash
    // it walked the whole payload twice and held both copies at the same time.
    final bytes = file.readAsBytesSync();
    final expected = expectedBytes[index];
    if (expected != null && bytes.length != expected) {
      throw FormatException('章节 ${index + 1} 文件缺失或不完整');
    }
    final expectedDigest = expectedDigests[index];
    if (expectedDigest != null && !_verified.contains(index)) {
      if (sha256.convert(bytes).toString() != expectedDigest) {
        throw FormatException('章节 ${index + 1} 校验失败');
      }
      _verified.add(index);
    }
    final chapter = decodeChapterPayload(jsonDecode(utf8.decode(bytes)), index);
    _cache[index] = chapter;
    while (_cache.length > 8) {
      _cache.remove(_cache.keys.first);
    }
    return chapter;
  }
}

class LazyChapter extends Chapter {
  final LazyChapterStore store;
  final bool richContent;
  final int? richBlockCount;
  final bool? semanticHeading;

  LazyChapter({
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

/// Manages immutable per-chapter directories, manifests, and legacy payloads.
class ChapterDiskStore {
  ChapterDiskStore(
    this._getAppDataDirectory,
    this._enqueueLibraryMutation,
    this._enqueueChapterWrite,
    this._isBookDeleted,
  );

  final Future<Directory> Function() _getAppDataDirectory;
  final Future<T> Function<T>(Future<T> Function()) _enqueueLibraryMutation;
  final Future<T> Function<T>(String, Future<T> Function())
  _enqueueChapterWrite;
  final bool Function(String) _isBookDeleted;

  Future<File> chapterFile(String bookId) async {
    final root = await _getAppDataDirectory();
    final directory = Directory(p.join(root.path, 'books'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, '${safeBookId(bookId)}.json'));
  }

  Future<Directory> chapterDirectory(String bookId) async {
    final root = await _getAppDataDirectory();
    final books = Directory(p.join(root.path, 'books'));
    if (!await books.exists()) await books.create(recursive: true);
    return Directory(p.join(books.path, safeBookId(bookId)));
  }

  Future<bool> hasReadableBookPayload(
    Book book,
    SharedPreferences prefs, {
    bool deep = false,
  }) async {
    final legacy = prefs.getString('$kLegacyChapterPrefPrefix${book.id}');
    if (legacy != null && legacy.trim().isNotEmpty) return true;

    final directory = await chapterDirectory(book.id);
    for (final candidate in <Directory>[
      directory,
      Directory('${directory.path}.tmp'),
      Directory('${directory.path}.bak'),
    ]) {
      if (await _chapterDirectoryLooksPlausible(
        candidate,
        verifyContents: deep,
      )) {
        return true;
      }
    }

    final file = await chapterFile(book.id);
    for (final candidate in <File>[
      file,
      File('${file.path}.tmp'),
      File('${file.path}.bak'),
    ]) {
      if (await _chapterPayloadLooksPlausible(
        candidate,
        verifyContents: deep,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<int?> readStoredContentRevision(String bookId) async =>
      _readStoredContentRevision(await chapterDirectory(bookId));

  Future<List<Chapter>> loadChapters(
    String bookId,
    SharedPreferences prefs,
  ) async {
    final legacyKey = '$kLegacyChapterPrefPrefix$bookId';
    final legacyRaw = prefs.getString(legacyKey);
    if (legacyRaw != null) {
      final chapters = _chaptersFromJson(legacyRaw);
      try {
        await _migrateLegacyChapters(
          bookId,
          chapters,
        ).timeout(_kLegacyMigrationTimeout);
        await prefs.remove(legacyKey);
      } on Object {
        // Reading must win over migration. If file storage is unavailable, keep
        // the legacy payload in preferences and let the user open the book.
      }
      return chapters;
    }

    final directory = await chapterDirectory(
      bookId,
    ).timeout(_kChapterIoTimeout);
    for (final candidate in <Directory>[
      directory,
      Directory('${directory.path}.tmp'),
      Directory('${directory.path}.bak'),
    ]) {
      try {
        if (!await candidate.exists().timeout(_kChapterIoTimeout)) continue;
        final chapters = await loadChapterDirectory(
          candidate,
        ).timeout(_kChapterIoTimeout);
        if (candidate.path != directory.path) {
          final recovered = _materializeChapters(chapters);
          try {
            await saveChapters(
              bookId,
              recovered,
              contentRevision: chapterContentRevision(chapters) ?? 0,
            ).timeout(_kChapterIoTimeout);
            return await loadChapterDirectory(
              directory,
            ).timeout(_kChapterIoTimeout);
          } on Object {
            return recovered;
          }
        }
        return chapters;
      } on Object {
        // Try a temporary/backup directory, then the legacy monolithic file.
      }
    }

    final file = await chapterFile(bookId).timeout(_kChapterIoTimeout);
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
        final chapters = await Isolate.run(
          () => _chaptersFromJson(raw),
        ).timeout(_kChapterIoTimeout);
        if (candidate.path != file.path) {
          try {
            await _migrateLegacyChapters(
              bookId,
              chapters,
            ).timeout(_kChapterIoTimeout);
          } on Object {
            // The recovered in-memory copy is still readable for this session.
          }
        }
        unawaited(
          _migrateLegacyChapters(
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

  Future<void> _migrateLegacyChapters(String bookId, List<Chapter> chapters) =>
      _enqueueLibraryMutation(() async {
        if (_isBookDeleted(bookId)) return;
        final directory = await chapterDirectory(bookId);
        if (await _resolveChapterManifestFile(directory) != null) return;
        await saveChapters(bookId, chapters);
      });

  Future<void> saveChapters(
    String bookId,
    List<Chapter> chapters, {
    int contentRevision = 0,
    ChapterWriteProgress? onProgress,
  }) async {
    final directory = await chapterDirectory(bookId);
    return _enqueueChapterWrite(directory.path, () async {
      await writeChapterDirectory(
        directory,
        chapters,
        contentRevision: contentRevision,
        onProgress: onProgress,
      );
      await _deleteLegacyPayloadFiles(bookId);
    });
  }

  Future<void> replaceSingleChapter({
    required Directory directory,
    required Book sourceBook,
    required Chapter replacement,
    required int nextRevision,
  }) {
    return _enqueueChapterWrite(directory.path, () async {
      if (!await directory.exists()) {
        final chapters = List<Chapter>.of(sourceBook.chapters);
        chapters[replacement.index] = replacement;
        await writeChapterDirectory(
          directory,
          chapters,
          contentRevision: nextRevision,
        );
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
      if (oldFileName is! String || !isStoredChapterFileName(oldFileName)) {
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
        'contentRevision': nextRevision,
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
      if (await liveManifest.exists()) {
        if (await backupManifest.exists()) await backupManifest.delete();
        await liveManifest.rename(backupManifest.path);
      } else if (manifestFile.path != backupManifest.path) {
        await backupManifest.writeAsString(
          rawManifest,
          encoding: utf8,
          flush: true,
        );
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
        if (await oldFile.exists()) {
          await oldFile.setLastModified(DateTime.now());
        }
      } on FileSystemException {
        // The new manifest is authoritative.
      }
    });
  }

  Future<List<Chapter>> loadChapterDirectory(Directory directory) async {
    final manifestFile = await _resolveChapterManifestFile(directory);
    if (manifestFile == null) {
      throw const FormatException('章节清单不存在');
    }
    final rawManifest = await manifestFile.readAsString(encoding: utf8);
    final manifest = await _decodeChapterManifestInBackground(rawManifest);
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
          !isStoredChapterFileName(fileName) ||
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
    final store = LazyChapterStore(
      chaptersDirectoryPath: chaptersDirectory.path,
      contentRevision: readContentRevision(manifest['contentRevision']),
      fileNames: fileNames,
      expectedBytes: expectedBytes,
      expectedDigests: expectedDigests,
    );
    return List<Chapter>.generate(
      entries.length,
      (index) => LazyChapter(
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

  Future<void> writeChapterDirectory(
    Directory directory,
    List<Chapter> chapters, {
    int contentRevision = 0,
    ChapterWriteProgress? onProgress,
  }) async {
    final temporary = Directory('${directory.path}.tmp');
    final backup = Directory('${directory.path}.bak');
    if (await temporary.exists()) await temporary.delete(recursive: true);
    final temporaryChapters = Directory(p.join(temporary.path, 'chapters'));
    await temporaryChapters.create(recursive: true);

    final manifestEntries = <Map<String, dynamic>>[];
    final chaptersPath = temporaryChapters.path;
    final batchSize = _chapterBatchSize(chapters.length);
    onProgress?.call(0, chapters.length);
    for (var start = 0; start < chapters.length; start += batchSize) {
      final end = math.min(chapters.length, start + batchSize);
      final batch = chapters.sublist(start, end);
      manifestEntries.addAll(
        await _storeChapterBatchInBackground(chaptersPath, batch, start),
      );
      onProgress?.call(end, chapters.length);
    }
    await File(p.join(temporary.path, 'manifest.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'version': 2,
        'contentRevision': contentRevision,
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

  Future<void> deleteBookPayloads(String bookId) async {
    await _deleteLegacyPayloadFiles(bookId);
    final directory = await chapterDirectory(bookId);
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
  }

  Future<void> _deleteLegacyPayloadFiles(String bookId) async {
    final file = await chapterFile(bookId);
    for (final candidate in <File>[
      file,
      File('${file.path}.tmp'),
      File('${file.path}.bak'),
      File('${file.path}.presplit'),
    ]) {
      try {
        if (await candidate.exists()) await candidate.delete();
      } on FileSystemException {
        // Metadata has already been removed or updated.
      }
    }
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
      await _verifyLegacyPayloadInBackground(file.path);
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
}) => verifyContents
    ? _verifyChapterDirectoryInBackground(directory.path)
    : _inspectChapterDirectory(directory);

Future<bool> _verifyChapterDirectoryInBackground(String path) => Isolate.run(
  () => _inspectChapterDirectory(Directory(path), verifyContents: true),
);

Future<void> _verifyLegacyPayloadInBackground(String path) => Isolate.run(() {
  _chaptersFromJson(File(path).readAsStringSync(encoding: utf8));
});

Future<bool> _inspectChapterDirectory(
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
    final parsed = verifyContents
        ? _chapterManifestFromJson(rawManifest)
        : await _decodeChapterManifestInBackground(rawManifest);
    final entries = parsed['chapters'];
    final chapterCount = parsed['chapterCount'];
    if (parsed['version'] != 2 ||
        entries is! List ||
        entries.isEmpty ||
        chapterCount is! num ||
        chapterCount.toInt() != entries.length) {
      return false;
    }
    for (final index in _shallowChapterProbes(entries.length, verifyContents)) {
      final rawEntry = entries[index];
      if (rawEntry is! Map) return false;
      final entry = Map<String, dynamic>.from(rawEntry);
      final fileName = entry['file'];
      final expectedBytes = entry['bytes'];
      if (fileName is! String ||
          !isStoredChapterFileName(fileName) ||
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
        decodeChapterPayload(jsonDecode(raw), index);
      }
    }
    return true;
  } on Object {
    return false;
  }
}

List<int> _shallowChapterProbes(int count, bool verifyContents) {
  const probeLimit = 24;
  if (verifyContents || count <= probeLimit) {
    return List<int>.generate(count, (index) => index, growable: false);
  }
  final step = count / (probeLimit - 1);
  final probes = <int>{0, count - 1};
  for (var position = 1; position < probeLimit - 1; position++) {
    probes.add((position * step).floor().clamp(0, count - 1));
  }
  final ordered = probes.toList(growable: false)..sort();
  return ordered;
}

Future<File?> _resolveChapterManifestFile(Directory directory) async {
  final live = File(p.join(directory.path, 'manifest.json'));
  if (await live.exists()) return live;
  final staged = File('${live.path}.edit.tmp');
  final backup = File('${live.path}.edit.bak');
  for (final candidate in <File>[backup, staged]) {
    if (!await candidate.exists()) continue;
    return candidate;
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

Future<List<Map<String, dynamic>>> _storeChapterBatchInBackground(
  String chaptersPath,
  List<Chapter> batch,
  int firstIndex,
) => Isolate.run(() => _storeChapterBatch(chaptersPath, batch, firstIndex));

int _chapterBatchSize(int chapterCount) => (chapterCount / _chapterWriteBatches)
    .ceil()
    .clamp(_minChapterBatch, _maxChapterBatch);

List<Map<String, dynamic>> _storeChapterBatch(
  String chaptersPath,
  List<Chapter> chapters,
  int firstIndex,
) {
  final entries = <Map<String, dynamic>>[];
  for (var offset = 0; offset < chapters.length; offset++) {
    final chapter = chapters[offset];
    final fileName = '${(firstIndex + offset).toString().padLeft(6, '0')}.json';
    final payload = utf8.encode(jsonEncode(encodeChapterPayload(chapter)));
    File(p.join(chaptersPath, fileName)).writeAsBytesSync(payload);
    entries.add(<String, dynamic>{
      'file': fileName,
      'bytes': payload.length,
      'sha256': sha256.convert(payload).toString(),
      'title': chapter.title,
      if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle,
      'hasRichContent': chapter.hasRichEpubContent,
      'richBlockCount': chapter.epubBlockCount,
      'hasSemanticHeading': chapter.hasSemanticHeading,
    });
  }
  return entries;
}

Future<Map<String, dynamic>> _decodeChapterManifestInBackground(String raw) =>
    Isolate.run(() => _chapterManifestFromJson(raw));

Future<String> _encodeEditedChapter(Chapter chapter) =>
    Isolate.run(() => jsonEncode(encodeChapterPayload(chapter)));

Future<int?> _readStoredContentRevision(Directory directory) async {
  final manifest = await _resolveChapterManifestFile(directory);
  if (manifest == null) return null;
  final data = await _decodeChapterManifestInBackground(
    await manifest.readAsString(encoding: utf8),
  );
  return readContentRevision(data['contentRevision']);
}
