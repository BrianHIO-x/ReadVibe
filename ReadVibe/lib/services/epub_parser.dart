import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/book.dart';

/// Parses an EPUB archive in spine order.
Future<Book> parseEpub(String filePath, String fileName) async {
  // ZIP inflation plus XML/HTML parsing can otherwise block every animation
  // frame while a large book is imported.
  return Isolate.run(() => _parseEpubSync(filePath, fileName));
}

Book _parseEpubSync(String filePath, String fileName) {
  final bytes = File(filePath).readAsBytesSync();
  if (bytes.isEmpty) throw const FormatException('EPUB 文件为空');

  late final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on FormatException {
    throw const FormatException('无效的 EPUB 文件：ZIP 数据已损坏');
  }
  if (archive.files.length > 20000) {
    throw const FormatException('EPUB 文件包含过多条目，无法安全解析');
  }
  const maxExpandedBytes = 512 * 1024 * 1024;
  var expandedBytes = 0;
  final archiveFiles = <String, ArchiveFile>{};
  for (final file in archive.files) {
    expandedBytes += file.size;
    if (expandedBytes > maxExpandedBytes) {
      throw const FormatException('EPUB 解压后的内容过大，无法安全解析');
    }
    archiveFiles.putIfAbsent(_normalizeArchivePath(file.name), () => file);
  }

  final containerFile = _findArchiveFile(
    archiveFiles,
    'META-INF/container.xml',
  );
  if (containerFile == null) {
    throw const FormatException('无效的 EPUB 文件：缺少 container.xml');
  }

  final container = _parseXml(containerFile, 'container.xml');
  final rootFile = _elementsNamed(container, 'rootfile').firstOrNull;
  final rawOpfPath = rootFile?.getAttribute('full-path');
  if (rawOpfPath == null || rawOpfPath.trim().isEmpty) {
    throw const FormatException('container.xml 中未找到 OPF 路径');
  }
  final opfPath = _normalizeArchivePath(rawOpfPath);

  final opfFile = _findArchiveFile(archiveFiles, opfPath);
  if (opfFile == null) {
    throw FormatException('无效的 EPUB 文件：无法读取 OPF ($opfPath)');
  }
  final opf = _parseXml(opfFile, 'OPF');
  final opfDir = p.posix.dirname(opfPath);

  final title = _firstElementText(opf, 'title');
  final author = _firstElementText(opf, 'creator');
  final manifest = _extractManifest(opf, opfDir);
  final spineIds = _elementsNamed(opf, 'itemref')
      .where(
        (element) =>
            element.getAttribute('linear')?.toLowerCase().trim() != 'no',
      )
      .map((element) => element.getAttribute('idref'))
      .whereType<String>()
      .toList();

  final chapters = <Chapter>[];
  for (final itemId in spineIds) {
    final contentPath = manifest[itemId];
    if (contentPath == null) continue;

    final contentFile = _findArchiveFile(archiveFiles, contentPath);
    if (contentFile == null) continue;

    final xhtml = _decodeMarkup(_bytesOf(contentFile));
    final document = html_parser.parse(xhtml);
    final chapterTitle =
        _extractChapterTitle(document) ?? '章节 ${chapters.length + 1}';
    var plainText = _documentToPlainText(document);
    if (plainText == chapterTitle) {
      plainText = '';
    } else if (plainText.startsWith('$chapterTitle\n')) {
      plainText = plainText.substring(chapterTitle.length).trimLeft();
    }
    if (plainText.isEmpty) continue;

    chapters.add(
      Chapter(index: chapters.length, title: chapterTitle, content: plainText),
    );
  }

  if (chapters.isEmpty) {
    throw const FormatException('无法从 EPUB 中解析出任何章节内容');
  }

  final now = DateTime.now();
  final fallbackTitle = fileName
      .replaceAll(RegExp(r'\.epub$', caseSensitive: false), '')
      .trim();
  return Book(
    id: 'epub_${now.microsecondsSinceEpoch}',
    title: title.isNotEmpty
        ? title
        : (fallbackTitle.isEmpty ? '未命名书籍' : fallbackTitle),
    author: author,
    format: BookFormat.epub,
    chapters: chapters,
    importDate: now,
    fileSize: bytes.length,
  );
}

