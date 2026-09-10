// Reader bookmarks and notes for reflowable text books.
//
// PDF keeps its own page-indexed bookmark and note records because a fixed
// layout has no chapters or reading paragraphs. Text books anchor on the same
// (chapter, paragraph, character) triple the reader already uses to restore a
// reading position and to open a search hit, so a saved mark survives font,
// margin and reading-mode changes.

import 'dart:math' as math;

const maxReaderBookmarksPerBook = 500;
const maxReaderBookmarkExcerpt = 160;
const maxReaderBookmarkNote = 4000;

/// One saved position in a text book, optionally carrying a note.
class ReaderBookmark {
  final String id;
  final int chapterIndex;
  final String chapterTitle;
  final int paragraphIndex;
  final int characterOffset;

  /// Body text around the anchor, used as the list preview.
  final String excerpt;

  /// Empty for a plain bookmark; non-empty when the user wrote a note.
  final String note;

  /// Position inside the chapter at save time, shown as a percentage.
  final double chapterProgress;
  final DateTime createdAt;

  const ReaderBookmark({
    required this.id,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.paragraphIndex,
    required this.characterOffset,
    required this.excerpt,
    required this.note,
    required this.chapterProgress,
    required this.createdAt,
  });

  bool get hasNote => note.isNotEmpty;

  /// True when both marks point at the same reading paragraph. The reader uses
  /// this to toggle the current position instead of stacking near-duplicates.
  bool sharesAnchorWith(ReaderBookmark other) =>
      chapterIndex == other.chapterIndex &&
      paragraphIndex == other.paragraphIndex;

  ReaderBookmark copyWith({String? note, String? excerpt}) => ReaderBookmark(
    id: id,
    chapterIndex: chapterIndex,
    chapterTitle: chapterTitle,
    paragraphIndex: paragraphIndex,
    characterOffset: characterOffset,
    excerpt: excerpt ?? this.excerpt,
    note: note ?? this.note,
    chapterProgress: chapterProgress,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'chapterIndex': chapterIndex,
    'chapterTitle': chapterTitle,
    'paragraphIndex': paragraphIndex,
    'characterOffset': characterOffset,
    'excerpt': excerpt,
    if (note.isNotEmpty) 'note': note,
    'chapterProgress': chapterProgress,
    'createdAt': createdAt.toIso8601String(),
  };

  /// Returns null for a record that cannot be trusted as a reading anchor.
  /// A damaged entry is dropped rather than repaired, so the list never shows
  /// a mark that would jump somewhere the user never was.
  static ReaderBookmark? fromJson(Object? source) {
    if (source is! Map) return null;
    final json = Map<String, dynamic>.from(source);
    final chapterIndex = _boundedInt(json['chapterIndex']);
    final paragraphIndex = _boundedInt(json['paragraphIndex']);
    final characterOffset = _boundedInt(json['characterOffset']);
    if (chapterIndex == null ||
        paragraphIndex == null ||
        characterOffset == null) {
      return null;
    }
    final id = json['id'];
    final createdRaw = json['createdAt'];
    final createdAt = createdRaw is String
        ? DateTime.tryParse(createdRaw) ?? DateTime.now()
        : DateTime.now();
    final progress = json['chapterProgress'];
    return ReaderBookmark(
      id: id is String && id.isNotEmpty && id.length <= 64
          ? id
          : '$chapterIndex:$paragraphIndex:${createdAt.microsecondsSinceEpoch}',
      chapterIndex: chapterIndex,
      chapterTitle: clampBookmarkText(json['chapterTitle'], 120),
      paragraphIndex: paragraphIndex,
      characterOffset: characterOffset,
      excerpt: clampBookmarkText(json['excerpt'], maxReaderBookmarkExcerpt),
      note: clampBookmarkText(json['note'], maxReaderBookmarkNote),
      chapterProgress: progress is num && progress.isFinite
          ? progress.toDouble().clamp(0.0, 1.0)
          : 0.0,
      createdAt: createdAt,
    );
  }

  static int? _boundedInt(Object? value) {
    if (value is! num || !value.isFinite) return null;
    final result = value.toInt();
    return result >= 0 && result <= 0x7fffffff ? result : null;
  }
}

/// Trims a stored string to a safe display length without splitting a surrogate
/// pair, which would leave an unpaired code unit in the shelf JSON.
String clampBookmarkText(Object? value, int maxLength) {
  if (value is! String) return '';
  final trimmed = value.trim();
  if (trimmed.length <= maxLength) return trimmed;
  var end = math.min(maxLength, trimmed.length);
  final unit = trimmed.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  return trimmed.substring(0, end).trimRight();
}

/// Sorts marks into reading order so the list matches the book's own sequence.
List<ReaderBookmark> sortedReaderBookmarks(Iterable<ReaderBookmark> marks) {
  return marks.toList()
    ..sort((first, second) {
      final byChapter = first.chapterIndex.compareTo(second.chapterIndex);
      if (byChapter != 0) return byChapter;
      final byParagraph = first.paragraphIndex.compareTo(second.paragraphIndex);
      if (byParagraph != 0) return byParagraph;
      return first.characterOffset.compareTo(second.characterOffset);
    });
}
