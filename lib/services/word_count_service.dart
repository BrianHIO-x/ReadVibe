import 'dart:async';
import 'dart:isolate';

import '../models/book.dart';

/// Counts visible Unicode characters in a book without blocking the UI isolate.
///
/// Whitespace and paragraph separators are excluded. A Unicode scalar value is
/// counted once, so supplementary-plane characters are not double-counted as
/// two UTF-16 code units.
class WordCountService {
  static final Map<String, List<int>> _chapterCountCache =
      <String, List<int>>{};
  static final Map<String, Future<List<int>>> _chapterCountsInFlight =
      <String, Future<List<int>>>{};

  /// Counts each chapter body independently without blocking the UI isolate.
  ///
  /// Chapter titles are metadata and are intentionally excluded. Completed
  /// results stay in memory so reopening the directory does not rescan a large
  /// book during the same app session.
  Future<List<int>> countChapters(Book book) {
    final stored = book.chapterWordCounts;
    if (stored != null && stored.length == book.chapters.length) {
      return Future<List<int>>.value(stored);
    }

    final cacheKey = _chapterCacheKey(book);
    final cached = _chapterCountCache[cacheKey];
    if (cached != null) return Future<List<int>>.value(cached);

    final existing = _chapterCountsInFlight[cacheKey];
    if (existing != null) return existing;

    final contents = <String>[
      for (final chapter in book.chapters) chapter.content,
    ];
    late final Future<List<int>> operation;
    operation = Isolate.run(() => _countVisibleRunesByEntry(contents))
        .then((counts) {
          final immutableCounts = List<int>.unmodifiable(counts);
          _chapterCountCache[cacheKey] = immutableCounts;
          return immutableCounts;
        })
        .whenComplete(() {
          if (identical(_chapterCountsInFlight[cacheKey], operation)) {
            _chapterCountsInFlight.remove(cacheKey);
          }
        });
    _chapterCountsInFlight[cacheKey] = operation;
    return operation;
  }

  /// Derives the whole-book count from the one authoritative chapter scan.
  /// Values are saturated to the same range accepted by persisted metadata.
  static int totalFromChapterCounts(Iterable<int> counts) {
    var total = 0;
    for (final count in counts) {
      total = (total + count.clamp(0, 0x7fffffffffffffff)).clamp(
        0,
        0x7fffffffffffffff,
      );
    }
    return total;
  }
}

String _chapterCacheKey(Book book) =>
    '${book.id}:${book.fileSize}:${book.txtParserVersion}:${book.chapters.length}';

List<int> _countVisibleRunesByEntry(List<String> contents) =>
    List<int>.unmodifiable(contents.map(_countVisibleRunesIn));

int _countVisibleRunesIn(String content) {
  var total = 0;
  for (final rune in content.runes) {
    if (!_isUnicodeWhitespace(rune)) total++;
  }
  return total;
}

bool _isUnicodeWhitespace(int rune) {
  return (rune >= 0x09 && rune <= 0x0D) ||
      rune == 0x20 ||
      rune == 0x85 ||
      rune == 0xA0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000 ||
      rune == 0xFEFF;
}

String formatBookWordCount(int? wordCount) {
  if (wordCount == null) return '全文字数未统计';
  return '全文 ${_withThousandsSeparators(wordCount)} 字';
}

String formatChapterWordCount(int? wordCount) {
  if (wordCount == null) return '统计中…';
  return '${_withThousandsSeparators(wordCount)} 字';
}

String _withThousandsSeparators(int value) {
  final digits = value.clamp(0, 0x7fffffffffffffff).toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}
