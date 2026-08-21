import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late StorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    documents = Directory.systemTemp.createTempSync('readvibe_storage_test_');
    storage = StorageService(documentsDirectory: documents);
  });

  tearDown(() {
    try {
      if (documents.existsSync()) documents.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows antivirus can briefly retain a handle after an isolate read.
    }
  });

  test('chapter payload recovers from an interrupted tmp write', () async {
    final book = _textBook('recover_tmp');
    await storage.saveBook(book);
    final payload = _chapterPayload(documents, book.id);
    await payload.rename('${payload.path}.tmp');

    final restored = await storage.getBook(book.id);

    expect(restored?.chapters.single.content, '正文内容');
    expect(await payload.exists(), isTrue);
  });

  test(
    'chapter payload falls back to bak when the primary is damaged',
    () async {
      final book = _textBook('recover_bak');
      await storage.saveBook(book);
      final payload = _chapterPayload(documents, book.id);
      await payload.copy('${payload.path}.bak');
      await payload.writeAsString('{damaged', flush: true);

      final restored = await storage.getBook(book.id);

      expect(restored?.chapters.single.content, '正文内容');
      expect(await payload.exists(), isTrue);
    },
  );

  test('deletion wins against an in-flight progress save', () async {
    final book = _textBook('delete_progress_race');
    await storage.saveBook(book);
    final progress = ReadingProgress(
      bookId: book.id,
      chapterIndex: 0,
      scrollOffset: 120,
      lastReadDate: DateTime(2026, 1, 1),
    );

    final save = storage.saveProgress(progress);
    final delete = storage.deleteBook(book.id);
    await Future.wait(<Future<void>>[save, delete]);

    expect(await storage.getProgress(book.id), isNull);
    expect(await storage.getBook(book.id), isNull);
  });

  test('chapter counts and their sum are persisted together', () async {
    final book = _textBook('word_count_metadata');
    await storage.saveBook(book);

    await storage.saveWordCounts(book, <int>[4]);

    final summary = (await storage.getBookSummaries()).single;
    expect(summary.chapterWordCounts, <int>[4]);
    expect(summary.wordCount, 4);
  });

  test('the newest concurrent settings write is authoritative', () async {
    final first = storage.saveSettings(
      const ReaderSettings(fontSize: 16, automaticUpdateChecks: true),
    );
    final second = storage.saveSettings(
      const ReaderSettings(fontSize: 24, automaticUpdateChecks: false),
    );
    await Future.wait(<Future<void>>[first, second]);

    final restored = await storage.getSettings();
    expect(restored.fontSize, 24);
    expect(restored.automaticUpdateChecks, isFalse);
  });

  test('automatic update checks default off and round-trip explicitly', () {
    expect(const ReaderSettings().automaticUpdateChecks, isFalse);
    final restored = ReaderSettings.fromJson(
      const ReaderSettings(automaticUpdateChecks: true).toJson(),
    );
    expect(restored.automaticUpdateChecks, isTrue);
  });

  test('orphan cleanup honors metadata and the 24-hour grace period', () async {
    final referencedBook = _textBook('referenced_payload');
    await storage.saveBook(referencedBook);

    final root = await storage.getAppDataDirectory();
    final books = Directory(p.join(root.path, 'books'))
      ..createSync(recursive: true);
    final epub = Directory(p.join(root.path, 'epub'))
      ..createSync(recursive: true);
    final pdf = Directory(p.join(root.path, 'pdf'))
      ..createSync(recursive: true);
    final orphanBook = File(p.join(books.path, 'b3JwaGFu.json'))
      ..writeAsStringSync('[]');
    final orphanEpub = Directory(p.join(epub.path, 'orphan'))
      ..createSync(recursive: true);
    File(p.join(orphanEpub.path, 'image.png')).writeAsBytesSync(<int>[1]);
    final orphanPdf = File(p.join(pdf.path, 'orphan.pdf'))
      ..writeAsBytesSync(<int>[1]);

    final firstPass = await storage.collectOrphanedData();
    expect(firstPass.removedEntries, 0);
    expect(orphanBook.existsSync(), isTrue);
    expect(orphanEpub.existsSync(), isTrue);
    expect(orphanPdf.existsSync(), isTrue);

    final secondPass = await storage.collectOrphanedData(
      referenceTime: DateTime.now().add(const Duration(days: 2)),
    );
    expect(secondPass.removedFiles, 2);
    expect(secondPass.removedDirectories, 1);
    expect(orphanBook.existsSync(), isFalse);
    expect(orphanEpub.existsSync(), isFalse);
    expect(orphanPdf.existsSync(), isFalse);
    expect(_chapterPayload(documents, referencedBook.id).existsSync(), isTrue);
  });

  test('orphan cleanup is disabled when shelf metadata is malformed', () async {
    final root = await storage.getAppDataDirectory();
    final books = Directory(p.join(root.path, 'books'))
      ..createSync(recursive: true);
    final orphan = File(p.join(books.path, 'b3JwaGFu.json'))
      ..writeAsStringSync('[]');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('readvibe_books', '{damaged');

    final result = await storage.collectOrphanedData(
      referenceTime: DateTime.now().add(const Duration(days: 2)),
    );

    expect(result.removedEntries, 0);
    expect(orphan.existsSync(), isTrue);
  });
}

Book _textBook(String id) => Book(
  id: id,
  title: '测试书',
  format: BookFormat.txt,
  chapters: const <Chapter>[Chapter(index: 0, title: '第一章', content: '正文内容')],
  importDate: DateTime(2026, 1, 1),
  fileSize: 12,
);

File _chapterPayload(Directory documents, String bookId) {
  final safeId = base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');
  return File(p.join(documents.path, 'ReadVibe', 'books', '$safeId.json'));
}
