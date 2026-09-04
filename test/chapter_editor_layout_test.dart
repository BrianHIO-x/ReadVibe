import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/repositories/reader_repositories.dart';
import 'package:readvibe/screens/reader_screen.dart';
import 'package:readvibe/screens/reader/reader_pagination_support.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/chapter_editor_sheet.dart';

class _EditorRepository implements ReaderRepository {
  Chapter? saved;
  final savedCounts = Completer<void>();
  @override
  Future<ReaderSettings> getSettings() async =>
      const ReaderSettings(theme: ReaderThemeMode.warm);
  @override
  Future<ReadingProgress?> getProgress(String bookId) async => null;
  @override
  Future<void> saveProgress(ReadingProgress progress) async {}
  @override
  Future<void> saveSettings(ReaderSettings settings) async {}
  @override
  Future<Set<String>> getCollapsedTocGroups(String bookId) async => {};
  @override
  Future<void> saveCollapsedTocGroups(
    String bookId,
    Set<String> groups,
  ) async {}
  @override
  Future<void> replaceChapter(Book book, Chapter chapter) async {
    saved = chapter;
  }

  @override
  Future<void> saveWordCounts(Book book, List<int> counts) async {
    if (!savedCounts.isCompleted) savedCounts.complete();
  }

  @override
  Future<void> deleteBook(String bookId) async {}
  @override
  Future<File> saveImportedFont(String sourcePath, String fileName) =>
      throw UnsupportedError('unused');
}

Future<void> _frames(WidgetTester tester, [int count = 50]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<ScrollController> _openEditor(
  WidgetTester tester,
  _EditorRepository repository,
) async {
  tester.view.physicalSize = const Size(400, 880);
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 54, bottom: 24);
  tester.view.padding = const FakeViewPadding(top: 54, bottom: 24);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewInsets);
  final book = Book(
    id: 'editor-insets',
    title: 'Editor',
    format: BookFormat.txt,
    chapters: [
      Chapter(
        index: 0,
        title: '第一章',
        content: 'Chapter content for editing.\n' * 100,
      ),
    ],
    importDate: DateTime(2026),
    fileSize: 3000,
    wordCount: 2000,
    chapterWordCounts: const [2000],
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.theme,
      home: ReaderScreen(book: book, repository: repository),
    ),
  );
  await _frames(tester);
  final list = tester.widget<ListView>(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is ListView &&
              widget.controller is SelectionAwareScrollController,
        )
        .first,
  );
  final controller = list.controller!;
  controller.jumpTo(320);
  await _frames(tester, 3);
  await tester.tapAt(const Offset(200, 440));
  await tester.pumpAndSettle();
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
  expect(find.byType(ChapterEditorSheet), findsOneWidget);
  return controller;
}

void main() {
  const wakelock =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          wakelock,
          (_) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelock, null);
  });

  testWidgets(
    'editor fills the page and anchors its header below the cutout during IME changes',
    (tester) async {
      final repository = _EditorRepository();
      final reader = await _openEditor(tester, repository);
      final originalOffset = reader.offset;
      expect(tester.getRect(find.byType(ChapterEditorSheet)).top, 0);
      expect(
        tester.getTopLeft(find.byTooltip('关闭编辑器')).dy,
        greaterThanOrEqualTo(54),
      );
      final titleY = tester.getTopLeft(find.text('编辑当前章节')).dy;
      final saveY = tester.getTopLeft(find.text('保存')).dy;
      final titleFieldY = tester.getTopLeft(find.byType(TextField).at(0)).dy;
      final body = tester
          .widget<TextField>(find.byType(TextField).at(1))
          .controller!;
      final originalText = body.text;
      for (final inset in [80.0, 200.0, 340.0, 220.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        tester.view.padding = FakeViewPadding(
          top: 54,
          bottom: inset > 0 ? 0 : 24,
        );
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getTopLeft(find.text('编辑当前章节')).dy, titleY);
          expect(tester.getTopLeft(find.text('保存')).dy, saveY);
          expect(
            tester.getTopLeft(find.byType(TextField).at(0)).dy,
            titleFieldY,
          );
          expect(tester.takeException(), isNull);
        }
        expect(
          tester.getBottomLeft(find.byType(TextField).at(1)).dy,
          lessThanOrEqualTo(880 - inset),
        );
        expect(body.text, originalText);
        expect(reader.offset, originalOffset);
      }
      await tester.tap(find.byTooltip('关闭编辑器'));
      await tester.pumpAndSettle();
      expect(find.byType(ChapterEditorSheet), findsNothing);
      expect(repository.saved, isNull);
      expect(reader.offset, originalOffset);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'editor retains input and supports confirmation and saving with the keyboard visible',
    (tester) async {
      final repository = _EditorRepository();
      await _openEditor(tester, repository);
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      tester.view.padding = const FakeViewPadding(top: 54);
      await _frames(tester, 12);
      await tester.enterText(find.byType(TextField).at(0), '新的标题');
      await tester.enterText(find.byType(TextField).at(1), '新的章节正文');
      await tester.tap(find.byTooltip('关闭编辑器'));
      await tester.pumpAndSettle();
      expect(find.text('放弃修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        '新的标题',
      );
      expect(find.text('保存').hitTestable(), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pump();
      // The count worker uses a real isolate, while widget futures use fake time.
      for (
        var attempt = 0;
        attempt < 100 && !repository.savedCounts.isCompleted;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(repository.savedCounts.isCompleted, isTrue);
      await tester.pumpAndSettle();
      expect(repository.saved?.title, '新的标题');
      expect(repository.saved?.content, '新的章节正文');
      expect(find.byType(ChapterEditorSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
