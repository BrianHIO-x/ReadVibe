import '../../models/book.dart';
import '../../models/reader_settings.dart';
import '../../models/reading_paragraph.dart';
import 'reader_pagination_support.dart';

/// Reader-session caches. Content changes invalidate them as one unit;
/// typography and width signatures independently invalidate measured extents.
///
/// Entries are keyed by chapter index rather than by the Chapter object.
/// A stored chapter loads its body lazily, so object identity is the only
/// equality it can offer and a rebuilt chapter list would silently miss every
/// entry. The index is stable for one book and one content revision, and the
/// reader calls [clear] whenever either of those changes.
class ReaderLayoutCache {
  ReaderLayoutCache({
    this.maxChapters = 12,
    this.maxCharacters = 12 * 1024 * 1024,
  });

  final int maxChapters;
  final int maxCharacters;
  final _paragraphs = <int, List<String>>{};
  final _extentsByMode = <ReaderReadingMode, Map<int, ChapterItemExtents>>{};
  final _signaturesByMode = <ReaderReadingMode, SimulationLayoutSignature>{};
  var _characters = 0;
  SimulationLayoutSignature? _lineSignature;
  double? _lineExtent;

  List<String> paragraphs(Chapter chapter) {
    final key = chapter.index;
    final cached = _paragraphs.remove(key);
    if (cached != null) {
      _paragraphs[key] = cached;
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
    _paragraphs[key] = values;
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
        _lineSignature?.fontSize == signature.fontSize &&
        _lineSignature?.lineHeight == signature.lineHeight &&
        _lineSignature?.fontFamily == signature.fontFamily &&
        _lineSignature?.importedFontFamily == signature.importedFontFamily &&
        _lineSignature?.importedFontPath == signature.importedFontPath &&
        _lineSignature?.fontWeight == signature.fontWeight &&
        _lineSignature?.locale == signature.locale) {
      return cached;
    }
    final measured = measure();
    _lineSignature = signature;
    _lineExtent = measured;
    return measured;
  }

  ChapterItemExtents chapterExtents(
    Chapter chapter,
    SimulationLayoutSignature signature,
    ChapterItemExtents Function() measure,
  ) {
    final mode = signature.mode;
    final extents = _extentsByMode.putIfAbsent(
      mode,
      () => <int, ChapterItemExtents>{},
    );
    if (_signaturesByMode[mode]?.matches(signature) != true) {
      extents.clear();
      _signaturesByMode[mode] = signature;
    }
    final key = chapter.index;
    final cached = extents.remove(key);
    if (cached != null) {
      extents[key] = cached;
      return cached;
    }
    final measured = measure();
    extents[key] = measured;
    while (extents.length > maxChapters) {
      extents.remove(extents.keys.first);
    }
    return measured;
  }

  void clear() {
    _paragraphs.clear();
    _characters = 0;
    _extentsByMode.clear();
    _signaturesByMode.clear();
    _lineSignature = null;
    _lineExtent = null;
  }

  static int _length(List<String> paragraphs) =>
      paragraphs.fold(0, (sum, paragraph) => sum + paragraph.length);
}

/// The height of every item in a page-mode chapter list, from the standalone
/// title through the body to the closing spacer, and the chapter's total.
///
/// Page mode builds a fresh list for the page a turn reveals and for the back
/// of the leaf. A list that only knows its total has to lay out every item
/// from the top of the chapter to find the one at its offset, so a turn deep
/// into a long chapter used to lay out the whole chapter up to there, twice.
/// With every height known in advance, the list starts at the page itself.
class ChapterItemExtents {
  ChapterItemExtents({required List<double> items, required this.total})
    : items = List<double>.unmodifiable(items);

  final List<double> items;
  final double total;
}
