import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:dart3_big5/big5.dart';

import '../models/book.dart';

const txtParagraphIndent = '　　';
const txtParagraphSeparator = '\n';

// TXT files exported by browsers, office software, and older ebook tools do
// not always use CR/LF. Treat the common Unicode and legacy separators as
// line breaks as well, otherwise a whole novel can become one giant line.
final _txtLineBreakPattern = RegExp(r'\r\n?|\n|\u000B|\f|\u0085|\u2028|\u2029');
final _commonChineseRunes =
    '的一是不了人我在有他這这為为個个們们來来時时說说書书閱讀读第章回卷內容内容簡介简介正文繁體体中文華华與与'.runes.toSet();

// A line such as "第一卷载官股——皇室内帑、户部出资。" is ordinary prose, not a
// chapter heading. Chinese headings may end in ! or ?, but a full stop, comma,
// or semicolon is a strong prose signal. Closing quotation marks are allowed.
final _proseEndingPattern = RegExp(r'[。，；,;][”’」』）)]*$');

final _markdownHeadingPrefix = RegExp(r'^(?:#{1,6}|＃{1,6})[ \t　]*(.+)$');
final _markdownHeadingSuffix = RegExp(r'[ \t　]+(?:#{1,6}|＃{1,6})[ \t　]*$');

/// Chapter markers are checked only after optional Markdown decoration has
/// been removed. This supports both ordinary TXT novels and Markdown-exported
/// text without treating an arbitrary `# heading` as a novel chapter.
final _chapterPatterns = [
  RegExp(r'^第[一二两三四五六七八九十百千万零〇０-９0-9]+[章回节卷集部篇]'),
  RegExp(r'^卷[一二两三四五六七八九十百千万零〇０-９0-9]+'),
  RegExp(r'^(?:Chapter|Part)\s*[0-9０-９IVXLCDM]+', caseSensitive: false),
  RegExp(
    r'^(?:内容简介|作品简介|书籍简介|作者简介|编辑推荐|内容提要|出版说明|简介|序言|序章|楔子|引子|前言|后记|尾声|附录)(?:$|[\s　:：—（(【\[-])',
  ),
  RegExp(
    r'^番外(?:第?[一二两三四五六七八九十百千万零〇０-９0-9]+[章节篇]?|[一二两三四五六七八九十百千万零〇０-９0-9]+)?',
  ),
];

// Novel-sized TXT files are a few megabytes; anything near a gigabyte would
// exhaust memory when decoded and split inside the worker isolate.
const _maxTxtFileBytes = 256 * 1024 * 1024;

/// Parses a TXT file and detects its UTF-8 or GBK encoding automatically.
Future<Book> parseTxt(String filePath, String fileName) async {
  // Decoding and chapter detection are CPU-heavy for novel-sized files. Keep
  // them off the UI isolate so the import spinner and Android system UI remain
  // responsive.
  return Isolate.run(() => _parseTxtSync(filePath, fileName));
}

Book _parseTxtSync(String filePath, String fileName) {
  final file = File(filePath);
  final length = file.lengthSync();
  if (length <= 0) throw const FormatException('TXT 文件为空或无法读取');
  if (length > _maxTxtFileBytes) {
    throw const FormatException('TXT 文件过大，请选择小于 256 MB 的文件');
  }
  final bytes = file.readAsBytesSync();
  final content = decodeTxtBytes(bytes);
  return buildBookFromText(
    content: content,
    fileName: fileName,
    format: BookFormat.txt,
    fileSize: bytes.length,
  );
}

