import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/word_count_service.dart';

void main() {
  test('one chapter scan supplies chapter and whole-book counts', () async {
    final book = Book(
      id: 'word_count_once',
      title: '标题不计入正文',
      format: BookFormat.txt,
      chapters: const <Chapter>[
        Chapter(index: 0, title: '第一章', content: '你好 \n😀'),
        Chapter(index: 1, title: '第二章', content: '　A\tB'),
      ],
      importDate: DateTime(2026, 1, 1),
      fileSize: 24,
    );

    final counts = await WordCountService().countChapters(book);

    expect(counts, <int>[3, 2]);
    expect(WordCountService.totalFromChapterCounts(counts), 5);
  });
}
