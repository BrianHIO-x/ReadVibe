import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/repositories/reader_repositories.dart';
import 'package:readvibe/screens/reader/reader_selection_edge_scroller.dart';
import 'package:readvibe/screens/reader/reader_selectable_block.dart';
import 'package:readvibe/screens/reader_screen.dart';

class _MemoryReaderRepository implements ReaderRepository {
  _MemoryReaderRepository(this.settings);
  final ReaderSettings settings;
  @override
  Future<ReaderSettings> getSettings() async => settings;
  @override
  Future<ReadingProgress?> getProgress(String bookId) async => null;
  @override
  Future<Set<String>> getCollapsedTocGroups(String bookId) async => {};
  @override
  Future<void> saveProgress(ReadingProgress progress) async {}
  @override
  Future<void> saveSettings(ReaderSettings settings) async {}
  @override
  Future<void> saveCollapsedTocGroups(
    String bookId,
    Set<String> groupIds,
  ) async {}
  @override
  Future<void> saveWordCounts(Book book, List<int> counts) async {}
  @override
  Future<void> deleteBook(String bookId) async {}
  @override
  Future<void> replaceChapter(Book book, Chapter chapter) async {}
  @override
  Future<File> saveImportedFont(String sourcePath, String fileName) =>
      throw UnsupportedError('unused');
}

void main() {
  const wakelock =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  String? copiedText;
  setUp(() {
    copiedText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          wakelock,
          (_) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelock, null);
  });

  for (final mode in [
    ReaderReadingMode.chapter,
    ReaderReadingMode.continuous,
  ]) {
    for (final format in [BookFormat.txt, BookFormat.epub]) {
      for (final copyFirst in [true, false]) {
        testWidgets(
          'large real reader selection remains usable in ${mode.name} ${format.name} copy=$copyFirst',
          (tester) async {
            tester.view.physicalSize = const Size(400, 600);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final body =
                'Select words and keep the original anchor while scrolling. ' *
                4;
            final book = Book(
              id: 'large-selection-${mode.name}',
              title: 'Large selection',
              format: format,
              chapters: List.generate(
                10,
                (chapter) => Chapter(
                  index: chapter,
                  title: 'Chapter $chapter',
                  content: List.generate(
                    25,
                    (paragraph) =>
                        'Chapter $chapter paragraph $paragraph: $body',
                  ).join('\n'),
                  epubBlocks: format == BookFormat.epub
                      ? List.generate(
                          25,
                          (paragraph) => EpubContentBlock(
                            kind: EpubContentBlockKind.text,
                            text:
                                'Chapter $chapter paragraph $paragraph: $body',
                          ),
                        )
                      : const [],
                ),
              ),
              importDate: DateTime(2026),
              fileSize: 50000,
              wordCount: 10000,
              chapterWordCounts: List.filled(10, 1000),
            );
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(platform: TargetPlatform.android),
                home: ReaderScreen(
                  book: book,
                  repository: _MemoryReaderRepository(
                    ReaderSettings(
                      readingMode: mode,
                      fontSize: 19,
                      lineHeight: 1.73,
                    ),
                  ),
                ),
              ),
            );
            for (var i = 0; i < 40; i++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            final gesture = await tester.startGesture(const Offset(160, 220));
            await tester.pump(const Duration(milliseconds: 700));
            final area = tester.widget<ReaderSelectionEdgeScroller>(
              find.byType(ReaderSelectionEdgeScroller).first,
            );
            expect(area.selectionActive.value, isTrue);
            final selection = tester
                .widget<SelectionContainer>(
                  find
                      .descendant(
                        of: find.byType(ReaderSelectionEdgeScroller).first,
                        matching: find.byType(SelectionContainer),
                      )
                      .first,
                )
                .delegate!;
            final original = selection.getSelectedContent()!.plainText;
            await gesture.moveTo(const Offset(160, 585));
            for (var i = 0; i < 2200; i++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.takeException(), isNull, reason: 'frame $i');
            }
            await gesture.up();
            await tester.pump(const Duration(milliseconds: 100));
            expect(find.byType(ErrorWidget), findsNothing);
            expect(find.text('复制'), findsOneWidget);
            final edge = tester.widget<ReaderSelectionEdgeScroller>(
              find.byType(ReaderSelectionEdgeScroller).first,
            );
            expect(edge.controller.offset, greaterThan(2000));
            expect(find.text('复制').hitTestable(), findsOneWidget);
            final retainedBlocks = find
                .byType(ReaderSelectableBlock, skipOffstage: false)
                .evaluate()
                .length;
            if (copyFirst) {
              await tester.tap(find.text('复制'));
              await tester.pump();
              expect(tester.takeException(), isNull);
              expect(copiedText, startsWith(original));
              for (var paragraph = 1; paragraph <= 20; paragraph++) {
                expect(copiedText, contains('Chapter 0 paragraph $paragraph:'));
              }
            } else {
              // User reported flow: leave the selection untouched, then swipe the
              // body instead of choosing Copy or explicitly clearing the selection.
              final retainedSelection = selection
                  .getSelectedContent()!
                  .plainText;
              final before = edge.controller.offset;
              final swipe = await tester.startGesture(const Offset(310, 300));
              await swipe.moveBy(const Offset(0, 60));
              await tester.pump(const Duration(milliseconds: 16));
              await swipe.moveBy(const Offset(0, 60));
              await tester.pump(const Duration(milliseconds: 16));
              expect(edge.controller.offset, lessThan(before - 40));
              expect(edge.selectionActive.value, isTrue);
              expect(
                selection.getSelectedContent()!.plainText,
                retainedSelection,
              );
              expect(find.text('复制'), findsNothing);
              await swipe.up();
              await tester.pumpAndSettle();
              expect(copiedText, isNull);
              expect(
                selection.getSelectedContent()!.plainText,
                retainedSelection,
              );
              // Scroll back while retaining the same character range.
              await tester.dragFrom(
                const Offset(310, 400),
                const Offset(0, -100),
              );
              await tester.pumpAndSettle();
              expect(edge.selectionActive.value, isTrue);
              expect(
                selection.getSelectedContent()!.plainText,
                retainedSelection,
              );
              expect(find.text('复制').hitTestable(), findsOneWidget);
              await tester.tap(find.text('复制'));
              await tester.pump();
              expect(copiedText, retainedSelection);
              expect(tester.takeException(), isNull);
            }
            expect(edge.selectionActive.value, isFalse);
            for (var frame = 0; frame < 5; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            if (mode == ReaderReadingMode.chapter) {
              expect(
                find
                    .byType(ReaderSelectableBlock, skipOffstage: false)
                    .evaluate()
                    .length,
                lessThan(retainedBlocks),
              );
            }
            final offset = edge.controller.offset;
            await tester.dragFrom(const Offset(280, 300), const Offset(0, 120));
            await tester.pump(const Duration(milliseconds: 100));
            expect(edge.controller.offset, lessThan(offset));
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 1));
          },
        );
      }
    }
  }
}
