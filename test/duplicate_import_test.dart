import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/book_id.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _book(String id, String title) => Book(
  id: id,
  title: title,
  format: BookFormat.txt,
  chapters: const [Chapter(index: 0, title: '第一章', content: '正文')],
  importDate: DateTime(2026),
  fileSize: 10,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    documents = Directory.systemTemp.createTempSync('readvibe_duplicate_');
  });

  tearDown(() {
    try {
      if (documents.existsSync()) documents.deleteSync(recursive: true);
    } on FileSystemException {
      // Temp cleanup is best-effort on Windows.
    }
  });

  test('ids stay unique when the clock repeats or moves backwards', () {
    final frozen = DateTime(2026, 5, 1);
    final ids = <String>{
      for (var index = 0; index < 200; index++) nextBookId('txt', now: frozen),
    };
    expect(ids, hasLength(200));

    // A time correction that steps the clock back must not reissue an old id.
    final rewound = nextBookId('txt', now: frozen.subtract(const Duration(days: 1)));
    expect(ids.contains(rewound), isFalse);
    expect(rewound.startsWith('txt_'), isTrue);
  });

  test('re-importing the same book keeps both copies apart', () async {
    final storage = StorageService(documentsDirectory: documents);
    final first = await storage.saveBook(_book(nextBookId('txt'), '同名的书'));
    final second = await storage.saveBook(_book(nextBookId('txt'), '同名的书'));
    final third = await storage.saveBook(_book(nextBookId('txt'), '同名的书'));

    expect(first.title, '同名的书');
    expect(second.title, '同名的书 (2)');
    expect(third.title, '同名的书 (3)');
    expect({first.id, second.id, third.id}, hasLength(3));

    final shelf = await storage.getBookSummaries();
    expect(shelf.map((book) => book.title).toSet(), {
      '同名的书',
      '同名的书 (2)',
      '同名的书 (3)',
    });

    // Each copy keeps its own payload rather than sharing one on disk.
    for (final book in shelf) {
      final loaded = await storage.getBook(book.id);
      expect(loaded!.chapters.single.content, '正文');
    }
  });

  test('saving an existing book again keeps its title untouched', () async {
    final storage = StorageService(documentsDirectory: documents);
    final id = nextBookId('txt');
    await storage.saveBook(_book(id, '原名'));
    final resaved = await storage.saveBook(_book(id, '原名'));

    expect(resaved.title, '原名');
    expect(await storage.getBookSummaries(), hasLength(1));
  });

  test('a numbered title never grows past the rename limit', () {
    final long = '书' * 120;
    final numbered = uniqueLibraryTitle(long, {long});
    expect(numbered.length, lessThanOrEqualTo(120));
    expect(numbered.endsWith(' (2)'), isTrue);
  });

  test('storage usage reports the library and its caches separately', () async {
    final storage = StorageService(documentsDirectory: documents);
    await storage.saveBook(_book(nextBookId('txt'), '占用统计'));

    final report = await storage.measureStorageUsage();
    expect(report.bookCount, 1);
    expect(report.bookPayloadBytes, greaterThan(0));
    expect(report.totalBytes, greaterThanOrEqualTo(report.libraryBytes));

    // Clearing caches must never touch a saved book.
    await storage.clearTemporaryCaches();
    final after = await storage.measureStorageUsage();
    expect(after.bookPayloadBytes, report.bookPayloadBytes);
    expect(after.cacheBytes, 0);
  });
}
