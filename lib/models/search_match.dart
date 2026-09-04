const maxDocumentSearchResults = 500;

/// Display contract independent of a document's navigation coordinates.
abstract interface class SearchMatch {
  String get title;
  String get snippet;
  String get matchedText;
  int get snippetMatchStart;
  int get snippetMatchEnd;
}

class BookSearchResult implements SearchMatch {
  @override
  String get title => chapterTitle;
  final int chapterIndex;
  final int paragraphIndex;
  final int characterOffset;
  final String chapterTitle;
  @override
  final String snippet;
  @override
  final String matchedText;
  @override
  final int snippetMatchStart;
  @override
  final int snippetMatchEnd;

  const BookSearchResult({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.characterOffset,
    required this.chapterTitle,
    required this.snippet,
    required this.matchedText,
    required this.snippetMatchStart,
    required this.snippetMatchEnd,
  });
}

class PdfTextSearchResult implements SearchMatch {
  final bool isOcr;
  @override
  String get title => '第 ${pageIndex + 1} 页${isOcr ? ' · OCR' : ''}';
  final int pageIndex;
  @override
  final String snippet;
  @override
  final String matchedText;
  @override
  final int snippetMatchStart;
  @override
  final int snippetMatchEnd;

  const PdfTextSearchResult({
    this.isOcr = false,
    required this.pageIndex,
    required this.snippet,
    required this.matchedText,
    required this.snippetMatchStart,
    required this.snippetMatchEnd,
  });
}
