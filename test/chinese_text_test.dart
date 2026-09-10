import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/book_search_service.dart';
import 'package:readvibe/services/chinese_text.dart';

Book _book(String content) => Book(
  id: 'zh',
  title: '折叠测试',
  format: BookFormat.txt,
  chapters: [Chapter(index: 0, title: '第一章', content: content)],
  importDate: DateTime(2026),
  fileSize: content.length,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full-width ASCII forms fold onto their half-width counterparts', () {
    expect(foldFullWidth('１２３'), '123');
    expect(foldFullWidth('ＡＢｃ'), 'ABc');
    expect(foldFullWidth('（第５章）：？！'), '(第5章):?!');
    expect(foldFullWidth('第五章'), '第五章');
  });

  test('Chinese punctuation outside the mirrored block keeps its identity', () {
    // These are Chinese marks in their own right, not wide ASCII.
    expect(foldFullWidth('他说。然后、走了'), '他说。然后、走了');
  });

  test('folding preserves rune count so highlights stay aligned', () {
    const source = 'ＡＢ１２（）';
    expect(foldFullWidth(source).runes.length, source.runes.length);
  });

  test('a half-width query finds full-width body text', () async {
    final results = await BookSearchService.search(
      _book('　　第（５）节的开头，接着是正文。'),
      '(5)',
    );

    expect(results, hasLength(1));
    final match = results.single;
    // The highlight must point at the full-width characters in the source.
    expect(
      match.snippet.substring(match.snippetMatchStart, match.snippetMatchEnd),
      '（５）',
    );
  });

  test('a full-width query finds half-width body text', () async {
    final results = await BookSearchService.search(
      _book('　　章节编号 (5) 出现在这里。'),
      '（５）',
    );

    expect(results, hasLength(1));
    final match = results.single;
    expect(
      match.snippet.substring(match.snippetMatchStart, match.snippetMatchEnd),
      '(5)',
    );
  });
}
