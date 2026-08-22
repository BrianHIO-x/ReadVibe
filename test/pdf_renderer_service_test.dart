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
          return null;
        });

    final search = await PdfRendererService.searchText(
      filePath: '/book.pdf',
      query: '搜索',
    );
    final outline = await PdfRendererService.getOutline('/book.pdf');

    expect(search.single.pageIndex, 2);
    expect(search.single.snippetMatchStart, 1);
    expect(outline.single.title, '第一节');
    expect(outline.single.pageIndex, 4);
  });
}
