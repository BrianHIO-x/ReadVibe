import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/controllers/private_shelf_controller.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_note.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/services/data_safety_vault_service.dart';
import 'package:readvibe/services/library_backup_service.dart';
import 'package:readvibe/services/private_shelf_lock.dart';
import 'package:readvibe/services/reading_session_store.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:readvibe/theme/app_overlay_theme.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/screens/library_notes_screen.dart';
import 'package:readvibe/widgets/app_dialog.dart';
import 'package:readvibe/widgets/app_segmented_control.dart';
import 'package:readvibe/widgets/app_switch.dart';
import 'package:readvibe/widgets/book_card.dart';
import 'package:readvibe/widgets/chapter_editor_sheet.dart';
import 'package:readvibe/widgets/data_safety_sheet.dart';
import 'package:readvibe/widgets/reader_note_quick_sheet.dart';
import 'package:readvibe/widgets/reader_settings_sheet.dart';
import 'package:readvibe/widgets/vault_directory_picker_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _installChannelMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.readvibe.app/storage_vault'),
    (call) async {
      return switch (call.method) {
        'deviceFreeBytes' => 1024 * 1024 * 1024,
        'allFilesAccessStatus' => <String, Object?>{
          'supported': true,
          'granted': true,
          'rootPath': '/storage/emulated/0',
          'defaultPath': '/storage/emulated/0/Documents',
        },
        'listLocalDirectories' => <String, Object?>{
          'currentPath': '/storage/emulated/0/Documents',
          'parentPath': '/storage/emulated/0',
          'relativePath': 'Documents',
          'displayName': 'Documents',
          'hasVault': false,
          'directories': <Map<String, Object?>>[
            <String, Object?>{
              'path': '/storage/emulated/0/Documents/ReadVibe_Vault',
              'name': 'ReadVibe_Vault',
              'hasVault': true,
            },
          ],
        },
        _ => null,
      };
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.readvibe.app/reader_window'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.readvibe.app/motion'),
    (_) async => false,
  );
}