Map<String, String> _extractManifest(XmlDocument opf, String opfDir) {
  final manifest = <String, String>{};
  for (final item in _elementsNamed(opf, 'item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id == null || href == null) continue;

    final pathWithoutFragment = href.split('#').first.split('?').first;
    final decodedPath = _safeDecodeUriComponent(pathWithoutFragment);
    final joined = opfDir == '.'
        ? decodedPath
        : p.posix.join(opfDir, decodedPath);
    manifest[id] = _normalizeArchivePath(joined);
  }
  return manifest;
}

Iterable<XmlElement> _elementsNamed(XmlNode node, String localName) {
  return node.descendants.whereType<XmlElement>().where(
    (element) => element.name.local == localName,
  );
}

String _firstElementText(XmlDocument document, String localName) {
  return _elementsNamed(document, localName).firstOrNull?.innerText.trim() ??
      '';
}

ArchiveFile? _findArchiveFile(
  Map<String, ArchiveFile> archiveFiles,
  String requestedPath,
) {
  return archiveFiles[_normalizeArchivePath(requestedPath)];
}

String _safeDecodeUriComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    // A few older EPUB generators leave a literal '%' in href values. The ZIP
    // entry may still be perfectly usable under that exact raw name.
    return value;
  }
}

String _normalizeArchivePath(String value) {
  var normalized = p.posix.normalize(value.replaceAll('\\', '/'));
  while (normalized.startsWith('/')) {
    normalized = normalized.substring(1);
  }
  return normalized;
}

List<int> _bytesOf(ArchiveFile file) {
  try {
    return file.content;
  } on FormatException {
    throw FormatException('EPUB 条目已损坏：${file.name}');
  }
}

XmlDocument _parseXml(ArchiveFile file, String label) {
  try {
    return XmlDocument.parse(_decodeMarkup(_bytesOf(file)));
  } on XmlException {
    throw FormatException('$label 格式错误，无法解析 EPUB');
  }
}

String _decodeMarkup(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), Endian.little);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), Endian.big);
  }

  var payload = bytes;
  if (payload.length >= 3 &&
      payload[0] == 0xEF &&
      payload[1] == 0xBB &&
      payload[2] == 0xBF) {
    payload = payload.sublist(3);
  }
  return utf8.decode(payload, allowMalformed: true);
}

String _decodeUtf16(List<int> bytes, Endian endian) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final codeUnits = <int>[];
  for (var offset = 0; offset + 1 < data.lengthInBytes; offset += 2) {
    codeUnits.add(data.getUint16(offset, endian));
  }
  return String.fromCharCodes(codeUnits);
}

String? _extractChapterTitle(Document document) {
  final heading = document.querySelector('h1, h2, h3')?.text.trim();
  if (heading != null && heading.isNotEmpty) return heading;
  final title = document.querySelector('title')?.text.trim();
  return title == null || title.isEmpty ? null : title;
}

const _blockElements = {
  'address',
  'article',
  'aside',
  'blockquote',
  'div',
  'dl',
  'dt',
  'dd',
  'figcaption',
  'figure',
  'footer',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tr',
  'ul',
};

String _documentToPlainText(Document document) {
  final output = StringBuffer();

  void visit(Node node) {
    if (node is Text) {
      output.write(node.data);
      return;
    }
    if (node is! Element) {
      for (final child in node.nodes) {
        visit(child);
      }
      return;
    }

    final tag = node.localName;
    if (tag == 'script' || tag == 'style' || tag == 'head') return;
    if (tag == 'br' || tag == 'hr') output.write('\n');
    for (final child in node.nodes) {
      visit(child);
    }
    if (_blockElements.contains(tag)) output.write('\n');
  }

  final root = document.body ?? document.documentElement;
  if (root == null) return '';
  visit(root);
  return output
      .toString()
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n[ \t]+'), '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
