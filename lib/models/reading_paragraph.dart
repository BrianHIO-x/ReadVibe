import 'book.dart';

final _leadingWhitespace = RegExp(r'^[\s　]+');
final _paragraphBreak = RegExp(r'(?:\r\n?|\n)+');

String visibleParagraphBody(String text) =>
    text.replaceFirst(_leadingWhitespace, '').trimRight();

String richParagraphPrefix(EpubContentBlock block) => List<String>.filled(
  block.style.textIndentEm.round().clamp(0, 8),
  '　',
).join();

class ReadingParagraph {
  const ReadingParagraph({required this.body, required this.prefix});
  final String body;
  final String prefix;
  String get displayText => '$prefix$body';
}

/// Shared paragraph ordering for reader rendering and search coordinates.
/// Headings participate exactly like other visible text blocks.
Iterable<ReadingParagraph> readingParagraphs(Chapter chapter) sync* {
  if (chapter.hasRichEpubContent) {
    for (final block in chapter.epubBlocks) {
      if (!block.isText) continue;
      final body = visibleParagraphBody(block.text);
      if (body.isNotEmpty) {
        yield ReadingParagraph(body: body, prefix: richParagraphPrefix(block));
      }
    }
  } else {
    for (final raw in chapter.content.split(_paragraphBreak)) {
      final body = visibleParagraphBody(raw);
      if (body.isNotEmpty) {
        yield ReadingParagraph(body: body, prefix: '　　');
      }
    }
  }
}
