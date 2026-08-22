import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/screens/reader_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wakelockChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          wakelockChannel,
          (message) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockChannel, null);
  });

  testWidgets('novel reader renders content and exposes shared reader tools', (
    tester,
  ) async {
    final book = Book(
      id: 'reader_widget',
      title: '阅读器测试',
      format: BookFormat.txt,
      chapters: const <Chapter>[
        Chapter(index: 0, title: '第一章', content: '　　正文内容'),
      ],
      importDate: DateTime(2026, 1, 1),
      fileSize: 20,
    );

    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('正文内容'), findsWidgets);
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
