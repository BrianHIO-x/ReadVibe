import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/models/search_match.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/book_search_sheet.dart';

void main() {
  testWidgets(
    'search sheet replaces an in-flight keyword without showing stale hits',
    (tester) async {
      final first = Completer<List<PdfTextSearchResult>>();
      final queries = <String>[];
      const hit = PdfTextSearchResult(
        pageIndex: 8,
        snippet: '新结果',
        matchedText: '新',
        snippetMatchStart: 0,
        snippetMatchEnd: 1,
      );
      PdfTextSearchResult? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookSearchSheet<PdfTextSearchResult>(
              colors: AppTheme.getReaderTheme(ReaderThemeMode.warm),
              onSearch: (query) {
                queries.add(query);
                return query == '旧' ? first.future : Future.value([hit]);
              },
              onSelect: (result) => selected = result,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '旧');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.enterText(find.byType(TextField), '新');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      first.complete([
        const PdfTextSearchResult(
          pageIndex: 0,
          snippet: '旧结果',
          matchedText: '旧',
          snippetMatchStart: 0,
          snippetMatchEnd: 1,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(queries, ['旧', '新']);
      expect(find.text('第 1 页'), findsNothing);
      expect(find.text('第 9 页'), findsOneWidget);
      await tester.tap(find.text('第 9 页'));
      expect(selected, same(hit));
      await tester.enterText(find.byType(TextField), '别的词');
      await tester.pump();
      expect(find.text('第 9 页'), findsNothing);
    },
  );
}
