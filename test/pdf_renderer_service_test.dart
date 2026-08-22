import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/services/pdf_renderer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.readvibe.app/pdf_renderer');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('PDF text and outline channel results are validated', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'searchText') {
            return <Map<String, Object>>[
              <String, Object>{
                'pageIndex': 2,
                'snippet': '…搜索结果…',
                'matchedText': '搜索',
                'snippetMatchStart': 1,
                'snippetMatchEnd': 3,
              },
            ];
          }
          if (call.method == 'getOutline') {
            return <Map<String, Object>>[
              <String, Object>{'title': '第一节', 'pageIndex': 4, 'depth': 1},
            ];
          }
          if (call.method == 'getTextAnnotations') {
            return <Map<String, Object>>[
              <String, Object>{
                'pageIndex': 1,
                'annotationId': 'external-note',
                'contents': '已有批注',
              },
            ];
          }
          return null;
        });

    final search = await PdfRendererService.searchText(
      filePath: '/book.pdf',
      query: '搜索',
    );
    final outline = await PdfRendererService.getOutline('/book.pdf');
    final annotations = await PdfRendererService.getTextAnnotations(
      '/book.pdf',
    );

    expect(search.single.pageIndex, 2);
    expect(search.single.snippetMatchStart, 1);
    expect(outline.single.title, '第一节');
    expect(outline.single.pageIndex, 4);
    expect(annotations.single.contents, '已有批注');
  });

  test(
    'PDF password, OCR and embedded note calls use the native channel',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'isPasswordProtected' => true,
              'unlockPdf' => 12,
              'recognizePageText' => '离线识别文字',
              _ => null,
            };
          });

      expect(await PdfRendererService.isPasswordProtected('/book.pdf'), isTrue);
      expect(
        await PdfRendererService.unlockPdf(
          filePath: '/book.pdf',
          password: 'secret',
        ),
        12,
      );
      expect(
        await PdfRendererService.recognizePageText(
          filePath: '/book.pdf',
          pageIndex: 3,
        ),
        '离线识别文字',
      );
      await PdfRendererService.syncTextNote(
        filePath: '/book.pdf',
        pageIndex: 3,
        noteId: 'ReadVibe:test:3',
        contents: '批注',
      );

      expect(
        calls.map((call) => call.method),
        containsAll(<String>[
          'isPasswordProtected',
          'unlockPdf',
          'recognizePageText',
          'syncTextNote',
        ]),
      );
    },
  );

  test('password-protected page count reports a dedicated exception', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getPageCount') {
            throw PlatformException(code: 'PDF_RENDER_FAILED');
          }
          if (call.method == 'isPasswordProtected') return true;
          return null;
        });

    await expectLater(
      PdfRendererService.getPageCount('/protected.pdf'),
      throwsA(isA<PdfPasswordRequiredException>()),
    );
  });
}
