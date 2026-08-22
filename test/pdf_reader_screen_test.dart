import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/screens/pdf_reader_screen.dart';
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
          (message) async => const StandardMessageCodec().encodeMessage(
            <Object?>[null],
          ),
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
}
