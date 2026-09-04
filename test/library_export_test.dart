import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/repositories/reader_repositories.dart';
import 'package:readvibe/screens/library_screen.dart';
import 'package:readvibe/services/book_export_service.dart';
import 'package:readvibe/services/update_service.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/book_card.dart';

class _Repository implements LibraryRepository {
  final Book latest = Book(
    id: 'one',
    title: '导出用书',
    format: BookFormat.txt,
    chapters: const [Chapter(index: 0, title: '第一章', content: '已保存的新内容')],
    importDate: DateTime(2026),
    fileSize: 100,
  );
  int loads = 0;
  @override
  Future<List<Book>> getBookSummaries() async => [
    latest.copyWith(chapters: []),
  ];
  @override
  Future<Book?> getBook(String id) async {
    loads++;
    return latest;
  }

  @override
  Future<ReaderSettings> getSettings() async =>
      const ReaderSettings(theme: ReaderThemeMode.warm);
  @override
  Future<ReadingProgress?> getShelfProgress(Book book) async => null;
  @override
  Future<BookAvailability> checkBookAvailability(
    Book book, {
    bool deep = false,
  }) async => BookAvailability.available;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Updates implements UpdateChecker {
  @override
  Future<String> currentVersion() async => '0.6.13';
  @override
  Future<UpdateCheckResult> checkForUpdate() async =>
      const UpdateCheckResult.upToDate();
}

class _Exporter implements BookExporter {
  Book? received;
  final done = Completer<bool>();
  @override
  Future<bool> exportBook(Book book) {
    received = book;
    return done.future;
  }
}

void main() {
  const incoming = MethodChannel('com.readvibe.app/incoming_file');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(incoming, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(incoming, null);
  });
  testWidgets(
    'narrow shelf filters keep input stable and export uses current stored content',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      final exporter = _Exporter();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: LibraryScreen(
            repository: repository,
            updateChecker: _Updates(),
            exporter: exporter,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      double? width;
      for (final label in ['未读', 'TXT', 'EPUB', 'MOBI/AZW', 'Word', 'PDF']) {
        await tester.tap(find.byTooltip('筛选书架'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        width ??= tester.getSize(find.byType(TextField)).width;
        expect(tester.getSize(find.byType(TextField)).width, width);
        expect(
          find.byKey(const ValueKey('shelf-active-filter')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      tester.widget<InputChip>(find.byType(InputChip)).onDeleted!();
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(BookCard).first);
      await tester.pumpAndSettle();
      expect(find.text('导出文件').hitTestable(), findsOneWidget);
      await tester.tap(find.text('导出文件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.loads, 1);
      expect(exporter.received!.chapters.single.content, '已保存的新内容');
      exporter.done.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('已导出'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
