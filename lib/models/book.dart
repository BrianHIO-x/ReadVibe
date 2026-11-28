// Book and chapter data models.
// Backing fields keep the public constructor names stable while allowing the
// storage layer to override content getters with bounded lazy chapter proxies.
// ignore_for_file: prefer_initializing_formals

import 'book_content_revision.dart';

const currentTxtParserVersion = 3;

final _volumeChapterTitlePattern = RegExp(
  r'^(?:第[一二两兩三四五六七八九十百千万萬零〇０-９0-9]+卷|卷[一二两兩三四五六七八九十百千万萬零〇０-９0-9]+(?:$|[\s　:：—–\-（(【\[]))',
);
final _introductoryChapterTitlePattern = RegExp(
  r'^(?:内容简介|內容簡介|作品简介|作品簡介|书籍简介|書籍簡介|作者简介|作者簡介|编辑推荐|編輯推薦|内容提要|內容提要|出版说明|出版說明|简介|簡介|前言|序言|序章|楔子|引子|开篇|開篇|导读|導讀)(?:$|[\s　:：—（(【\[-])',
);
final _standaloneTailTitlePattern = RegExp(
  r'^(?:(?:后记|後記|尾声|尾聲|附录|附錄)(?:$|[\s　:：—（(【\[-]|$)|番外(?:$|[\s　:：—（(【\[-]|第?[一二两兩三四五六七八九十百千万萬零〇０-９0-9]+[章节節篇]?(?:$|[\s　:：—（(【\[])))',
);

bool isVolumeChapterTitle(String title) =>
    _volumeChapterTitlePattern.hasMatch(title.trim());

bool isIntroductoryChapterTitle(String title) =>
    _introductoryChapterTitlePattern.hasMatch(title.trim());

bool isStandaloneChapterTitle(String title) =>
    isIntroductoryChapterTitle(title) ||
    _standaloneTailTitlePattern.hasMatch(title.trim());

enum BookFormat { txt, epub, mobi, azw, azw3, docx, doc, pdf }

enum BookAvailability {
  available,
  sourceMissing,
  payloadMissing,
  resourceMissing,
}

extension BookAvailabilityInfo on BookAvailability {
  bool get blocksOpening =>
      this == BookAvailability.sourceMissing ||
      this == BookAvailability.payloadMissing;

  String get label => switch (this) {
    BookAvailability.available => '',
    BookAvailability.sourceMissing => '源文件丢失',
    BookAvailability.payloadMissing => '正文载荷损坏',
    BookAvailability.resourceMissing => '图片资源丢失',
  };
}

enum EpubContentBlockKind { text, image }

/// A compact, Flutter-independent subset of EPUB styling.
///
/// Values are persisted with the chapter payload so EPUB books can keep their
/// publisher layout without using a second WebView-based reader. Font sizes,
/// line heights and spacing are relative to the user's reader settings.
class EpubContentStyle {
  final String? fontFamily;
  final double fontScale;
  final int fontWeight;
  final bool italic;
  final bool underline;
  final String textAlign;
  final double lineHeightScale;
  final double letterSpacingEm;
  final double textIndentEm;
  final double marginTopEm;
  final double marginBottomEm;
  final int? colorArgb;
  final int? backgroundColorArgb;
  final String? backgroundImagePath;

  const EpubContentStyle({
    this.fontFamily,
    this.fontScale = 1,
    this.fontWeight = 400,
    this.italic = false,
    this.underline = false,
    this.textAlign = 'start',
    this.lineHeightScale = 1,
    this.letterSpacingEm = 0,
    this.textIndentEm = 2,
    this.marginTopEm = 0,
    this.marginBottomEm = 0,
    this.colorArgb,
    this.backgroundColorArgb,
    this.backgroundImagePath,
  });
}

/// Where an EPUB hyperlink points inside the same book.
///
/// External schemes are deliberately not modeled: ReadVibe processes book
/// content locally, so a publisher's outbound link stays plain text instead of
/// becoming a tap that leaves the device.
class EpubLinkTarget {
  final int chapterIndex;

  /// Block the fragment resolved to, or -1 when only the chapter is known.
  final int blockIndex;

  /// Set for a link that came from a directory-style row.
  ///
  /// The target of such a row is a destination the reader chose, so the reader
  /// jumps to it instead of showing the short-target footnote preview. Links in
  /// ordinary prose keep their preview. Older payloads omit the flag and mean
  /// false.
  final bool needDirectJump;