/// Builds a chaptered local book from plain text extracted by any supported
/// container. DOC and DOCX reuse exactly the same chapter rules as TXT so the
/// directory and reading behavior stay consistent across import formats.
Book buildBookFromText({
  required String content,
  required String fileName,
  required BookFormat format,
  required int fileSize,
}) {
  final normalized = content
      .replaceAll('\u0000', '')
      .replaceAll('\u0007', '\n');
  if (normalized.trim().isEmpty) {
    throw FormatException('${format.name.toUpperCase()} 文件没有可阅读的正文');
  }
  final cleanTitle = fileName
      .replaceAll(RegExp(r'\.(?:txt|docx?|epub)$', caseSensitive: false), '')
      .trim();
  final now = DateTime.now();
  return Book(
    id: '${format.name}_${now.microsecondsSinceEpoch}',
    title: cleanTitle.isEmpty ? '未命名书籍' : cleanTitle,
    format: format,
    chapters: extractTxtChapters(splitTxtLines(normalized)),
    txtParserVersion: currentTxtParserVersion,
    importDate: now,
    fileSize: fileSize,
  );
}

/// Splits all common TXT line endings, including Unicode separators used by
/// copied webpages and some ebook conversion tools.
List<String> splitTxtLines(String content) =>
    content.split(_txtLineBreakPattern);

/// Returns a normalized chapter title when [sourceLine] has a supported novel
/// heading shape, otherwise returns null.
String? detectTxtChapterTitle(String sourceLine) =>
    _parseChapterHeading(sourceLine)?.title;

/// Reconstructs and reparses TXT books saved by an older parser. Legacy
/// chapter titles are included because an earlier false positive may have
/// moved a real body sentence into the title field. Synthetic app titles are
/// excluded because they never existed in the source file.
Book upgradeLegacyTxtBook(Book book) {
  if (book.format != BookFormat.txt ||
      book.txtParserVersion >= currentTxtParserVersion ||
      book.chapters.isEmpty) {
    return book;
  }

  final reconstructedLines = <String>[];
  for (final chapter in book.chapters) {
    final title = _trimTxtLine(chapter.title);
    if (title.isNotEmpty && title != '全文' && title != '开篇') {
      reconstructedLines.add(title);
    }
    reconstructedLines.addAll(splitTxtLines(chapter.content));
  }
  final chapters = extractTxtChapters(reconstructedLines);

  // Parser v2 discarded empty volume-marker lines before persistence, so those
  // exact strings cannot be recreated without the original file. This upgrade
  // still applies every v3 rule to surviving titles and body text instead of
  // leaving recoverable v2 books permanently on the old schema.

  return Book(
    id: book.id,
    title: book.title,
    author: book.author,
    format: book.format,
    chapters: chapters,
    importDate: book.importDate,
    fileSize: book.fileSize,
    txtParserVersion: currentTxtParserVersion,
  );
}

/// Decodes bytes as UTF-8 (including BOM) and falls back to GBK.
///
/// Chinese TXT novels commonly use either encoding. A strict UTF-8 attempt is
/// important: decoding malformed bytes permissively would hide GBK files behind
/// replacement characters instead of trying the correct codec.
String decodeTxtBytes(List<int> bytes) {
  var payload = bytes;
  if (payload.length >= 2 && payload[0] == 0xFF && payload[1] == 0xFE) {
    return _decodeUtf16(payload.sublist(2), Endian.little);
  }
  if (payload.length >= 2 && payload[0] == 0xFE && payload[1] == 0xFF) {
    return _decodeUtf16(payload.sublist(2), Endian.big);
  }
  if (payload.length >= 3 &&
      payload[0] == 0xEF &&
      payload[1] == 0xBB &&
      payload[2] == 0xBF) {
    payload = payload.sublist(3);
  }

  try {
    return utf8.decode(payload, allowMalformed: false);
  } on FormatException {
    final gbk = const GbkCodec(allowMalformed: true).decode(payload);
    final big5 = Big5.decode(payload);
    return _legacyChineseScore(big5) > _legacyChineseScore(gbk) ? big5 : gbk;
  }
}

