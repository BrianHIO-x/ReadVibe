import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import '../models/book.dart';
import 'txt_parser.dart';

const _documentChannel = MethodChannel('com.readvibe.app/document_parser');
const _maxWordFileBytes = 128 * 1024 * 1024;
const _maxDocxExpandedBytes = 256 * 1024 * 1024;
const _maxDocumentXmlBytes = 96 * 1024 * 1024;

/// Imports modern DOCX locally in Dart and delegates the legacy binary DOC
/// container to Apache POI on Android. Both paths return plain text to the
/// existing chapter detector; no book text leaves the device.
Future<Book> parseWordDocument(String filePath, String fileName) async {
  final extension = fileName.toLowerCase();
  if (extension.endsWith('.docx')) {
    return Isolate.run(() => _parseDocxSync(filePath, fileName));
  }
  if (!extension.endsWith('.doc')) {
    throw const FormatException('仅支持 DOCX 或 DOC 文档');
  }

  final file = File(filePath);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
    throw const FormatException('DOC 文件为空或无法读取');
  }
  if (stat.size > _maxWordFileBytes) {
    throw const FormatException('DOC 文件过大，请选择小于 128 MB 的文档');
  }

  try {
    final content = await _documentChannel.invokeMethod<String>(
      'extractLegacyDoc',
      {'filePath': filePath},
    );
    if (content == null) {
      throw const FormatException('DOC 文档未返回可阅读内容');
    }
    return Isolate.run(
      () => buildBookFromText(
        content: content,
        fileName: fileName,
        format: BookFormat.doc,
        fileSize: stat.size,
      ),
    );
  } on PlatformException catch (error) {
    final message = error.message?.trim();
    throw FormatException(
      message == null || message.isEmpty
          ? 'DOC 文档无法解析，可能已损坏或加密'
          : 'DOC 文档无法解析：$message',
    );
  }
}

Book _parseDocxSync(String filePath, String fileName) {
  final file = File(filePath);
  final length = file.lengthSync();
  if (length <= 0) throw const FormatException('DOCX 文件为空');
  if (length > _maxWordFileBytes) {
    throw const FormatException('DOCX 文件过大，请选择小于 128 MB 的文档');
  }

  late final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  } on Object {
    throw const FormatException('DOCX 文件无效、已损坏或已加密');
  }
  if (archive.files.length > 20000) {
    throw const FormatException('DOCX 包含过多内部条目，无法安全解析');
  }

  var expandedBytes = 0;
  ArchiveFile? documentFile;
  for (final entry in archive.files) {
    expandedBytes += entry.size;
    if (expandedBytes > _maxDocxExpandedBytes) {
      throw const FormatException('DOCX 解压后的内容过大，无法安全解析');
    }
    if (entry.name.replaceAll('\\', '/').toLowerCase() == 'word/document.xml') {
      documentFile = entry;
    }
  }
  if (documentFile == null) {
    throw const FormatException('DOCX 缺少主文档内容');
  }
  if (documentFile.size > _maxDocumentXmlBytes) {
    throw const FormatException('DOCX 正文过大，无法安全解析');
  }

  late final XmlDocument document;
  try {
    final bytes = documentFile.content as List<int>;
    document = XmlDocument.parse(utf8.decode(bytes, allowMalformed: false));
  } on Object {
    throw const FormatException('DOCX 主文档数据已损坏');
  }

  final body = document.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'body')
      .firstOrNull;
  if (body == null) throw const FormatException('DOCX 中没有可读取的正文');

  final paragraphs = <String>[];
  for (final paragraph in body.descendants.whereType<XmlElement>().where(
    (element) => element.name.local == 'p',
  )) {
    final output = StringBuffer();
    for (final node in paragraph.descendants.whereType<XmlElement>()) {
      switch (node.name.local) {
        case 't':
          output.write(node.innerText);
        case 'tab':
          output.write('\t');
        case 'br':
        case 'cr':
          output.write('\n');
        case 'noBreakHyphen':
          output.write('‑');
      }
    }
    paragraphs.add(output.toString().trimRight());
  }

  return buildBookFromText(
    content: paragraphs.join('\n'),
    fileName: fileName,
    format: BookFormat.docx,
    fileSize: length,
  );
}