  const EpubLinkTarget({
    required this.chapterIndex,
    this.blockIndex = -1,
    this.needDirectJump = false,
  });

  bool get hasBlock => blockIndex >= 0;
}

class EpubTextRun {
  final String text;
  final EpubContentStyle style;

  /// Set when the run sits inside an anchor that resolves within this book.
  final EpubLinkTarget? link;

  const EpubTextRun({required this.text, required this.style, this.link});

  EpubTextRun withLink(EpubLinkTarget? target) =>
      EpubTextRun(text: text, style: style, link: target);
}

class EpubContentBlock {
  final EpubContentBlockKind kind;
  final String text;
  final List<EpubTextRun> runs;
  final bool isHeading;
  final String? imagePath;
  final String? altText;
  final double? imageWidth;
  final double? imageHeight;
  final EpubContentStyle style;

  /// Element ids this block covers, so a link fragment can find its landing
  /// block. Footnote bodies carry the id that the marker in the text points at.
  final List<String> anchorIds;

  /// UTF-16 offset in [text] where a table row's right-hand cell starts.
  ///
  /// Only a simple two-column row whose right cell carries a page number gets
  /// this metadata. [text] remains the complete readable line (the separator is
  /// the character before this offset), so search, copying and plain-text
  /// fallbacks need no special case. The reader may then draw the trailing cell
  /// as a narrow, end-aligned column. Null on every ordinary block.
  final int? trailingCellStart;

  /// Relative width of the trailing cell in em of the reader's base font.
  ///
  /// The parser resolves a publisher width against the cell's own font size and
  /// stores the effective value, so layout only multiplies by the reader's font
  /// size. Null when the row has no trailing-cell metadata.
  final double? trailingCellWidthEm;

  const EpubContentBlock({
    required this.kind,
    this.text = '',
    this.runs = const <EpubTextRun>[],
    this.isHeading = false,
    this.imagePath,
    this.altText,
    this.imageWidth,
    this.imageHeight,
    this.style = const EpubContentStyle(),
    this.anchorIds = const <String>[],
    this.trailingCellStart,
    this.trailingCellWidthEm,
  });

  bool get isText => kind == EpubContentBlockKind.text;
  bool get isImage => kind == EpubContentBlockKind.image;
  bool get hasLinks => runs.any((run) => run.link != null);

  /// Whether this block carries a right-hand table cell that the reader can
  /// lay out as its own narrow column.
  bool get hasTrailingCell =>
      isText &&
      trailingCellStart != null &&
      trailingCellStart! > 0 &&
      trailingCellStart! < text.length;

  EpubContentBlock withRuns(List<EpubTextRun> replacement) => EpubContentBlock(
    kind: kind,
    text: text,
    runs: List<EpubTextRun>.unmodifiable(replacement),
    isHeading: isHeading,
    imagePath: imagePath,
    altText: altText,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    style: style,
    anchorIds: anchorIds,
    trailingCellStart: trailingCellStart,
    trailingCellWidthEm: trailingCellWidthEm,
  );
}

/// One chapter of a book.
///
/// Chapter deliberately keeps identity equality. A stored chapter reads its
/// body from disk on first access, so a value-based `==` would have to either
/// load every payload it compares, which is exactly the work the lazy proxy
/// exists to avoid, or compare only the cheap fields and call two different
/// chapters equal. Callers that need a stable key use [index], which is unique
/// within a book and changes only when its content revision does.
class Chapter {
  final int index;
  final String title;
  final String _content;
  final String? volumeTitle;
  final List<EpubContentBlock> _epubBlocks;
  final int? _storedEpubBlockCount;
  final bool? _storedHasSemanticHeading;

  const Chapter({
    required this.index,
    required this.title,
    required String content,
    this.volumeTitle,
    List<EpubContentBlock> epubBlocks = const <EpubContentBlock>[],
    int? epubBlockCount,
    bool? hasSemanticHeading,
  }) : _content = content,
       _epubBlocks = epubBlocks,
       _storedEpubBlockCount = epubBlockCount,
       _storedHasSemanticHeading = hasSemanticHeading;

  String get content => _content;

  List<EpubContentBlock> get epubBlocks => _epubBlocks;

  bool get hasRichEpubContent => epubBlocks.isNotEmpty;

  int get epubBlockCount => epubBlocks.isNotEmpty
      ? epubBlocks.length
      : (_storedEpubBlockCount ?? 0).clamp(0, 0x7fffffff);

  bool get hasKnownEpubBlockCount =>
      epubBlocks.isNotEmpty || _storedEpubBlockCount != null;

