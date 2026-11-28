import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/controllers/reader_window_controller.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_bookmark.dart';
import 'package:readvibe/models/reader_note.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/repositories/reader_repositories.dart';
import 'package:readvibe/screens/reader_screen.dart';
import 'package:readvibe/services/storage/chapter_disk_store.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryReaderRepository implements ReaderRepository {
  _MemoryReaderRepository({
    required ReaderSettings initialSettings,
    ReadingProgress? initialProgress,
  }) : settings = initialSettings,
       progress = initialProgress;

  ReaderSettings settings;
  ReadingProgress? progress;
  final List<ReaderBookmark> bookmarks = <ReaderBookmark>[];
  final List<ReaderNote> notes = <ReaderNote>[];
  final Set<String> collapsedToc = <String>{};

  @override
  Future<ReaderSettings> getSettings() async => settings;

  @override
  Future<void> saveSettings(ReaderSettings value) async {
    settings = value;
  }

  @override
  Future<ReadingProgress?> getProgress(String bookId) async => progress;

  @override
  Future<void> saveProgress(ReadingProgress value) async {
    progress = value;
  }

  @override
  Future<List<ReaderBookmark>> getBookmarks(String bookId) async =>
      List<ReaderBookmark>.of(bookmarks);

  @override
  Future<void> saveBookmarks(String bookId, List<ReaderBookmark> value) async {
    bookmarks
      ..clear()
      ..addAll(value);
  }

  @override
  Future<List<ReaderNote>> getNotes(
    String bookId, {
    bool isPdf = false,
    int? pdfPageCount,
  }) async => List<ReaderNote>.of(notes);

  @override
  Future<void> saveNotes(String bookId, List<ReaderNote> value) async {
    notes
      ..clear()
      ..addAll(value);
  }

  @override
  Future<Set<String>> getCollapsedTocGroups(String bookId) async =>
      Set<String>.of(collapsedToc);

  @override
  Future<void> saveCollapsedTocGroups(
    String bookId,
    Set<String> groupIds,
  ) async {
    collapsedToc
      ..clear()
      ..addAll(groupIds);
  }

  @override
  Future<void> saveWordCounts(
    Book sourceBook,
    List<int> chapterWordCounts,
  ) async {}

  @override
  Future<Book> replaceChapter(Book sourceBook, Chapter replacement) async =>
      sourceBook;

  @override
  Future<File> saveImportedFont(String sourcePath, String fileName) async =>
      File(sourcePath);

  @override
  Future<void> deleteBook(String bookId) async {}
}

void _installMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.readvibe.app/reader_window'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.readvibe.app/motion'),
    (_) async => false,
  );
}

Future<void> _flushIsolatesAndFrames(WidgetTester tester, {int ticks = 8}) async {
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

double _activeScrollOffset(WidgetTester tester) {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  return state.position.pixels;
}

double _activeViewportExtent(WidgetTester tester) {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  return state.position.viewportDimension;
}

Future<void> _waitForReaderReady(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(Scrollable).evaluate().isNotEmpty) {
      break;
    }
  }
  await _flushIsolatesAndFrames(tester, ticks: 6);
  expect(find.byType(Scrollable), findsAtLeastNWidgets(1));
}