int _legacyChineseScore(String text) {
  final sample = text.length <= 256 * 1024
      ? text
      : '${text.substring(0, 128 * 1024)}${text.substring(text.length - 128 * 1024)}';
  var score = 0;
  for (final rune in sample.runes) {
    if (rune == 0xfffd) {
      score -= 120;
    } else if ((rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
        (rune >= 0xe000 && rune <= 0xf8ff)) {
      score -= 40;
    } else if (rune >= 0x4e00 && rune <= 0x9fff) {
      score += 2;
      if (_commonChineseRunes.contains(rune)) score += 3;
    } else if (rune == 0x3002 ||
        rune == 0xff0c ||
        rune == 0xff1a ||
        rune == 0x3001) {
      score += 2;
    }
  }
  score +=
      RegExp(
        r'(?:第.{1,12}[章回卷節节篇]|chapter\s*\d+)',
        caseSensitive: false,
      ).allMatches(sample).length *
      20;
  return score;
}

String _decodeUtf16(List<int> bytes, Endian endian) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final codeUnits = <int>[];
  for (var offset = 0; offset + 1 < data.lengthInBytes; offset += 2) {
    codeUnits.add(data.getUint16(offset, endian));
  }
  return String.fromCharCodes(codeUnits);
}

List<Chapter> extractTxtChapters(List<String> lines) {
  final chapterStarts = <({int index, String title, String marker})>[];

  for (var i = 0; i < lines.length; i++) {
    final heading = _parseChapterHeading(lines[i]);
    if (heading != null) {
      // Lines such as "第一章正文如下" can occur immediately below a real
      // "第一章 标题" and resemble another heading. Suppress only an adjacent
      // duplicate. A later repeated number can be legitimate after a new volume.
      if (chapterStarts.isNotEmpty &&
          heading.marker == chapterStarts.last.marker &&
          !_containsReadableText(
            lines.getRange(chapterStarts.last.index + 1, i),
          )) {
        continue;
      }
      chapterStarts.add((
        index: i,
        title: heading.title,
        marker: heading.marker,
      ));
    }
  }

  if (chapterStarts.isEmpty) {
    return [
      Chapter(index: 0, title: '全文', content: normalizeTxtContent(lines)),
    ];
  }

  final chapters = <Chapter>[];
  String? activeVolumeTitle;

  // Never discard text before the first detected heading. It may be a preface,
  // publication information, or (as in the reported book) real opening prose.
  final openingContent = normalizeTxtContent(
    lines.getRange(0, chapterStarts.first.index),
  );
  if (openingContent.isNotEmpty) {
    chapters.add(
      Chapter(index: chapters.length, title: '开篇', content: openingContent),
    );
  }

  for (var i = 0; i < chapterStarts.length; i++) {
    final start = chapterStarts[i].index;
    final end = i < chapterStarts.length - 1
        ? chapterStarts[i + 1].index
        : lines.length;
    final content = normalizeTxtContent(lines.getRange(start + 1, end));
    final title = chapterStarts[i].title;
    if (isVolumeChapterTitle(title)) {
      activeVolumeTitle = title;
    }

    // Adjacent table-of-contents entries and duplicate headings used to create
    // selectable chapters with a completely blank page. Empty entries are not
    // useful reading destinations, so omit them.
    if (content.isEmpty) continue;
    chapters.add(
      Chapter(
        index: chapters.length,
        title: title,
        content: content,
        volumeTitle: isStandaloneChapterTitle(title) ? null : activeVolumeTitle,
      ),
    );
  }

  // If every apparent heading was empty, preserve the source as one readable
  // chapter instead of returning an empty book.
  return chapters.isEmpty
      ? [Chapter(index: 0, title: '全文', content: normalizeTxtContent(lines))]
      : chapters;
}

({String title, String marker})? _parseChapterHeading(String sourceLine) {
  final trimmed = _trimTxtLine(sourceLine);
  if (trimmed.isEmpty || trimmed.length > 160) return null;

  var title = trimmed;
  var explicitMarkdownHeading = false;
  final markdownMatch = _markdownHeadingPrefix.firstMatch(title);
  if (markdownMatch != null) {
    explicitMarkdownHeading = true;
    title = markdownMatch.group(1)!.trim();
    title = title.replaceFirst(_markdownHeadingSuffix, '').trimRight();
  }
  if (title.isEmpty || title.length > 120) return null;

  RegExpMatch? markerMatch;
  for (final pattern in _chapterPatterns) {
    markerMatch = pattern.firstMatch(title);
    if (markerMatch != null) break;
  }
  if (markerMatch == null) return null;

  // Explicit Markdown syntax is deliberate structure. Plain TXT lines need a
  // prose guard so "第一卷……。" remains body text instead of a false chapter.
  if (!explicitMarkdownHeading && _proseEndingPattern.hasMatch(title)) {
    return null;
  }

  final marker = markerMatch
      .group(0)!
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '');
  return (title: title, marker: _canonicalizeChapterMarker(marker));
}