  bool get hasSemanticHeading =>
      _storedHasSemanticHeading ??
      epubBlocks.any(
        (block) =>
            block.isText && block.isHeading && block.text.trim().isNotEmpty,
      );

  bool get hasKnownSemanticHeading =>
      epubBlocks.isNotEmpty || _storedHasSemanticHeading != null;
}

List<String> normalizeBookGroups(
  Iterable<Object?> rawGroups, {
  int maxGroups = 12,
  int maxLength = 24,
}) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final raw in rawGroups) {
    if (raw is! String) continue;
    final collapsed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) continue;
    final clamped = _clampBookGroupName(collapsed, maxLength);
    if (clamped.isEmpty || !seen.add(clamped)) continue;
    normalized.add(clamped);
    if (normalized.length >= maxGroups) break;
  }
  return List<String>.unmodifiable(normalized);
}

String _clampBookGroupName(String value, int maxUnits) {
  if (value.length <= maxUnits) return value;
  var cut = maxUnits;
  if (cut > 0 && cut < value.length) {
    final prev = value.codeUnitAt(cut - 1);
    final next = value.codeUnitAt(cut);
    if (prev >= 0xD800 && prev <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF) {
      cut -= 1;
    }
  }
  return value.substring(0, cut).trimRight();
}

class Book {
  final String id;
  final String title;
  final String author;
  final BookFormat format;
  final List<Chapter> chapters;
  final int? _storedChapterCount;
  final DateTime importDate;
  final int fileSize;
  final int txtParserVersion;
  final int contentRevision;
  final int? wordCount;
  final List<int>? chapterWordCounts;
  final String? sourcePath;
  final String? coverImagePath;
  final int? pageCount;
  final Map<String, String> embeddedFonts;

  /// Shown only on the private shelf. Shelf membership is changed through
  /// the library, never by saving a book's content.
  final bool isPrivate;
  final List<String> groups;

  const Book({
    required this.id,
    required this.title,
    this.author = '',
    required this.format,
    required this.chapters,
    int? chapterCount,
    required this.importDate,
    this.fileSize = 0,
    this.txtParserVersion = currentTxtParserVersion,
    this.contentRevision = 0,
    this.wordCount,
    this.chapterWordCounts,
    this.sourcePath,
    this.coverImagePath,
    this.pageCount,
    this.embeddedFonts = const <String, String>{},
    this.isPrivate = false,
    this.groups = const <String>[],
  }) : _storedChapterCount = chapterCount;

  bool get isPdf => format == BookFormat.pdf;

