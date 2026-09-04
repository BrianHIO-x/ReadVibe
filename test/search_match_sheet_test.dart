import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/models/search_match.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/book_search_sheet.dart';

void main() {
  testWidgets('PDF search keeps a page target without novel coordinates', (
    tester,
  ) async {
    const hit = PdfTextSearchResult(
      pageIndex: 17,
      isOcr: true,
      snippet: '命中文字',
      matchedText: '命中',
      snippetMatchStart: 0,
      snippetMatchEnd: 2,
    );
    PdfTextSearchResult? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookSearchSheet<PdfTextSearchResult>(
            colors: AppTheme.getReaderTheme(ReaderThemeMode.warm),
            onSearch: (_) async => [hit],
            onSelect: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '命中');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('第 18 页 · OCR'), findsOneWidget);
    await tester.tap(find.text('第 18 页 · OCR'));
    expect(selected, same(hit));
    expect(selected!.pageIndex, 17);
  });
}
