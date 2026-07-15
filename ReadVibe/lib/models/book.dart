// Book and chapter data models.

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

enum BookFormat { txt, epub, docx, doc }

class Chapter {
  final int index;
  final String title;
  final String content;
  final String? volumeTitle;

  const Chapter({
    required this.index,
    required this.title,
    required this.content,
    this.volumeTitle,
  });
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
  final int? wordCount;
  final List<int>? chapterWordCounts;

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
    this.wordCount,
    this.chapterWordCounts,
  }) : _storedChapterCount = chapterCount;

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
    if (wordCount != null) 'wordCount': wordCount,
    if (chapterWordCounts != null && chapterWordCounts!.length == chapterCount)
      'chapterWordCounts': chapterWordCounts,
    // Note: chapters are stored separately to reduce JSON size
    'chapterCount': chapterCount,
  };

  Book copyWith({String? title, int? wordCount, List<int>? chapterWordCounts}) {
    return Book(
      id: id,
      title: title ?? this.title,
      author: author,
      format: format,
      chapters: chapters,
      chapterCount: chapterCount,
      importDate: importDate,
      fileSize: fileSize,
      txtParserVersion: txtParserVersion,
      wordCount: wordCount ?? this.wordCount,
      chapterWordCounts: chapterWordCounts ?? this.chapterWordCounts,
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
      wordCount: wordCount,
      chapterWordCounts: chapterWordCounts,
    );
  }
}
