import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:readvibe/services/book_search_service.dart';
import 'package:readvibe/services/word_count_service.dart';
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
    final payload = _chapterDirectory(documents, book.id);
    await payload.rename('${payload.path}.tmp');

    final restored = await storage.getBook(book.id);

    expect(restored?.chapters.single.content, '正文内容');
    expect(await payload.exists(), isTrue);
  });

  test('new books persist a manifest and independent chapter files', () async {
    final book = Book(
      id: 'chapter_directory',
      title: '分章存储',
      format: BookFormat.txt,
      chapters: const <Chapter>[
        Chapter(index: 0, title: '第一章', content: '一'),
        Chapter(index: 1, title: '第二章', content: '二'),
      ],
      importDate: DateTime(2026, 1, 1),
      fileSize: 20,
    );

    await storage.saveBook(book);

    final directory = _chapterDirectory(documents, book.id);
    expect(File(p.join(directory.path, 'manifest.json')).existsSync(), isTrue);
    final chapterFiles = Directory(
      p.join(directory.path, 'chapters'),
    ).listSync().whereType<File>().toList();
    expect(chapterFiles, hasLength(2));
    expect((await storage.getBook(book.id))?.chapters, hasLength(2));
  });

  test('chapter bodies remain lazy until their content is accessed', () async {
    final book = _textBook('lazy_chapter');
    await storage.saveBook(book);
    final loaded = await storage.getBook(book.id);
    expect(loaded, isNotNull);
    final chapterFile = File(
      p.join(
        _chapterDirectory(documents, book.id).path,
        'chapters',
        '000000.json',
      ),
    );
    await chapterFile.delete();

    expect(() => loaded!.chapters.single.content, throwsFormatException);
  });

  test(
    'lazy chapters remain searchable and countable in worker isolates',
    () async {
      final book = _textBook('lazy_worker');
      await storage.saveBook(book);
      final loaded = await storage.getBook(book.id);

      final results = await BookSearchService.search(loaded!, '正文');
      final counts = await WordCountService().countChapters(loaded);

      expect(results, hasLength(1));
      expect(counts.single, 4);
    },
  );

  test(
    'chapter payload falls back to bak when the primary is damaged',
    () async {
      final book = _textBook('recover_bak');
      await storage.saveBook(book);
      final payload = _chapterDirectory(documents, book.id);
      await payload.rename('${payload.path}.bak');
      await Directory(p.join(payload.path, 'chapters')).create(recursive: true);
      await File(
        p.join(payload.path, 'manifest.json'),
      ).writeAsString('{damaged', flush: true);

      final restored = await storage.getBook(book.id);

      expect(restored?.chapters.single.content, '正文内容');
      expect(await payload.exists(), isTrue);
    },
  );

  test(
    'shelf health check distinguishes missing and recoverable payloads',
    () async {
      final book = _textBook('availability');
      await storage.saveBook(book);
      final payload = _chapterDirectory(documents, book.id);

      expect(
        await storage.checkBookAvailability(book),
        BookAvailability.available,
      );
      await payload.rename('${payload.path}.bak');
      expect(
        await storage.checkBookAvailability(book),
        BookAvailability.available,
      );
      await File(
        p.join('${payload.path}.bak', 'manifest.json'),
      ).writeAsString('{truncated');
      expect(
        await storage.checkBookAvailability(book),
        BookAvailability.payloadMissing,
      );
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

  test('PDF progress migrates away from the novel chapter model', () async {
    final book = Book(
      id: 'pdf_progress_migration',
      title: 'PDF',
      format: BookFormat.pdf,
      chapters: const <Chapter>[],
      pageCount: 20,
      sourcePath: p.join(documents.path, 'source.pdf'),
      importDate: DateTime(2026, 1, 1),
    );
    await File(book.sourcePath!).writeAsBytes(<int>[1]);
    await storage.saveBook(book);
    await storage.saveProgress(
      ReadingProgress(
        bookId: book.id,
        chapterIndex: 7,
        lastReadDate: DateTime(2026, 1, 2),
      ),
    );

    final migrated = await storage.getPdfProgress(book.id, pageCount: 20);

    expect(migrated?.pageIndex, 7);
    expect(migrated?.pageCount, 20);
    expect(
      (await storage.getShelfProgress(book))?.scrollProgress,
      closeTo(7 / 19, 0.0001),
    );
  });

  test('PDF bookmarks are clamped, sorted and removed with the book', () async {
    final book = Book(
      id: 'pdf_bookmarks',
      title: 'PDF',
      format: BookFormat.pdf,
      chapters: const <Chapter>[],
      pageCount: 8,
      sourcePath: p.join(documents.path, 'bookmarks.pdf'),
      importDate: DateTime(2026, 1, 1),
    );
    await File(book.sourcePath!).writeAsBytes(<int>[1]);
    await storage.saveBook(book);

    await storage.savePdfBookmarks(book.id, <int>{7, 2, -1, 8}, 8);
    expect(await storage.getPdfBookmarks(book.id, 8), <int>{2, 7});
    await storage.savePdfNotes(book.id, <int, String>{
      2: '重点',
      8: '越界',
      3: '   ',
    }, 8);
    expect(await storage.getPdfNotes(book.id, 8), <int, String>{2: '重点'});

    await storage.deleteBook(book.id);
    expect(await storage.getPdfBookmarks(book.id, 8), isEmpty);
    expect(await storage.getPdfNotes(book.id, 8), isEmpty);
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
    expect(
      _chapterDirectory(documents, referencedBook.id).existsSync(),
      isTrue,
    );
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

Directory _chapterDirectory(Directory documents, String bookId) {
  final safeId = base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');
  return Directory(p.join(documents.path, 'ReadVibe', 'books', safeId));
}
