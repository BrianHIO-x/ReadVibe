import '../../models/book.dart';
import '../../models/reading_paragraph.dart';
import 'reader_pagination_support.dart';

/// Reader-session caches. Content changes invalidate them as one unit;
/// typography and width signatures independently invalidate measured extents.
class ReaderLayoutCache {
  ReaderLayoutCache({
    this.maxChapters = 5,
    this.maxCharacters = 12 * 1024 * 1024,
  });

  final int maxChapters;
  final int maxCharacters;
  final _paragraphs = <Chapter, List<String>>{};
  final _extents = <Chapter, double>{};
  var _characters = 0;
  SimulationLayoutSignature? _extentSignature;
  SimulationLayoutSignature? _lineSignature;
  double? _lineExtent;

  List<String> paragraphs(Chapter chapter) {
    final cached = _paragraphs.remove(chapter);
    if (cached != null) {
      _paragraphs[chapter] = cached;
      return cached;
    }
    final values = List<String>.unmodifiable(
      readingParagraphs(chapter).map((paragraph) => paragraph.displayText),
    );
    final characters = _length(values);
    // Retain one oversized current chapter to avoid repeatedly splitting it
    // during scrolling. Adjacent chapters share the normal bounded budget.
    while (_paragraphs.isNotEmpty &&
        (_paragraphs.length >= maxChapters ||
            _characters + characters > maxCharacters)) {
      _characters -= _length(_paragraphs.remove(_paragraphs.keys.first)!);
    }
    _paragraphs[chapter] = values;
    _characters += characters;
    return values;
  }

  double lineExtent(
    SimulationLayoutSignature signature,
    double Function() measure,
  ) {
    final cached = _lineExtent;
    if (cached != null &&
        cached.isFinite &&
        cached > 0 &&
        _lineSignature?.matches(signature) == true) {
      return cached;
    }
    final measured = measure();
    _lineSignature = signature;
    _lineExtent = measured;
    return measured;
  }

  double chapterExtent(
    Chapter chapter,
    SimulationLayoutSignature signature,
    double Function() measure,
  ) {
    if (_extentSignature?.matches(signature) != true) {
      _extents.clear();
      _extentSignature = signature;
    }
    final cached = _extents.remove(chapter);
    if (cached != null) {
      _extents[chapter] = cached;
      return cached;
    }
    final measured = measure();
    _extents[chapter] = measured;
    while (_extents.length > maxChapters) {
      _extents.remove(_extents.keys.first);
    }
    return measured;
  }

  void clear() {
    _paragraphs.clear();
    _characters = 0;
    _extents.clear();
    _extentSignature = null;
    _lineSignature = null;
    _lineExtent = null;
  }

  static int _length(List<String> paragraphs) =>
      paragraphs.fold(0, (sum, paragraph) => sum + paragraph.length);
}