String _canonicalizeChapterMarker(String marker) {
  final numbered = RegExp(r'^第(.+)([章回节卷集部篇])$').firstMatch(marker);
  if (numbered != null) {
    final number = _chapterNumberValue(numbered.group(1)!);
    if (number != null) return '第$number${numbered.group(2)!}';
  }

  final volume = RegExp(r'^卷(.+)$').firstMatch(marker);
  if (volume != null) {
    final number = _chapterNumberValue(volume.group(1)!);
    if (number != null) return '卷$number';
  }
  return marker;
}

int? _chapterNumberValue(String source) {
  const fullWidthDigits = '０１２３４５６７８９';
  final ascii = StringBuffer();
  var allDecimalDigits = true;
  for (final codeUnit in source.codeUnits) {
    final character = String.fromCharCode(codeUnit);
    if (codeUnit >= 0x30 && codeUnit <= 0x39) {
      ascii.write(character);
    } else {
      final fullWidthIndex = fullWidthDigits.indexOf(character);
      if (fullWidthIndex >= 0) {
        ascii.write(fullWidthIndex);
      } else {
        allDecimalDigits = false;
        break;
      }
    }
  }
  if (allDecimalDigits && ascii.isNotEmpty) {
    return int.tryParse(ascii.toString());
  }

  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000};
  final hasUnit = source.contains(RegExp(r'[十百千万]'));
  if (!hasUnit) {
    final result = StringBuffer();
    for (final character in source.split('')) {
      final digit = digits[character];
      if (digit == null) return null;
      result.write(digit);
    }
    return int.tryParse(result.toString());
  }

  var total = 0;
  var section = 0;
  var number = 0;
  var sawNumber = false;
  for (final character in source.split('')) {
    final digit = digits[character];
    if (digit != null) {
      number = digit;
      sawNumber = true;
      continue;
    }
    if (character == '万') {
      section = (section + number) * 10000;
      total += section;
      section = 0;
      number = 0;
      sawNumber = true;
      continue;
    }
    final unit = units[character];
    if (unit == null) return null;
    section += (number == 0 ? 1 : number) * unit;
    number = 0;
    sawNumber = true;
  }
  return sawNumber ? total + section + number : null;
}

String _trimTxtLine(String line) {
  var start = 0;
  var end = line.length;
  while (start < end && _isTxtEdgeWhitespace(line.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isTxtEdgeWhitespace(line.codeUnitAt(end - 1))) {
    end--;
  }
  return start == 0 && end == line.length ? line : line.substring(start, end);
}

bool _isTxtEdgeWhitespace(int codeUnit) {
  return codeUnit <= 0x20 ||
      codeUnit == 0x00A0 ||
      codeUnit == 0x3000 ||
      codeUnit == 0xFEFF;
}

bool _containsReadableText(Iterable<String> lines) {
  return lines.any((line) => line.trim().isNotEmpty);
}

/// Normalizes imported TXT body text into the app's default novel layout:
/// every non-empty source line becomes a paragraph, each paragraph starts with
/// two full-width spaces, and paragraphs are separated by one line break. The
/// reader setting decides whether to render an additional blank line.
String normalizeTxtContent(Iterable<String> lines) {
  return lines
      .map(_normalizeTxtParagraph)
      .where((paragraph) => paragraph.isNotEmpty)
      .join(txtParagraphSeparator);
}

String _normalizeTxtParagraph(String line) {
  final body = line.replaceFirst(RegExp(r'^[\s　]+'), '').trimRight();
  return body.isEmpty ? '' : '$txtParagraphIndent$body';
}