Future<void> _settle(WidgetTester tester, {int steps = 16}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

bool _isOverlayBarVisible(WidgetTester tester) {
  final settingsFinder = find.text('设置');
  if (settingsFinder.evaluate().isEmpty) return false;
  return tester.getCenter(settingsFinder.first).dy < 795;
}

Future<void> _openSettings(WidgetTester tester) async {
  if (!_isOverlayBarVisible(tester)) {
    await tester.tapAt(const Offset(180, 400));
    await _settle(tester, steps: 10);
  }
  await tester.tap(find.text('设置'));
  await tester.pump();
  await _settle(tester, steps: 12);
}

Future<void> _tapSettingChip(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(target);
  await _flushIsolatesAndFrames(tester, ticks: 8);
}

Future<void> _closeSettings(WidgetTester tester) async {
  // Tap top barrier area above sheet (top 15% of 800dp screen).
  await tester.tapAt(const Offset(180, 60));
  await tester.pump();
  await _settle(tester, steps: 10);
  // Dismiss reader overlay if still visible.
  if (_isOverlayBarVisible(tester)) {
    await tester.tapAt(const Offset(180, 400));
    await _settle(tester, steps: 8);
  }
  await _flushIsolatesAndFrames(tester, ticks: 4);
}

Future<void> _unmountAndDrainTimers(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pump(const Duration(seconds: 3));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    ReaderWindowController.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    _installMocks();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.readvibe.app/reader_window'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.readvibe.app/motion'),
      null,
    );
  });

  testWidgets('1500-chapter continuous scroll mounts bounded window & switches modes without freeze', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    late Directory tempDir;
    late List<Chapter> lazyChapters;
    await tester.runAsync(() async {
      tempDir = Directory.systemTemp.createTempSync('readvibe_1500ch_');
      final store = ChapterDiskStore(
        () async => tempDir,
        <T>(fn) => fn(),
        <T>(_, fn) => fn(),
        (_) => false,
      );
      final raw = List<Chapter>.generate(
        1500,
        (i) => Chapter(
          index: i,
          title: '第 ${i + 1} 章 测试章节',
          content: List<String>.filled(
            6,
            '这是第 ${i + 1} 章的正文段落，用来测试长篇小说在连续滚动模式下的懒加载窗口、滑动性能与模式切换流畅性。',
          ).join('\n'),
        ),
        growable: false,
      );
      await store.saveChapters('book_1500', raw);
      final dir = await store.chapterDirectory('book_1500');
      lazyChapters = await store.loadChapterDirectory(dir);
    });
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final book = Book(
      id: 'book_1500',
      title: '一千五百章长篇',
      format: BookFormat.txt,
      chapters: lazyChapters,
      importDate: DateTime(2026),
      wordCount: 500000,
      chapterWordCounts: List<int>.filled(1500, 300),
    );
    final repo = _MemoryReaderRepository(
      initialSettings: const ReaderSettings(
        readingMode: ReaderReadingMode.continuous,
        fontSize: 20,
      ),
      initialProgress: ReadingProgress(
        bookId: book.id,
        chapterIndex: 20,
        scrollOffset: 0,
        scrollProgress: 0,
        lastReadDate: DateTime(2026),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.theme,
        home: ReaderScreen(book: book, repository: repo),
      ),
    );
    await _waitForReaderReady(tester);

    // Mounted window must be tiny (bounded sliding window, never 1500).
    final initialGroups = tester
        .widgetList<SliverMainAxisGroup>(find.byType(SliverMainAxisGroup))
        .length;
    expect(initialGroups, lessThanOrEqualTo(6));
    expect(find.byType(CustomScrollView), findsOneWidget);

    // Scroll downward repeatedly across several chapters.
    for (var step = 0; step < 6; step++) {
      await tester.dragFrom(
        const Offset(180, 650),
        const Offset(0, -500),
      );
      await _flushIsolatesAndFrames(tester, ticks: 8);
    }
    await tester.pump(const Duration(milliseconds: 600));

    final scrolledGroups = tester
        .widgetList<SliverMainAxisGroup>(find.byType(SliverMainAxisGroup))
        .length;
    expect(scrolledGroups, lessThanOrEqualTo(8));
    expect(repo.progress?.chapterIndex, greaterThan(20));

    // Switch Continuous -> Simulation -> Chapter -> Continuous smoothly.
    await _openSettings(tester);
    await _tapSettingChip(tester, '仿真');
    await _tapSettingChip(tester, '分章');
    await _tapSettingChip(tester, '滚动');
    await _closeSettings(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(CustomScrollView), findsOneWidget);

    await _unmountAndDrainTimers(tester);
  });

  testWidgets('zero drift in Simulation, Chapter, and Continuous modes across weight/size/margin/blank-line/mode roundtrips', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 45 medium paragraphs ensure multi-page pagination even at max viewport height.
    final chapter = Chapter(
      index: 0,
      title: '第 1 章 锚点回归',
      content: List<String>.generate(
        45,
        (i) =>
            '第${i + 1}段：海风吹拂着古老石桥的栏杆，少年停下脚步倾听远方钟声回荡在夜空之中，每一个字符都用来验证翻页与字号排版零漂移。',
      ).join('\n'),
    );
    final book = Book(
      id: 'anchor_plain',
      title: '锚点测试书',
      format: BookFormat.txt,
      chapters: [chapter],
      importDate: DateTime(2026),
      wordCount: 3000,
      chapterWordCounts: const [3000],
    );

    // 1) Simulation Mode Page 3 (with none spacing AND blankLine spacing)
    for (final initialSpacing in [
      ReaderParagraphSpacing.none,
      ReaderParagraphSpacing.blankLine,
    ]) {
      final repo = _MemoryReaderRepository(
        initialSettings: ReaderSettings(
          readingMode: ReaderReadingMode.simulation,
          simulationPageTurnEffect: SimulationPageTurnEffect.smooth,
          paragraphSpacing: initialSpacing,
          fontSize: 20,
          lineHeight: 1.8,
          pageMargin: ReaderPageMargin.medium,
          fontWeight: ReaderFontWeight.regular,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: ReaderScreen(book: book, repository: repo),
        ),
      );
      await _waitForReaderReady(tester);

      // Turn 2 pages forward (onto Page 3).
      for (var turn = 0; turn < 2; turn++) {
        await tester.flingFrom(
          const Offset(320, 400),
          const Offset(-240, 0),
          1200,
        );
        await _settle(tester, steps: 16);
      }

      final pageExtent = _activeViewportExtent(tester);
      final baselineOffset = _activeScrollOffset(tester);
      expect(baselineOffset, greaterThan(pageExtent * 1.5));

      await _openSettings(tester);
      await _tapSettingChip(tester, '粗');
      await _tapSettingChip(tester, '细');
      await _tapSettingChip(tester, '24');
      await _tapSettingChip(tester, '16');
      await _tapSettingChip(tester, '宽');
      await _tapSettingChip(tester, '窄');
      await _tapSettingChip(
        tester,
        initialSpacing == ReaderParagraphSpacing.none ? '空一行' : '不空行',
      );
      await _tapSettingChip(tester, '分章');
      await _tapSettingChip(tester, '滚动');
      // Restore all settings without moving pages
      await _tapSettingChip(tester, '中'); // matches first '中' or ensure fontWeight/margin
      await _tapSettingChip(tester, '20');
      await _tapSettingChip(
        tester,
        initialSpacing == ReaderParagraphSpacing.none ? '不空行' : '空一行',
      );
      await _tapSettingChip(tester, '仿真');
      // Also restore FontWeight + PageMargin specifically by tapping exact segmented controls
      final segmentedControls = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .toList();
      expect(segmentedControls, isNotEmpty);
      // Both fontWeight ('细'/'中'/'粗') and pageMargin ('窄'/'中'/'宽') share label '中':
      final mediumButtons = find.text('中');
      for (var m = 0; m < mediumButtons.evaluate().length; m++) {
        await tester.ensureVisible(mediumButtons.at(m));
        await tester.tap(mediumButtons.at(m));
        await _flushIsolatesAndFrames(tester, ticks: 6);
      }
      await _closeSettings(tester);

      final restoredOffset = _activeScrollOffset(tester);
      expect(
        (restoredOffset - baselineOffset).abs(),
        lessThanOrEqualTo(0.5),
        reason:
            'Simulation drift for $initialSpacing: baseline=$baselineOffset restored=$restoredOffset',
      );
      expect(tester.takeException(), isNull);
      await _unmountAndDrainTimers(tester);
    }

    // 2) Continuous Mode mid-chapter zero drift across mode/font roundtrip
    final continuousRepo = _MemoryReaderRepository(
      initialSettings: const ReaderSettings(
        readingMode: ReaderReadingMode.continuous,
        fontSize: 20,
        lineHeight: 1.8,
        pageMargin: ReaderPageMargin.medium,
        fontWeight: ReaderFontWeight.regular,
        paragraphSpacing: ReaderParagraphSpacing.none,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.theme,
        home: ReaderScreen(book: book, repository: continuousRepo),
      ),
    );
    await _waitForReaderReady(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -450));
    await _flushIsolatesAndFrames(tester, ticks: 6);
    final continuousBaseline = _activeScrollOffset(tester);
    expect(continuousBaseline, greaterThan(200));

    await _openSettings(tester);
    await _tapSettingChip(tester, '24');
    await _tapSettingChip(tester, '分章');
    await _tapSettingChip(tester, '仿真');
    await _tapSettingChip(tester, '20');
    await _tapSettingChip(tester, '滚动');
    await _closeSettings(tester);

    final continuousRestored = _activeScrollOffset(tester);
    final lineExtent =
        continuousRepo.settings.fontSize * continuousRepo.settings.lineHeight;
    expect(
      (continuousRestored - continuousBaseline).abs(),
      lessThan(lineExtent),
      reason:
          'Continuous stayed on the same reading line: baseline=$continuousBaseline restored=$continuousRestored',
    );
    // Repeated roundtrip from a line-aligned offset must have zero pixel drift.
    await _openSettings(tester);
    await _tapSettingChip(tester, '粗');
    await _tapSettingChip(tester, '宽');
    await _tapSettingChip(tester, '仿真');
    await _tapSettingChip(tester, '滚动');
    final mediumButtons = find.text('中');
    for (var m = 0; m < mediumButtons.evaluate().length; m++) {
      await tester.ensureVisible(mediumButtons.at(m));
      await tester.tap(mediumButtons.at(m));
      await _flushIsolatesAndFrames(tester, ticks: 6);
    }
    await _closeSettings(tester);
    final continuousSecondRestored = _activeScrollOffset(tester);
    expect(
      (continuousSecondRestored - continuousRestored).abs(),
      lessThanOrEqualTo(0.5),
      reason:
          'Continuous aligned roundtrip drift: first=$continuousRestored second=$continuousSecondRestored',
    );
    await _unmountAndDrainTimers(tester);

    // 3) Rich EPUB chapter (with heading, padded highlight background block, multi-line body)
    final epubBlocks = <EpubContentBlock>[
      const EpubContentBlock(
        kind: EpubContentBlockKind.text,
        text: '第一章 富文本测试',
        isHeading: true,
        style: EpubContentStyle(
          fontScale: 1.4,
          fontWeight: 700,
          textIndentEm: 0,
          marginBottomEm: 0.6,
        ),
      ),
      const EpubContentBlock(
        kind: EpubContentBlockKind.text,
        text: '这是一段带有背景填充色和内边距的引言区块，用以确认 innerPadTop 的往返计算精准无漂移。'
            '即使跨行显示也不会在切换阅读模式或字号之后退回上一页。',
        style: EpubContentStyle(
          textIndentEm: 0,
          backgroundColorArgb: 0xFFF2ECE1,
          marginTopEm: 0.3,
          marginBottomEm: 0.4,
        ),
      ),
      for (var i = 0; i < 36; i++)
        EpubContentBlock(
          kind: EpubContentBlockKind.text,
          text:
              '第 ${i + 1} 段 EPUB 富文本连续行文：夜幕低垂，远方的灯火闪烁不定，读者正在检验跨模式切换零偏移稳定性。',
          style: const EpubContentStyle(textIndentEm: 2),
        ),
    ];
    final epubBook = Book(
      id: 'anchor_epub',
      title: 'EPUB 锚点测试',
      format: BookFormat.epub,
      chapters: [
        Chapter(
          index: 0,
          title: '第一章 富文本测试',
          content: epubBlocks.map((b) => b.text).join('\n'),
          epubBlocks: epubBlocks,
          hasSemanticHeading: true,
        ),
      ],
      importDate: DateTime(2026),
      wordCount: 3000,
      chapterWordCounts: const [3000],
    );
    final epubRepo = _MemoryReaderRepository(
      initialSettings: const ReaderSettings(
        readingMode: ReaderReadingMode.simulation,
        simulationPageTurnEffect: SimulationPageTurnEffect.smooth,
        fontSize: 20,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.theme,
        home: ReaderScreen(book: epubBook, repository: epubRepo),
      ),
    );
    await _waitForReaderReady(tester);
    await tester.flingFrom(
      const Offset(320, 400),
      const Offset(-240, 0),
      1200,
    );
    await _settle(tester, steps: 16);
    final epubBaseline = _activeScrollOffset(tester);
    expect(epubBaseline, greaterThan(100));

    await _openSettings(tester);
    await _tapSettingChip(tester, '分章');
    await _tapSettingChip(tester, '滚动');
    await _tapSettingChip(tester, '仿真');
    await _closeSettings(tester);

    final epubRestored = _activeScrollOffset(tester);
    expect(
      (epubRestored - epubBaseline).abs(),
      lessThanOrEqualTo(0.5),
      reason: 'EPUB roundtrip drift: baseline=$epubBaseline restored=$epubRestored',
    );
    expect(tester.takeException(), isNull);
    await _unmountAndDrainTimers(tester);
  });
}