Widget _harness({
  required Widget child,
  required ReaderThemeColors colors,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: AppTheme.theme,
    builder: (context, inner) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: AppOverlayTheme(colors: colors, child: inner!),
    ),
    home: Scaffold(
      backgroundColor: colors.background,
      body: child,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _installChannelMocks();
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.readvibe.app/storage_vault'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.readvibe.app/reader_window'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.readvibe.app/motion'),
      null,
    );
  });

  testWidgets('key widgets and sheets render with zero overflow across themes & 1.5x text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final themes = <ReaderThemeColors>[
      AppTheme.getReaderTheme(ReaderThemeMode.light),
      AppTheme.getReaderTheme(ReaderThemeMode.warm),
      AppTheme.getReaderTheme(ReaderThemeMode.dark),
      AppTheme.getReaderTheme(ReaderThemeMode.black),
    ];

    final sampleNote = ReaderNote(
      id: 'n1',
      bookId: 'b1',
      chapterIndex: 0,
      chapterTitle: '第一章 这是一个非常非常长的章节标题用来检测宽度截断效果',
      paragraphIndex: 0,
      startOffset: 0,
      endOffset: 10,
      quote: '这是一段很长的划线摘录正文，用来确认卡片和底部快速栏均不溢出。',
      content: '这是对应的读者想法批注内容。',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    final sampleBook = Book(
      id: 'b1',
      title: '书架极长标题测试：即使三列排布也不得与角标文字发生重叠',
      author: '测试作者名称',
      format: BookFormat.epub,
      chapters: const [Chapter(index: 0, title: '第一章', content: '正文')],
      importDate: DateTime(2026),
      wordCount: 12345,
    );

    for (final colors in themes) {
      for (final scale in <double>[1.0, 1.5]) {
        // 1. ReaderSettingsSheet + AppSegmentedControl + AppSwitchTile + BookCard
        await tester.pumpWidget(
          _harness(
            colors: colors,
            textScale: scale,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 104,
                    child: BookCard(
                      book: sampleBook,
                      progress: ReadingProgress(
                        bookId: 'b1',
                        chapterIndex: 0,
                        scrollProgress: 0.42,
                        lastReadDate: DateTime(2026),
                      ),
                      colors: colors,
                      selectionMode: true,
                      selected: false,
                      onTap: () {},
                    ),
                  ),
                  AppSegmentedControl<ReaderThemeMode>(
                    options: const [
                      AppSegmentOption(value: ReaderThemeMode.system, label: '系统'),
                      AppSegmentOption(value: ReaderThemeMode.light, label: '浅色'),
                      AppSegmentOption(value: ReaderThemeMode.warm, label: '暖色'),
                      AppSegmentOption(value: ReaderThemeMode.dark, label: '深色'),
                      AppSegmentOption(value: ReaderThemeMode.black, label: '纯黑'),
                    ],
                    value: ReaderThemeMode.black,
                    colors: colors,
                    variant: AppSegmentedVariant.accent,
                    onChanged: (_) {},
                  ),
                  AppSwitchTile(
                    value: true,
                    onChanged: (_) {},
                    title: const Text('自动检查后台同步并启用防截屏保护'),
                    subtitle: const Text('测试副标题在 1.5x 字号下自动换行'),
                    colors: colors,
                  ),
                  ReaderSettingsSheet(
                    settings: const ReaderSettings(),
                    colors: colors,
                    onChange: (_) {},
                    onImportFont: () async {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);

        // 2. ReaderNoteQuickSheet inside modal route
        await tester.pumpWidget(
          _harness(
            colors: colors,
            textScale: scale,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showReaderNoteQuickSheet(
                  context: context,
                  note: sampleNote,
                  colors: colors,
                  onUpdateAppearance: (_) {},
                ),
                child: const Text('open_quick'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open_quick'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byTooltip('直线'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byTooltip('直线'))).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }
    }

    // 3. VaultDirectoryPickerSheet, DataSafetySheet, LibraryNotesScreen, ChapterEditorSheet
    final darkColors = AppTheme.getReaderTheme(ReaderThemeMode.black);
    final storage = StorageService();
    final vault = DataSafetyVaultService(storage);
    final backup = LibraryBackupService(storage);
    final lock = PrivateShelfLock();
    final privateShelf = PrivateShelfController(
      lock: lock,
      storage: storage,
      sessionStore: ReadingSessionStore(),
      contextProvider: () => null,
      isMounted: () => true,
      isOpeningBook: () => false,
      allBooksProvider: () => [sampleBook],
      colorsProvider: () => darkColors,
      onPrivateModeChanged: (_) {},
      onConfigChanged: () {},
      onReloadLibrary: () async {},
      onMessage: (_) {},
      onError: (_) {},
    );

    await tester.pumpWidget(
      _harness(
        colors: darkColors,
        textScale: 1.5,
        child: Builder(
          builder: (context) => Column(
            children: [
              ElevatedButton(
                onPressed: () => showDataSafetySheet(
                  context,
                  vaultService: vault,
                  backupService: backup,
                  privateShelf: privateShelf,
                  colors: darkColors,
                  onRestored: () async {},
                ),
                child: const Text('open_safety'),
              ),
              ElevatedButton(
                onPressed: () => showVaultDirectoryPickerSheet(
                  context,
                  privateShelf: privateShelf,
                  colors: darkColors,
                ),
                child: const Text('open_vault_dir'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('open_safety'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.byType(AppSegmentedControl<int>))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    await tester.tap(find.text('open_vault_dir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Documents').first)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    vault.dispose();
    privateShelf.dispose();

    await tester.pumpWidget(
      _harness(
        colors: darkColors,
        textScale: 1.35,
        child: LibraryNotesScreen(
          storage: storage,
          books: [sampleBook],
          colors: darkColors,
          privateMode: false,
          onOpenNote: (_, _) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      _harness(
        colors: darkColors,
        child: ChapterEditorSheet(
          initialTitle: '第一章 编辑标题',
          initialContent: '这是编辑测试正文。\n第二段内容。',
          hasRichContent: false,
          colors: darkColors,
          onSave: (_, _) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('PDF password dialog unlock button stays disabled until password is entered', (
    tester,
  ) async {
    final colors = AppTheme.getReaderTheme(ReaderThemeMode.warm);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? submitted;

    await tester.pumpWidget(
      _harness(
        colors: colors,
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              showAppDialog<String>(
                context: context,
                colors: colors,
                builder: (dialogContext) => AppDialog(
                  title: const Text('需要 PDF 密码'),
                  content: TextField(controller: controller),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('取消'),
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (_, value, _) => FilledButton(
                        onPressed: value.text.trim().isEmpty
                            ? null
                            : () {
                                submitted = value.text;
                                Navigator.of(dialogContext).pop(value.text);
                              },
                        child: const Text('解锁并导入'),
                      ),
                    ),
                  ],
                ),
              );
            },
            child: const Text('ask_pdf_pw'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('ask_pdf_pw'));
    await tester.pumpAndSettle();
    final disabledButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '解锁并导入'),
    );
    expect(disabledButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'secret123');
    await tester.pump();
    final enabledButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '解锁并导入'),
    );
    expect(enabledButton.onPressed, isNotNull);

    await tester.tap(find.text('解锁并导入'));
    await tester.pumpAndSettle();
    expect(submitted, 'secret123');
  });
}
