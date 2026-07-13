// Book and chapter data models.

const currentTxtParserVersion = 2;

enum BookFormat { txt, epub }

class Chapter {
  final int index;
  final String title;
  final String content;

  const Chapter({
    required this.index,
    required this.title,
    required this.content,
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
    // Note: chapters are stored separately to reduce JSON size
    'chapterCount': chapterCount,
  };

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
    );
  }
}
