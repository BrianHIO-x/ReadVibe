import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/screens/pdf_reader_screen.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/app_dialog.dart';
import 'package:readvibe/widgets/app_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const rendererChannel = MethodChannel('com.readvibe.app/pdf_renderer');
  const wakelockChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

  late Directory tempDirectory;
  late File source;
  late File renderedPage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDirectory = Directory.systemTemp.createTempSync('readvibe_pdf_widget_');
    source = File('${tempDirectory.path}/source.pdf')
      ..writeAsBytesSync(<int>[1]);
    renderedPage = File('${tempDirectory.path}/page.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(rendererChannel, (call) async {
          if (call.method == 'renderPage') return renderedPage.path;
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          wakelockChannel,
          (message) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(rendererChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockChannel, null);
    try {
      if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
    } on FileSystemException {
      // Image decoding can retain a Windows file handle briefly.
    }
  });

  testWidgets('PDF reader exposes page progress, jump and bookmarks', (
    tester,
  ) async {
    final book = Book(
      id: 'pdf_widget',
      title: 'PDF 测试',
      format: BookFormat.pdf,
      chapters: const <Chapter>[],
      pageCount: 3,
      sourcePath: source.path,
      importDate: DateTime(2026, 1, 1),
    );

    await tester.pumpWidget(MaterialApp(home: PdfReaderScreen(book: book)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(Slider).evaluate().isNotEmpty) break;
    }

    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byTooltip('添加书签'), findsOneWidget);

    await tester.tap(find.byTooltip('添加书签'));
    await tester.pump();
    expect(find.byTooltip('取消书签'), findsOneWidget);
  });
  for (final display in PdfDisplayTheme.values) {
    testWidgets('PDF jump, note and bookmarks follow ${display.name}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'readvibe_pdf_display_theme_pdf_prompts': display.name,
      });
      final colors = AppTheme.getReaderTheme(switch (display) {
        PdfDisplayTheme.original => ReaderThemeMode.light,
        PdfDisplayTheme.paper => ReaderThemeMode.warm,
        PdfDisplayTheme.dark => ReaderThemeMode.dark,
      });
      final book = Book(
        id: 'pdf_prompts',
        title: 'PDF',
        format: BookFormat.pdf,
        chapters: const [],
        pageCount: 3,
        sourcePath: source.path,
        importDate: DateTime(2026),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: PdfReaderScreen(book: book),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 / 3'));
      await tester.pumpAndSettle();
      final title = tester.widget<Text>(find.text('跳转页码'));
      final theme = Theme.of(tester.element(find.byType(AppDialog)));
      expect(theme.dialogTheme.backgroundColor, colors.headerBg);
      expect(
        title.style?.color ?? theme.dialogTheme.titleTextStyle!.color,
        colors.text,
      );
      await tester.enterText(find.byType(TextField), '2');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(find.byTooltip('添加笔记'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      final noteTheme = Theme.of(tester.element(find.byType(AppDialog)));
      expect(noteTheme.dialogTheme.backgroundColor, colors.headerBg);
      expect(
        field.decoration!.hintStyle?.color ??
            noteTheme.inputDecorationTheme.hintStyle!.color,
        colors.secondary,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('书签列表'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppSheetSurface>(find.byType(AppSheetSurface))
            .colors
            .headerBg,
        colors.headerBg,
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
