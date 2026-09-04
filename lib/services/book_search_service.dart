import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import '../models/book.dart';
import '../models/search_match.dart';
import '../models/reading_paragraph.dart';

export '../models/search_match.dart' show BookSearchResult;

/// Searches the chapter payload that is already used by the reader.
///
/// Search never depends on a generated file or a persisted completion flag.
/// A search panel owns one worker session. The book and its normalized
/// paragraphs cross the isolate boundary once, while subsequent keywords send
/// only the small query string.
class BookSearchService {
  BookSearchService._();

  static const maxResults = maxDocumentSearchResults;
  static final _searchWhitespacePattern = RegExp(
    r'[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+',
  );

  static BookSearchSession openSession(Book book) => BookSearchSession._(book);

  /// Convenience entry for callers that only issue one query. ReaderScreen
  /// uses [openSession] so repeated submissions reuse the prepared document.
  static Future<List<BookSearchResult>> search(Book book, String rawQuery) {
    final session = openSession(book);
    return session.search(rawQuery).whenComplete(session.dispose);
  }

  static _SearchDocument _prepareDocument(Book book) {
    return _SearchDocument(book);
  }

  static _SearchChapter _prepareChapter(Chapter chapter, int chapterIndex) {
    final paragraphs = <_SearchParagraph>[];
    var paragraphIndex = 0;
    for (final projected in readingParagraphs(chapter)) {
      final paragraph = projected.body;
      paragraphs.add(
        _SearchParagraph(
          index: paragraphIndex,
          source: paragraph,
          normalized: _normalizeForSearch(paragraph),
        ),
      );
      paragraphIndex++;
    }
    return _SearchChapter(
      index: chapterIndex,
      title: chapter.title,
      paragraphs: paragraphs,
    );
  }

