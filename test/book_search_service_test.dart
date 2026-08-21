import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/book_search_service.dart';

void main() {
  final book = Book(
    id: 'search_whitespace',
    title: '搜索样书',
    format: BookFormat.txt,
    chapters: const <Chapter>[
      Chapter(index: 0, title: '第一章', content: '　　开头。\n甲　\t\u00a0乙在这里。\n结尾。'),
    ],
    importDate: DateTime(2026, 1, 1),
    fileSize: 32,
  );

  test(
    'normalized whitespace maps back to the exact highlighted source',
    () async {
      final session = BookSearchService.openSession(book);
      addTearDown(session.dispose);

      final results = await session.search('甲 乙');

      expect(results, hasLength(1));
      final result = results.single;
      expect(result.paragraphIndex, 1);
      expect(result.matchedText, '甲　\t\u00a0乙');
      expect(
        result.snippet.substring(
          result.snippetMatchStart,
          result.snippetMatchEnd,
        ),
        result.matchedText,
      );
    },
  );

  test('one session supports multiple submitted keywords', () async {
    final session = BookSearchService.openSession(book);
    addTearDown(session.dispose);

    expect(await session.search('开头'), hasLength(1));
    expect(await session.search('结尾'), hasLength(1));
  });
}
