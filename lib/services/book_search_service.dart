import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/book.dart';
import 'storage_service.dart';

class BookSearchResult {
  final int chapterIndex;
  final int paragraphIndex;
  final int characterOffset;
  final String chapterTitle;
  final String snippet;
  final String matchedText;

  const BookSearchResult({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.characterOffset,
    required this.chapterTitle,
    required this.snippet,
    required this.matchedText,
  });
}

/// Searches the chapter payload that is already used by the reader.
///
/// Search never depends on a generated file or a persisted completion flag.
/// Every query is executed in a worker isolate, so even a large TXT book stays
/// searchable without blocking reader animations or input handling.
class BookSearchService {
  BookSearchService._();

  static const maxResults = 500;
  static final _paragraphBreakPattern = RegExp(r'(?:\r\n?|\n)+');
  static final _leadingWhitespacePattern = RegExp(r'^[\s　]+');
  static final _searchWhitespacePattern = RegExp(
    r'[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+',
  );
  static Future<void>? _obsoleteDataRemoval;

  static Future<List<BookSearchResult>> search(Book book, String rawQuery) {
    final query = _normalizeForSearch(rawQuery);
    if (query.isEmpty || book.isPdf || book.chapters.isEmpty) {
      return Future<List<BookSearchResult>>.value(const <BookSearchResult>[]);
    }
    return Isolate.run(() => _scanBook(book, query));
  }

  /// Removes files created by older releases. The current search path never
  /// reads or recreates this directory, so interrupted legacy work cannot make
  /// search unavailable after an overlay installation.
  static Future<void> removeObsoleteData(StorageService storage) {
    return _obsoleteDataRemoval ??= () async {
      try {
        final root = (await storage.getAppDataDirectory()).absolute;
        final directory = Directory(p.join(root.path, 'search')).absolute;
        if (p.isWithin(root.path, directory.path) && await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } on Object {
        // Searching does not use these files. A later app launch can retry the
        // space cleanup without changing current search availability.
        _obsoleteDataRemoval = null;
      }
    }();
  }

  static List<BookSearchResult> _scanBook(Book book, String query) {
    final results = <BookSearchResult>[];
    for (
      var chapterIndex = 0;
      chapterIndex < book.chapters.length;
      chapterIndex++
    ) {
      final chapter = book.chapters[chapterIndex];
      var paragraphIndex = 0;
      for (final rawParagraph in chapter.content.split(
        _paragraphBreakPattern,
      )) {
        final paragraph = _readerParagraphBody(rawParagraph);
        if (paragraph.isEmpty) continue;

        final searchable = _normalizeForSearch(paragraph);
        var matchOffset = searchable.indexOf(query);
        while (matchOffset >= 0) {
          final range = _sourceRangeForNormalizedMatch(
            paragraph,
            matchOffset,
            matchOffset + query.length,
          );
          final snippetStart = _safeSubstringStart(
            paragraph,
            (range.start - 28).clamp(0, paragraph.length),
          );
          final snippetEnd = _safeSubstringEnd(
            paragraph,
            (range.end + 42).clamp(0, paragraph.length),
          );
          results.add(
            BookSearchResult(
              chapterIndex: chapterIndex,
              paragraphIndex: paragraphIndex,
              characterOffset: range.start,
              chapterTitle: chapter.title,
              snippet:
                  '${snippetStart > 0 ? '…' : ''}${paragraph.substring(snippetStart, snippetEnd)}${snippetEnd < paragraph.length ? '…' : ''}',
              matchedText: paragraph.substring(range.start, range.end),
            ),
          );
          if (results.length >= maxResults) return results;
          final nextStart = matchOffset + query.length;
          matchOffset = searchable.indexOf(query, nextStart);
        }
        paragraphIndex++;
      }
    }
    return results;
  }

  static String _readerParagraphBody(String value) {
    return value.replaceFirst(_leadingWhitespacePattern, '').trimRight();
  }

  static String _normalizeForSearch(String value) {
    return value.toLowerCase().replaceAll(_searchWhitespacePattern, ' ').trim();
  }

  /// Converts a match offset in normalized text back to UTF-16 offsets in the
  /// exact paragraph rendered by ReaderScreen. Mapping is only calculated for
  /// paragraphs that actually match, avoiding a large per-character table for
  /// common 10–20 MB books.
  static ({int start, int end}) _sourceRangeForNormalizedMatch(
    String source,
    int normalizedStart,
    int normalizedEnd,
  ) {
    var sourceOffset = 0;
    var normalizedOffset = 0;
    int? matchStart;
    int? matchEnd;
    int? whitespaceStart;
    var whitespaceEnd = 0;

    void accountToken(String token, int sourceStart, int sourceEnd) {
      if (token.isEmpty || matchEnd != null) return;
      final tokenStart = normalizedOffset;
      final tokenEnd = tokenStart + token.length;
      if (matchStart == null && normalizedStart < tokenEnd) {
        matchStart = sourceStart;
      }
      if (normalizedEnd <= tokenEnd) {
        matchEnd = sourceEnd;
      }
      normalizedOffset = tokenEnd;
    }

    for (final rune in source.runes) {
      final runeLength = rune > 0xffff ? 2 : 1;
      final runeEnd = sourceOffset + runeLength;
      if (_isWhitespaceRune(rune)) {
        whitespaceStart ??= sourceOffset;
        whitespaceEnd = runeEnd;
        sourceOffset = runeEnd;
        continue;
      }
      if (whitespaceStart != null && normalizedOffset > 0) {
        accountToken(' ', whitespaceStart, whitespaceEnd);
        whitespaceStart = null;
        if (matchEnd != null) break;
      } else {
        whitespaceStart = null;
      }
      accountToken(
        String.fromCharCode(rune).toLowerCase(),
        sourceOffset,
        runeEnd,
      );
      sourceOffset = runeEnd;
      if (matchEnd != null) break;
    }

    final safeStart = (matchStart ?? 0).clamp(0, source.length);
    final safeEnd = (matchEnd ?? source.length).clamp(safeStart, source.length);
    return (start: safeStart, end: safeEnd);
  }

  static int _safeSubstringStart(String value, int offset) {
    if (offset <= 0 || offset >= value.length) return offset;
    return _isLowSurrogate(value.codeUnitAt(offset)) ? offset - 1 : offset;
  }

  static int _safeSubstringEnd(String value, int offset) {
    if (offset <= 0 || offset >= value.length) return offset;
    return _isHighSurrogate(value.codeUnitAt(offset - 1)) ? offset + 1 : offset;
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xd800 && codeUnit <= 0xdbff;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

  static bool _isWhitespaceRune(int rune) =>
      rune == 0x20 ||
      (rune >= 0x09 && rune <= 0x0d) ||
      rune == 0x85 ||
      rune == 0xa0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200a) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202f ||
      rune == 0x205f ||
      rune == 0x3000 ||
      rune == 0xfeff;
}
