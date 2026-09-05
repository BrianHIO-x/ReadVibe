// Book and chapter data models.
// Backing fields keep the public constructor names stable while allowing the
// storage layer to override content getters with bounded lazy chapter proxies.
// ignore_for_file: prefer_initializing_formals

import 'book_content_revision.dart';

const currentTxtParserVersion = 3;

final _volumeChapterTitlePattern = RegExp(
  r'^(?:第[一二两三四五六七八九十百千万零〇０-９0-9]+卷|卷[一二两三四五六七八九十百千万零〇０-９0-9]+)',
);
final _introductoryChapterTitlePattern = RegExp(
  r'^(?:内容简介|作品简介|书籍简介|作者简介|编辑推荐|内容提要|出版说明|简介|前言|序言|序章|楔子|引子|开篇)(?:$|[\s　:：—（(【\[-])',
);
final _standaloneTailTitlePattern = RegExp(
  r'^(?:(?:后记|尾声|附录)(?:$|[\s　:：—（(【\[-])|番外(?:$|[\s　:：—（(【\[-]|第?[一二两三四五六七八九十百千万零〇０-９0-9]+[章节篇]?))',
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

class EpubTextRun {
  final String text;
  final EpubContentStyle style;

  const EpubTextRun({required this.text, required this.style});
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
  });

  bool get isText => kind == EpubContentBlockKind.text;
  bool get isImage => kind == EpubContentBlockKind.image;
}

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
    );
  }
}