  int get chapterCount => chapters.isNotEmpty
      ? chapters.length
      : (_storedChapterCount ?? 0).clamp(0, 0x7fffffff);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'format': format.name,
    'importDate': importDate.toIso8601String(),
    'fileSize': fileSize,
    'txtParserVersion': txtParserVersion,
    'contentRevision': contentRevision,
    if (wordCount != null) 'wordCount': wordCount,
    if (chapterWordCounts != null && chapterWordCounts!.length == chapterCount)
      'chapterWordCounts': chapterWordCounts,
    if (sourcePath != null) 'sourcePath': sourcePath,
    if (coverImagePath != null) 'coverImagePath': coverImagePath,
    if (pageCount != null) 'pageCount': pageCount,
    if (embeddedFonts.isNotEmpty) 'embeddedFonts': embeddedFonts,
    if (isPrivate) 'private': true,
    if (groups.isNotEmpty) 'groups': groups,
    // Note: chapters are stored separately to reduce JSON size
    'chapterCount': chapterCount,
  };

  Book copyWith({
    String? title,
    String? author,
    List<Chapter>? chapters,
    int? contentRevision,
    int? wordCount,
    List<int>? chapterWordCounts,
    String? sourcePath,
    String? coverImagePath,
    int? pageCount,
    Map<String, String>? embeddedFonts,
    bool? isPrivate,
    List<String>? groups,
    bool clearWordCounts = false,
  }) {
    final nextChapters = chapters ?? this.chapters;
    return Book(
      id: id,
      title: title ?? this.title,
      author: author ?? this.author,
      format: format,
      chapters: nextChapters,
      chapterCount: chapters == null ? chapterCount : nextChapters.length,
      importDate: importDate,
      fileSize: fileSize,
      txtParserVersion: txtParserVersion,
      contentRevision: contentRevision ?? this.contentRevision,
      wordCount: clearWordCounts ? null : wordCount ?? this.wordCount,
      chapterWordCounts: clearWordCounts
          ? null
          : chapterWordCounts ?? this.chapterWordCounts,
      sourcePath: sourcePath ?? this.sourcePath,
      coverImagePath: coverImagePath ?? this.coverImagePath,
      pageCount: pageCount ?? this.pageCount,
      embeddedFonts: embeddedFonts ?? this.embeddedFonts,
      isPrivate: isPrivate ?? this.isPrivate,
      groups: groups == null ? this.groups : normalizeBookGroups(groups),
    );
  }

  /// Creates a Book from JSON. Chapters must be provided separately.
  factory Book.fromJson(Map<String, dynamic> json, List<Chapter> chapters) {
    final id = json['id'];
    final title = json['title'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('书籍 ID 无效');
    }
    if (title is! String || title.trim().isEmpty) {
      throw const FormatException('书名无效');
    }
    final rawImportDate = json['importDate'];
    final importDate = rawImportDate is String
        ? DateTime.tryParse(rawImportDate) ?? DateTime.now()
        : DateTime.now();
    final rawFileSize = json['fileSize'];
    final fileSize = rawFileSize is num
        ? rawFileSize.toInt().clamp(0, 0x7fffffffffffffff)
        : 0;
    final rawChapterCount = json['chapterCount'];
    final chapterCount = rawChapterCount is num
        ? rawChapterCount.toInt().clamp(0, 0x7fffffff)
        : chapters.length;
    final rawTxtParserVersion = json['txtParserVersion'];
    final txtParserVersion = rawTxtParserVersion is num
        ? rawTxtParserVersion.toInt().clamp(0, 0x7fffffff)
        : 0;
    final rawWordCount = json['wordCount'];
    final wordCount = rawWordCount is num
        ? rawWordCount.toInt().clamp(0, 0x7fffffffffffffff)
        : null;
    final rawChapterWordCounts = json['chapterWordCounts'];
    List<int>? chapterWordCounts;
    if (rawChapterWordCounts is List &&
        rawChapterWordCounts.length == chapterCount) {
      final parsed = <int>[];
      for (final value in rawChapterWordCounts) {
        if (value is! num || !value.isFinite || value < 0) {
          parsed.clear();
          break;
        }
        parsed.add(value.toInt().clamp(0, 0x7fffffffffffffff));
      }
      if (parsed.length == chapterCount) {
        chapterWordCounts = List<int>.unmodifiable(parsed);
      }
    }
    final rawSourcePath = json['sourcePath'];
    final sourcePath =
        rawSourcePath is String && rawSourcePath.trim().isNotEmpty
        ? rawSourcePath.trim()
        : null;
    final rawPageCount = json['pageCount'];
    final pageCount = rawPageCount is num
        ? rawPageCount.toInt().clamp(1, 0x7fffffff)
        : null;
    final rawCoverImagePath = json['coverImagePath'];
    final coverImagePath =
        rawCoverImagePath is String && rawCoverImagePath.trim().isNotEmpty
        ? rawCoverImagePath.trim()
        : null;
    final embeddedFonts = <String, String>{};
    final rawEmbeddedFonts = json['embeddedFonts'];
    if (rawEmbeddedFonts is Map) {
      for (final entry in rawEmbeddedFonts.entries) {
        final family = entry.key;
        final path = entry.value;
        if (family is String &&
            family.trim().isNotEmpty &&
            family.length <= 160 &&
            path is String &&
            path.trim().isNotEmpty) {
          embeddedFonts[family.trim()] = path.trim();
        }
      }
    }

    return Book(
      id: id,
      title: title,
      author: json['author'] is String ? json['author'] as String : '',
      format: BookFormat.values.firstWhere(
        (f) => f.name == json['format'],
        orElse: () => BookFormat.txt,
      ),
      chapters: chapters,
      chapterCount: chapterCount,
      importDate: importDate,
      fileSize: fileSize,
      txtParserVersion: txtParserVersion,
      contentRevision: readContentRevision(json['contentRevision']),
      wordCount: wordCount,
      chapterWordCounts: chapterWordCounts,
      sourcePath: sourcePath,
      coverImagePath: coverImagePath,
      pageCount: pageCount,
      embeddedFonts: Map<String, String>.unmodifiable(embeddedFonts),
      isPrivate: json['private'] == true,
      groups: json['groups'] is Iterable
          ? normalizeBookGroups((json['groups'] as Iterable).cast<Object?>())
          : const <String>[],
    );
  }
}
