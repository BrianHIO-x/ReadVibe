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

/// Maps a reading-paragraph coordinate back onto [Chapter.content] so the
/// chapter editor can open on the line the reader was looking at.
///
/// Reading paragraphs drop blank runs and strip indentation, so their indices
/// do not line up with raw offsets. Walking the bodies in order and searching
/// forward from the previous match keeps the mapping exact for plain chapters
/// and best-effort for rich EPUB ones, where the flattened text still carries
/// the same bodies in the same order. Returns null when the paragraph cannot
/// be located.
int? contentOffsetForReadingParagraph(
  Chapter chapter,
  int paragraphIndex,
  int bodyOffset,
) {
  if (paragraphIndex < 0 || bodyOffset < 0) return null;
  final content = chapter.content;
  if (content.isEmpty) return null;
  var cursor = 0;
  var index = 0;
  for (final paragraph in readingParagraphs(chapter)) {
    if (paragraph.body.isEmpty) continue;
    final start = content.indexOf(paragraph.body, cursor);
    if (start < 0) return null;
    if (index == paragraphIndex) {
      return (start + bodyOffset).clamp(0, content.length);
    }
    cursor = start + paragraph.body.length;
    index++;
  }
  return null;
}