  static List<BookSearchResult> _scanDocument(
    _SearchDocument document,
    String query,
  ) {
    final results = <BookSearchResult>[];
    for (
      var chapterIndex = 0;
      chapterIndex < document.chapterCount;
      chapterIndex++
    ) {
      final chapter = document.chapterAt(chapterIndex);
      for (final paragraph in chapter.paragraphs) {
        final searchable = paragraph.normalized;
        var matchOffset = searchable.indexOf(query);
        while (matchOffset >= 0) {
          final range = _sourceRangeForNormalizedMatch(
            paragraph.source,
            matchOffset,
            matchOffset + query.length,
          );
          final snippetStart = _safeSubstringStart(
            paragraph.source,
            (range.start - 28).clamp(0, paragraph.source.length),
          );
          final snippetEnd = _safeSubstringEnd(
            paragraph.source,
            (range.end + 42).clamp(0, paragraph.source.length),
          );
          final hasLeadingEllipsis = snippetStart > 0;
          final hasTrailingEllipsis = snippetEnd < paragraph.source.length;
          final snippet =
              '${hasLeadingEllipsis ? '…' : ''}${paragraph.source.substring(snippetStart, snippetEnd)}${hasTrailingEllipsis ? '…' : ''}';
          final snippetMatchStart =
              (hasLeadingEllipsis ? 1 : 0) + range.start - snippetStart;
          results.add(
            BookSearchResult(
              chapterIndex: chapter.index,
              paragraphIndex: paragraph.index,
              characterOffset: range.start,
              chapterTitle: chapter.title,
              snippet: snippet,
              matchedText: paragraph.source.substring(range.start, range.end),
              snippetMatchStart: snippetMatchStart,
              snippetMatchEnd: snippetMatchStart + range.end - range.start,
            ),
          );
          if (results.length >= maxResults) return results;
          final nextStart = matchOffset + query.length;
          matchOffset = searchable.indexOf(query, nextStart);
        }
      }
    }
    return results;
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

class BookSearchSession {
  final Book _book;
  Future<_BookSearchWorker>? _worker;
  bool _disposed = false;

  BookSearchSession._(this._book);

  Future<List<BookSearchResult>> search(String rawQuery) async {
    if (_disposed) throw StateError('搜索会话已关闭');
    final query = BookSearchService._normalizeForSearch(rawQuery);
    if (query.isEmpty || _book.isPdf || _book.chapters.isEmpty) {
      return const <BookSearchResult>[];
    }
    final worker = await (_worker ??= _BookSearchWorker.start(_book));
    if (_disposed) {
      worker.dispose();
      throw StateError('搜索会话已关闭');
    }
    return worker.search(query);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final worker = _worker;
    if (worker == null) return;
    unawaited(
      worker.then(
        (value) => value.dispose(),
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
}

class _BookSearchWorker {
  final Isolate _isolate;
  final SendPort _commands;
  final Set<_PendingSearch> _pending = <_PendingSearch>{};
  bool _disposed = false;

  _BookSearchWorker(this._isolate, this._commands);

  static Future<_BookSearchWorker> start(Book book) async {
    final readyPort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn<List<Object>>(
      _bookSearchWorkerMain,
      <Object>[readyPort.sendPort, book],
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );
    try {
      final signal = await Future.any<Object>([
        readyPort.first.then<Object>((value) => value as Object),
        errorPort.first.then<Object>(
          (error) => _WorkerStartupFailure('搜索 worker 启动失败：$error'),
        ),
        exitPort.first.then<Object>(
          (_) => const _WorkerStartupFailure('搜索 worker 在初始化前退出'),
        ),
      ]);
      if (signal case final SendPort commands) {
        return _BookSearchWorker(isolate, commands);
      }
      isolate.kill(priority: Isolate.immediate);
      throw StateError((signal as _WorkerStartupFailure).message);
    } finally {
      readyPort.close();
      errorPort.close();
      exitPort.close();
    }
  }

  Future<List<BookSearchResult>> search(String query) {
    if (_disposed) {
      return Future<List<BookSearchResult>>.error(StateError('搜索 worker 已关闭'));
    }
    final responsePort = ReceivePort();
    final completer = Completer<List<BookSearchResult>>();
    late final _PendingSearch pending;
    late final StreamSubscription<Object?> subscription;
    subscription = responsePort.listen((message) {
      if (completer.isCompleted) return;
      if (message case [true, final List<Object?> rawResults]) {
        completer.complete(rawResults.cast<BookSearchResult>());
      } else if (message case [false, final Object error]) {
        completer.completeError(StateError(error.toString()));
      } else {
        completer.completeError(StateError('搜索 worker 返回了无效结果'));
      }
      pending.close();
      _pending.remove(pending);
    });
    pending = _PendingSearch(responsePort, subscription, completer);
    _pending.add(pending);
    _commands.send(<Object>[query, responsePort.sendPort]);
    return completer.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final pending in _pending.toList(growable: false)) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError('搜索会话已关闭'));
      }
      pending.close();
    }
    _pending.clear();
    _commands.send(null);
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

class _PendingSearch {
  final ReceivePort port;
  final StreamSubscription<Object?> subscription;
  final Completer<List<BookSearchResult>> completer;

  const _PendingSearch(this.port, this.subscription, this.completer);

  void close() {
    unawaited(subscription.cancel());
    port.close();
  }
}

class _WorkerStartupFailure {
  final String message;

  const _WorkerStartupFailure(this.message);
}

class _SearchDocument {
  static const _maxCachedCharacters = 12 * 1024 * 1024;

  final Book book;
  final LinkedHashMap<int, _SearchChapter> _cache =
      LinkedHashMap<int, _SearchChapter>();
  var _cachedCharacters = 0;

  _SearchDocument(this.book);

  int get chapterCount => book.chapters.length;

  _SearchChapter chapterAt(int index) {
    final cached = _cache.remove(index);
    if (cached != null) {
      _cache[index] = cached;
      return cached;
    }
    final chapter = BookSearchService._prepareChapter(
      book.chapters[index],
      index,
    );
    final characters = chapter.paragraphs.fold<int>(
      0,
      (sum, paragraph) =>
          sum + paragraph.source.length + paragraph.normalized.length,
    );
    if (characters <= _maxCachedCharacters) {
      while (_cachedCharacters + characters > _maxCachedCharacters &&
          _cache.isNotEmpty) {
        final oldest = _cache.remove(_cache.keys.first)!;
        _cachedCharacters -= oldest.paragraphs.fold<int>(
          0,
          (sum, paragraph) =>
              sum + paragraph.source.length + paragraph.normalized.length,
        );
      }
      _cache[index] = chapter;
      _cachedCharacters += characters;
    }
    return chapter;
  }
}

class _SearchChapter {
  final int index;
  final String title;
  final List<_SearchParagraph> paragraphs;

  const _SearchChapter({
    required this.index,
    required this.title,
    required this.paragraphs,
  });
}

class _SearchParagraph {
  final int index;
  final String source;
  final String normalized;

  const _SearchParagraph({
    required this.index,
    required this.source,
    required this.normalized,
  });
}

void _bookSearchWorkerMain(List<Object> arguments) {
  final readyPort = arguments[0] as SendPort;
  final book = arguments[1] as Book;
  final document = BookSearchService._prepareDocument(book);
  final commands = ReceivePort();
  readyPort.send(commands.sendPort);
  commands.listen((message) {
    if (message == null) {
      commands.close();
      return;
    }
    if (message is! List ||
        message.length != 2 ||
        message[0] is! String ||
        message[1] is! SendPort) {
      return;
    }
    final query = message[0] as String;
    final response = message[1] as SendPort;
    try {
      response.send(<Object>[
        true,
        BookSearchService._scanDocument(document, query),
      ]);
    } on Object catch (error, stackTrace) {
      response.send(<Object>[false, '$error\n$stackTrace']);
    }
  });
}
