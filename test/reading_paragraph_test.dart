import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reading_paragraph.dart';
import 'package:readvibe/services/book_search_service.dart';
import 'package:readvibe/services/storage/chapter_payload_codec.dart';

void main() {
  test('plain text uses one paragraph order and stable reader prefixes', () {
    const chapter = Chapter(
      index: 0,
      title: '章',
      content: '\r\n　 第一段  \n\n\t第二段\r第三段',
    );
    final paragraphs = readingParagraphs(chapter).toList();
    expect(paragraphs.map((p) => p.body), ['第一段', '第二段', '第三段']);
    expect(paragraphs.map((p) => p.displayText), ['　　第一段', '　　第二段', '　　第三段']);
  });

  test(
    'rich headings, empty blocks and images share search coordinates',
    () async {
      const chapter = Chapter(
        index: 0,
        title: '标题',
        content: '正文',
        epubBlocks: [
          EpubContentBlock(
            kind: EpubContentBlockKind.image,
            imagePath: 'cover.png',
          ),
          EpubContentBlock(
            kind: EpubContentBlockKind.text,
            text: '标题',
            isHeading: true,
            style: EpubContentStyle(textIndentEm: 0),
          ),
          EpubContentBlock(kind: EpubContentBlockKind.text, text: '　 '),
          EpubContentBlock(
            kind: EpubContentBlockKind.text,
            text: '\t这是　　关键词  ',
            style: EpubContentStyle(textIndentEm: 3),
          ),
        ],
      );
      final restored = decodeChapterPayload(encodeChapterPayload(chapter), 0);
      final paragraphs = readingParagraphs(restored).toList();
      expect(paragraphs.map((p) => p.body), ['标题', '这是　　关键词']);
      expect(paragraphs[1].prefix, '　　　');
      final book = Book(
        id: 'projected',
        title: '书',
        format: BookFormat.epub,
        chapters: [restored],
        importDate: DateTime(2026),
      );
      final result = (await BookSearchService.search(book, '关键词')).single;
      expect(result.paragraphIndex, 1);
      expect(
        paragraphs[result.paragraphIndex].body.substring(
          result.characterOffset,
        ),
        '关键词',
      );
      expect(restored.hasSemanticHeading, isTrue);
      expect(encodeChapterPayload(restored), encodeChapterPayload(chapter));
    },
  );

  test('chapter codec rejects invalid data before creating a document', () {
    expect(
      () => decodeChapterPayload({'title': 1, 'content': '文'}, 0),
      throwsFormatException,
    );
    expect(() => decodeChapterPayload(null, 0), throwsFormatException);
  });
}
