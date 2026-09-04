import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/repositories/reader_repositories.dart';
import 'package:readvibe/screens/reader_screen.dart';
import 'package:readvibe/screens/reader/reader_pagination_support.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/app_sheet.dart';

class _Repository implements ReaderRepository {
  @override
  Future<ReaderSettings> getSettings() async => const ReaderSettings(
    theme: ReaderThemeMode.warm,
    readingMode: ReaderReadingMode.simulation,
  );
  @override
  Future<ReadingProgress?> getProgress(String bookId) async => null;
  @override
  Future<void> saveProgress(ReadingProgress progress) async {}
  @override
  Future<Set<String>> getCollapsedTocGroups(String bookId) async => {};
  @override
  Future<void> saveSettings(ReaderSettings settings) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _frames(WidgetTester tester, [int count = 40]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  const channel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  testWidgets(
    'simulation viewport and page offset survive all reader sheets and keyboard insets',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
            channel,
            (_) async =>
                const StandardMessageCodec().encodeMessage(<Object?>[null]),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMessageHandler(channel, null),
      );
      tester.view.physicalSize = const Size(400, 840);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);
      final book = Book(
        id: 'feedback-viewport',
        title: '阅读器弹层',
        format: BookFormat.txt,
        importDate: DateTime(2026),
        fileSize: 10000,
        wordCount: 1000,
        chapterWordCounts: const [1000],
        chapters: [
          Chapter(
            index: 0,
            title: '第一章',
            content: '这是一段仿真阅读正文，用来观察打开面板时页面是否重新排版。\n' * 100,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: ReaderScreen(book: book, repository: _Repository()),
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
      controller.jumpTo(controller.position.viewportDimension);
      await _frames(tester);
      final extent = controller.position.viewportDimension;
      final offset = controller.offset;
      expect(offset, greaterThan(0));
      for (final label in ['目录', '搜索', '设置']) {
        if (find.text(label).hitTestable().evaluate().isEmpty) {
          await tester.tapAt(const Offset(200, 420));
          await _frames(tester);
        }
        await tester.tap(find.text(label).hitTestable());
        await _frames(tester);
        expect(find.byType(AppSheetSurface), findsOneWidget);
        if (label == '搜索') {
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          tester.view.padding = const FakeViewPadding(top: 44);
          await _frames(tester);
        }
        expect(controller.position.viewportDimension, closeTo(extent, 0.1));
        expect(controller.offset, closeTo(offset, 0.1));
        Navigator.of(tester.element(find.byType(AppSheetSurface))).pop();
        tester.view.viewInsets = const FakeViewPadding();
        tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
        await _frames(tester);
        expect(find.byType(AppSheetSurface), findsNothing);
        expect(controller.position.viewportDimension, closeTo(extent, 0.1));
        expect(controller.offset, closeTo(offset, 0.1));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    },
  );
}
