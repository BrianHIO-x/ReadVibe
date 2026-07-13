import 'dart:async';
import 'dart:isolate';

import '../models/book.dart';

/// Counts visible Unicode characters in a book without blocking the UI isolate.
///
/// Whitespace and paragraph separators are excluded. A Unicode scalar value is
/// counted once, so supplementary-plane characters are not double-counted as
/// two UTF-16 code units.
class WordCountService {
  static final Map<String, Future<int>> _inFlight = <String, Future<int>>{};

  Future<int> count(Book book) {
    final stored = book.wordCount;
    if (stored != null) return Future<int>.value(stored);

    final existing = _inFlight[book.id];
    if (existing != null) return existing;

    final contents = <String>[
      for (final chapter in book.chapters) ...[chapter.title, chapter.content],
    ];
    late final Future<int> operation;
    operation = Isolate.run(() => _countVisibleRunes(contents)).whenComplete(
      () {
        if (identical(_inFlight[book.id], operation)) {
          _inFlight.remove(book.id);
        }
      },
    );
    _inFlight[book.id] = operation;
    return operation;
  }
}

int _countVisibleRunes(List<String> contents) {
  var total = 0;
  for (final content in contents) {
    for (final rune in content.runes) {
      if (!_isUnicodeWhitespace(rune)) total++;
    }
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
  if (wordCount == null) return '全文字数统计中…';
  return '全文 ${_withThousandsSeparators(wordCount)} 字';
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
