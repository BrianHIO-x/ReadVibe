import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/screens/reader/reader_layout_cache.dart';
import 'package:readvibe/screens/reader/reader_pagination_support.dart';

void main() {
  const chapter = Chapter(index: 0, title: '章', content: '第一段\n第二段');
  SimulationLayoutSignature signature({double width = 320, double font = 20}) =>
      SimulationLayoutSignature(
        contentWidth: width,
        settings: ReaderSettings(fontSize: font),
      );

  test(
    'content invalidation clears paragraph and measurement caches together',
    () {
      final cache = ReaderLayoutCache();
      var measured = 0;
      double measure() => (++measured).toDouble();
      final paragraphs = cache.paragraphs(chapter);
      expect(cache.paragraphs(chapter), same(paragraphs));
      expect(cache.lineExtent(signature(width: 0), measure), 1);
      expect(cache.chapterExtent(chapter, signature(), measure), 2);
      expect(cache.chapterExtent(chapter, signature(), measure), 2);
      cache.clear();
      expect(cache.paragraphs(chapter), isNot(same(paragraphs)));
      expect(cache.lineExtent(signature(width: 0), measure), 3);
      expect(cache.chapterExtent(chapter, signature(), measure), 4);
    },
  );

  test('new font or viewport dimensions cannot reuse stale pagination', () {
    final cache = ReaderLayoutCache();
    var measured = 0;
    double measure() => (++measured).toDouble();
    expect(cache.chapterExtent(chapter, signature(), measure), 1);
    expect(cache.chapterExtent(chapter, signature(width: 360), measure), 2);
    expect(
      cache.chapterExtent(chapter, signature(width: 360, font: 24), measure),
      3,
    );
    expect(
      cache.chapterExtent(chapter, signature(width: 360, font: 24), measure),
      3,
    );
  });
}
