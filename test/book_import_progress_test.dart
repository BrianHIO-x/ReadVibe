import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/book_import_coordinator.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Importing a serialized novel takes long enough that a reader cannot tell a
/// working import from a wedged one without being told. These tests hold the
/// reporting contract the shelf relies on: the import announces which step it
/// is on, counts chapters as they reach disk, and never goes quiet before it
/// is finished.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late StorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.resetLibraryCache();
    documents = Directory.systemTemp.createTempSync('readvibe_progress_');
    storage = StorageService(documentsDirectory: documents);
  });

  tearDown(() {
    try {
      if (documents.existsSync()) documents.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows antivirus can briefly retain a handle after an isolate read.
    }
  });

  test('saving a book counts chapters as they reach disk', () async {
    final reports = <List<int>>[];

    await storage.saveBook(
      _novel('counted', 600),
      onChapterProgress: (written, count) => reports.add(<int>[written, count]),
    );

    expect(reports, isNotEmpty);
    expect(reports.first, <int>[0, 600]);
    expect(reports.last, <int>[600, 600]);
    for (final report in reports) {
      expect(report[1], 600);
    }
    // A count that moved backwards would show the reader a shrinking bar.
    for (var index = 1; index < reports.length; index++) {
      expect(reports[index][0], greaterThanOrEqualTo(reports[index - 1][0]));
    }
    // Reporting once per chapter would cost more than the write itself, and
    // reporting once per book would leave a long save looking stuck.
    expect(reports.length, greaterThan(4));
    expect(reports.length, lessThan(600));
  });

  test('a long book still reports while it is being written', () async {
    final reports = <int>[];

    await storage.saveBook(
      _novel('long', 5000),
      onChapterProgress: (written, _) => reports.add(written),
    );

    expect(reports.first, 0);
    expect(reports.last, 5000);
    // The number of reports must not grow with the book, otherwise a serial
    // pays a shelf rebuild per chapter.
    expect(reports.length, lessThan(120));
    expect(reports.length, greaterThan(4));
  });

  test('importing a TXT reports each step in order', () async {
    final source = File(p.join(documents.path, '连载长篇.txt'));
    source.writeAsStringSync(_novelText(120));
    final coordinator = BookImportCoordinator(storage);
    final stages = <BookImportStage>[];
    BookImportProgress? lastSaving;

    final book = await coordinator.importFile(
      path: source.path,
      fileName: '连载长篇.txt',
      requestPdfPassword: () async => null,
      onProgress: (progress) {
        if (stages.isEmpty || stages.last != progress.stage) {
          stages.add(progress.stage);
        }
        if (progress.stage == BookImportStage.saving) lastSaving = progress;
      },
    );

    expect(book, isNotNull);
    expect(stages, <BookImportStage>[
      BookImportStage.inspecting,
      BookImportStage.parsing,
      BookImportStage.saving,
    ]);
    expect(lastSaving, isNotNull);
    expect(lastSaving!.completed, book!.chapterCount);
    expect(lastSaving!.fraction, 1.0);
  });

  test('a step with nothing to measure reports no fraction', () {
    const inspecting = BookImportProgress(BookImportStage.inspecting);
    const started = BookImportProgress(BookImportStage.saving, total: 400);
    const halfway = BookImportProgress(
      BookImportStage.saving,
      completed: 200,
      total: 400,
    );

    expect(inspecting.fraction, isNull);
    expect(started.fraction, isNull);
    expect(halfway.fraction, 0.5);
    expect(inspecting.label, '识别文件');
    expect(halfway.label, '保存章节');
  });
}

String _novelText(int chapterCount) {
  final buffer = StringBuffer();
  for (var index = 1; index <= chapterCount; index++) {
    buffer.writeln('第$index章 试炼之门');
    buffer.writeln('　　这是第$index章的正文，用来确认导入过程的每一步都有回报。');
    buffer.writeln();
  }
  return buffer.toString();
}

Book _novel(String id, int chapterCount) => Book(
  id: id,
  title: '连载长篇',
  format: BookFormat.txt,
  chapters: <Chapter>[
    for (var index = 0; index < chapterCount; index++)
      Chapter(
        index: index,
        title: '第${index + 1}章',
        content: '　　这是第${index + 1}章的正文。',
      ),
  ],
  importDate: DateTime(2026, 1, 1),
  fileSize: chapterCount * 64,
);
