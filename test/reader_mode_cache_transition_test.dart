import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/repositories/reader_repositories.dart';
import 'package:readvibe/screens/reader_screen.dart';
import 'package:readvibe/screens/reader/reader_pagination_support.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/reader_settings_sheet.dart';

class _Repository implements ReaderRepository {
  ReadingProgress? saved;
  @override
  Future<ReaderSettings> getSettings() async => const ReaderSettings();
  @override
  Future<ReadingProgress?> getProgress(String bookId) async => saved;
  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    saved = progress;
  }

  @override
  Future<Set<String>> getCollapsedTocGroups(String bookId) async => {};
  @override
  Future<void> saveSettings(ReaderSettings settings) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

ScrollController _readerScroll(WidgetTester tester) {
  final view = tester.widget<ScrollView>(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is ScrollView &&
              widget.controller is SelectionAwareScrollController,
        )
        .first,
  );
  return view.controller!;
}

List<int> _visibleParagraphs(WidgetTester tester) {
  final scroll = find
      .byWidgetPredicate(
        (widget) =>
            widget is ScrollView &&
            widget.controller is SelectionAwareScrollController,
      )
      .first;
  final viewport = tester.getRect(scroll);
  final paragraphs = find.descendant(
    of: scroll,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Text && RegExp(r'段落\d+').hasMatch(widget.data ?? ''),
    ),
  );
  final visible = <int>[];
  for (var i = 0; i < paragraphs.evaluate().length; i++) {
    final paragraph = paragraphs.at(i);
    final text = tester.widget<Text>(paragraph).data!;
    final richText = find.descendant(
      of: paragraph,
      matching: find.byType(RichText),
    );
    final render = tester.renderObject<RenderParagraph>(richText.first);
    final origin = render.localToGlobal(Offset.zero);
    for (final match in RegExp(r'段落(\d+)[^\n]*').allMatches(text)) {
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      if (boxes.any(
        (box) => box.toRect().shift(origin).intersect(viewport).height > 1,
      )) {
        visible.add(int.parse(match.group(1)!));
      }
    }
  }
  return visible..sort();
}

void main() {
  testWidgets(
    'font changes and all mode transitions restore the reading position',
    (tester) async {
      const channel =
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(
        channel,
        (_) async =>
            const StandardMessageCodec().encodeMessage(<Object?>[null]),
      );
      addTearDown(() => messenger.setMockMessageHandler(channel, null));
      tester.view.physicalSize = const Size(400, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      final book = Book(
        id: 'mode-cache',
        title: '阅读',
        format: BookFormat.txt,
        importDate: DateTime(2026),
        wordCount: 1000,
        chapterWordCounts: const [1000],
        chapters: [
          Chapter(
            index: 0,
            title: '第一章',
            content: List.generate(
              100,
              (index) => '段落$index，这是验证字体和模式切换时阅读位置保持的正文。',
            ).join('\n'),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: ReaderScreen(book: book, repository: repository),
        ),
      );
      await _frames(tester);
      _readerScroll(tester).jumpTo(1500);
      await _frames(tester);
      final initialRatio = repository.saved!.scrollProgress;
      expect(initialRatio, greaterThan(0.05));
      for (final mode in [
        ReaderReadingMode.simulation,
        ReaderReadingMode.continuous,
        ReaderReadingMode.chapter,
      ]) {
        final visibleBefore = _visibleParagraphs(tester);
        expect(visibleBefore, isNotEmpty);
        if (find.text('设置').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(const Offset(200, 420));
          await _frames(tester);
        }
        await tester.tap(find.text('设置').hitTestable());
        await _frames(tester);
        final sheet = tester.widget<ReaderSettingsSheet>(
          find.byType(ReaderSettingsSheet),
        );
        sheet.onChange(
          sheet.settings.copyWith(
            readingMode: mode,
            fontSize: mode == ReaderReadingMode.chapter ? 20 : 24,
          ),
        );
        await _frames(tester);
        Navigator.of(tester.element(find.byType(ReaderSettingsSheet))).pop();
        await _frames(tester);
        final scroll = _readerScroll(tester);
        expect(scroll.hasClients, isTrue);
        expect(scroll.offset, greaterThan(0));
        expect(repository.saved!.chapterIndex, 0);
        final visibleAfter = _visibleParagraphs(tester);
        expect(
          visibleAfter,
          contains(visibleBefore.first),
          reason: 'Mode $mode: before $visibleBefore, after $visibleAfter',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    },
  );
}
