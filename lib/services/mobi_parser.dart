import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_mobi/dart_mobi.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/book.dart';
import 'txt_parser.dart';

const _maxKindleFileBytes = 256 * 1024 * 1024;
const _maxKindleMarkupBytes = 512 * 1024 * 1024;

/// Imports DRM-free MOBI 7, AZW and AZW3/KF8 containers locally.
///
/// The parser never attempts to remove Amazon DRM. Encrypted books are
/// rejected with an explicit error so a corrupted/unsupported file is not
/// saved as an empty shelf entry.
Future<Book> parseKindleBook(String filePath, String fileName) async {
  final file = File(filePath);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
    throw const FormatException('Kindle 电子书为空或无法读取');
  }
  if (stat.size > _maxKindleFileBytes) {
    throw const FormatException('Kindle 电子书过大，请选择不超过 256 MB 的文件');
  }
  return Isolate.run(() => _parseKindleBook(filePath, fileName, stat.size));
}

Future<Book> _parseKindleBook(
  String filePath,
  String fileName,
  int fileSize,
) async {
  try {
    final bytes = File(filePath).readAsBytesSync();
    final data = await DartMobiReader.read(bytes);
    if ((data.record0header?.encryptionType ?? 0) != 0) {
      throw const FormatException('Kindle 电子书受 DRM 或加密保护，无法离线解析');
    }
    final raw = data.parseOpt(true, true, true);
    final markupParts = <List<int>>[];
    var markupBytes = 0;
    var part = raw.markup;
    var visitedParts = 0;
    while (part != null && visitedParts++ < 100000) {
      final bytes = part.data;
      if (bytes != null && bytes.isNotEmpty) {
        markupBytes += bytes.length;
        if (markupBytes > _maxKindleMarkupBytes) {
          throw const FormatException('Kindle 电子书展开后的正文超过 512 MB');
        }
        markupParts.add(bytes);
      }
      part = part.next;
    }
    if (markupParts.isEmpty) {
      throw const FormatException('Kindle 电子书没有可读取的正文，文件可能受 DRM 保护');
    }
    final metadata = _kindleMetadata(data.mobiExthHeader);
    final markup = markupParts
        .map((bytes) => _decodeKindleMarkup(bytes, data.mobiHeader?.encoding))
        .join('\n');
    final plainText = _kindleMarkupToText(markup);
    if (plainText.trim().isEmpty) {
      throw const FormatException('Kindle 电子书没有可阅读文本，扫描版或受 DRM 文件暂不支持');
    }
    final lowerName = fileName.toLowerCase();
    final format = lowerName.endsWith('.azw3')
        ? BookFormat.azw3
        : lowerName.endsWith('.azw')
        ? BookFormat.azw
        : BookFormat.mobi;
    return buildBookFromText(
      content: plainText,
      fileName: fileName,
      format: format,
      fileSize: fileSize,
      title: metadata.title.isNotEmpty
          ? metadata.title
          : data.mobiHeader?.fullname,
      author: metadata.author,
    );
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    final message = error.toString().toLowerCase();
    if (message.contains('drm') ||
        message.contains('encrypt') ||
        message.contains('voucher')) {
      throw const FormatException('Kindle 电子书受 DRM 或加密保护，无法离线解析');
    }
    throw const FormatException('Kindle 电子书无效、已损坏或暂不受支持');
  }
}

({String title, String author}) _kindleMetadata(MobiExthHeader? first) {
  var current = first;
  var title = '';
  final authors = <String>[];
  var visited = 0;
  while (current != null && visited++ < 10000) {
    final tag = current.tag;
    final data = current.data;
    if (data != null && data.isNotEmpty) {
      final value = utf8.decode(data, allowMalformed: true).trim();
      if ((tag == 99 || tag == 503) && value.isNotEmpty) title = value;
      if (tag == 100 && value.isNotEmpty && !authors.contains(value)) {
        authors.add(value);
      }
    }
    current = current.next;
  }
  return (title: title, author: authors.join('、'));
}

String _decodeKindleMarkup(List<int> bytes, MobiEncoding? encoding) {
  if (encoding == MobiEncoding.CP1252) {
    return latin1.decode(bytes, allowInvalid: true);
  }
  if (encoding == MobiEncoding.UTF16 && bytes.length >= 2) {
    final littleEndian = bytes[0] == 0xff && bytes[1] == 0xfe;
    final start =
        (bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff)
        ? 2
        : 0;
    final units = <int>[];
    for (var index = start; index + 1 < bytes.length; index += 2) {
      units.add(
        littleEndian
            ? bytes[index] | (bytes[index + 1] << 8)
            : (bytes[index] << 8) | bytes[index + 1],
      );
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

String _kindleMarkupToText(String markup) {
  final withBreaks = markup
      .replaceAll('\u0000', '')
      .replaceAll(RegExp(r'<\s*(?:br|hr)\b[^>]*>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(
          r'<\s*/?\s*(?:p|div|section|article|blockquote|h[1-6]|li|tr|table)\b[^>]*>',
          caseSensitive: false,
        ),
        '\n',
      );
  final decoded = html_parser.parseFragment(withBreaks).text ?? '';
  return decoded
      .replaceAll(RegExp(r'[\t\x0B\f ]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
