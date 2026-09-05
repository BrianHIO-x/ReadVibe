import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import 'txt_parser.dart';

const _documentChannel = MethodChannel('com.readvibe.app/document_parser');
const _maxWordFileBytes = 128 * 1024 * 1024;
const _maxDocxExpandedBytes = 256 * 1024 * 1024;
const _maxDocumentXmlBytes = 96 * 1024 * 1024;

/// Imports modern DOCX locally in Dart and delegates the legacy binary DOC
/// container to Apache POI on Android. Both paths return plain text to the
/// existing chapter detector; no book text leaves the device.
Future<Book> parseWordDocument(
  String filePath,
  String fileName,
  AppDataDirectoryProvider storage,
) async {
  final extension = fileName.toLowerCase();
  if (extension.endsWith('.docx')) {
    final now = DateTime.now();
    final bookId = 'docx_${now.microsecondsSinceEpoch}';
    final root = await storage.getAppDataDirectory();
    final resourceDirectory = Directory(p.join(root.path, 'word', bookId));
    try {
      return await Isolate.run(
        () => _parseDocxSync(
          filePath,
          fileName,
          bookId,
          now,
          resourceDirectory.path,
        ),
      );
    } on Object {
      try {
        if (await resourceDirectory.exists()) {
          await resourceDirectory.delete(recursive: true);
        }
      } on FileSystemException {
        // Storage maintenance can retry an interrupted resource cleanup.
      }
      rethrow;
    }
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
    final rawDocument = await _documentChannel
        .invokeMapMethod<Object?, Object?>('extractLegacyDoc', {
          'filePath': filePath,
        });
    final content = rawDocument?['content'];
    if (content is! String) {
      throw const FormatException('DOC 文档未返回可阅读内容');
    }
    final title = rawDocument?['title'];
    final author = rawDocument?['author'];
    return await Isolate.run(
      () => buildBookFromText(
        content: content,
        fileName: fileName,
        format: BookFormat.doc,
        fileSize: stat.size,
        title: title is String ? title : null,
        author: author is String ? author : null,
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

Book _parseDocxSync(
  String filePath,
  String fileName,
  String bookId,
  DateTime importDate,
  String resourceDirectoryPath,
) {
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
  final archiveFiles = <String, ArchiveFile>{};
  ArchiveFile? documentFile;
  for (final entry in archive.files) {
    expandedBytes += entry.size;
    if (expandedBytes > _maxDocxExpandedBytes) {
      throw const FormatException('DOCX 解压后的内容过大，无法安全解析');
    }
    final normalizedName = entry.name.replaceAll('\\', '/');
    archiveFiles.putIfAbsent(normalizedName.toLowerCase(), () => entry);
    if (normalizedName.toLowerCase() == 'word/document.xml') {
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

  String coreProperty(String name) {
    final coreFile = archiveFiles['docprops/core.xml'];
    if (coreFile == null || coreFile.size > 1024 * 1024) return '';
    try {
      final core = XmlDocument.parse(
        utf8.decode(coreFile.content as List<int>, allowMalformed: false),
      );
      return core.descendants
              .whereType<XmlElement>()
              .where((element) => element.name.local == name)
              .firstOrNull
              ?.innerText
              .trim() ??
          '';
    } on Object {
      return '';
    }
  }

  final relationships = _docxRelationships(archiveFiles);
  final footnotes = _docxFootnotes(archiveFiles);
  final resourceDirectory = Directory(resourceDirectoryPath)
    ..createSync(recursive: true);
  final imageStore = _DocxImageStore(
    archiveFiles: archiveFiles,
    relationships: relationships,
    outputDirectory: resourceDirectory,
  );
  final blocks = <EpubContentBlock>[];
  for (final child in body.childElements) {
    if (child.name.local == 'p') {
      blocks.addAll(_docxParagraphBlocks(child, footnotes, imageStore));
    } else if (child.name.local == 'tbl') {
      final table = _docxTableBlock(child, footnotes);
      if (table != null) blocks.add(table);
    }
  }
  if (blocks.isEmpty) {
    throw const FormatException('DOCX 中没有可读取的正文、表格或图片');
  }

  final chapters = _docxChapters(blocks);
  final fallbackTitle = p.basenameWithoutExtension(fileName).trim();
  final metadataTitle = coreProperty('title');
  return Book(
    id: bookId,
    title: metadataTitle.isNotEmpty
        ? metadataTitle
        : (fallbackTitle.isEmpty ? '未命名书籍' : fallbackTitle),
    author: coreProperty('creator'),
    format: BookFormat.docx,
    chapters: chapters,
    importDate: importDate,
    fileSize: length,
    sourcePath: resourceDirectory.path,
  );
}

Map<String, String> _docxRelationships(Map<String, ArchiveFile> archiveFiles) {
  final file = archiveFiles['word/_rels/document.xml.rels'];
  if (file == null || file.size > 8 * 1024 * 1024) return const {};
  try {
    final document = XmlDocument.parse(
      utf8.decode(file.content as List<int>, allowMalformed: false),
    );
    final relationships = <String, String>{};
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.name.local != 'Relationship') continue;
      final id = _wordAttribute(element, 'Id');
      final target = _wordAttribute(element, 'Target');
      final targetMode = _wordAttribute(element, 'TargetMode').toLowerCase();
      if (id.isEmpty || target.isEmpty || targetMode == 'external') continue;
      final path = p.posix
          .normalize(p.posix.join('word', Uri.decodeComponent(target)))
          .replaceFirst(RegExp(r'^/+'), '')
          .toLowerCase();
      if (path != '..' && !path.startsWith('../')) relationships[id] = path;
    }
    return relationships;
  } on Object {
    return const {};
  }
}

Map<String, String> _docxFootnotes(Map<String, ArchiveFile> archiveFiles) {
  final file = archiveFiles['word/footnotes.xml'];
  if (file == null || file.size > 32 * 1024 * 1024) return const {};
  try {
    final document = XmlDocument.parse(
      utf8.decode(file.content as List<int>, allowMalformed: false),
    );
    final notes = <String, String>{};
    for (final footnote in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'footnote',
    )) {
      final id = _wordAttribute(footnote, 'id');
      final parsed = int.tryParse(id);
      if (parsed == null || parsed < 0) continue;
      final text = _docxElementText(footnote).trim();
      if (text.isNotEmpty) notes[id] = text;
    }
    return notes;
  } on Object {
    return const {};
  }
}

List<EpubContentBlock> _docxParagraphBlocks(
  XmlElement paragraph,
  Map<String, String> footnotes,
  _DocxImageStore imageStore,
) {
  final paragraphProperties = paragraph.childElements
      .where((element) => element.name.local == 'pPr')
      .firstOrNull;
  final styleName = paragraphProperties?.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'pStyle')
      .map((element) => _wordAttribute(element, 'val'))
      .where((value) => value.isNotEmpty)
      .firstOrNull;
  final alignmentValue = paragraphProperties?.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'jc')
      .map((element) => _wordAttribute(element, 'val').toLowerCase())
      .where((value) => value.isNotEmpty)
      .firstOrNull;
  final runs = <EpubTextRun>[];
  final images = <EpubContentBlock>[];
  final text = StringBuffer();

  for (final run in paragraph.descendants.whereType<XmlElement>().where(
    (element) => element.name.local == 'r',
  )) {
    final runText = StringBuffer();
    for (final node in run.descendants.whereType<XmlElement>()) {
      switch (node.name.local) {
        case 't':
        case 'delText':
        case 'instrText':
          runText.write(node.innerText);
        case 'tab':
          runText.write('\t');
        case 'br':
        case 'cr':
          runText.write('\n');
        case 'noBreakHyphen':
          runText.write('‑');
        case 'footnoteReference':
          final note = footnotes[_wordAttribute(node, 'id')];
          if (note != null) runText.write('〔脚注：$note〕');
        case 'blip':
          final relationshipId = _wordAttribute(node, 'embed');
          final image = imageStore.extract(relationshipId);
          if (image != null) images.add(image);
      }
    }
    final value = runText.toString();
    if (value.isEmpty) continue;
    final style = _docxRunStyle(run);
    runs.add(EpubTextRun(text: value, style: style));
    text.write(value);
  }

  final normalizedText = text.toString().trimRight();
  final normalizedStyleName = styleName?.toLowerCase() ?? '';
  final isHeading =
      normalizedText.isNotEmpty &&
      (normalizedStyleName.startsWith('heading') ||
          normalizedStyleName.startsWith('标题') ||
          normalizedStyleName == 'title' ||
          detectTxtChapterTitle(normalizedText) != null);
  final alignment = switch (alignmentValue) {
    'center' => 'center',
    'right' || 'end' => 'end',
    'both' || 'distribute' || 'thai_distribute' => 'justify',
    _ => 'start',
  };
  final result = <EpubContentBlock>[];
  if (normalizedText.isNotEmpty) {
    final blockStyle = EpubContentStyle(
      fontScale: isHeading ? 1.25 : 1,
      fontWeight: isHeading ? 700 : 400,
      textAlign: alignment,
      textIndentEm: isHeading ? 0 : 2,
      marginTopEm: isHeading ? 0.65 : 0,
      marginBottomEm: isHeading ? 0.45 : 0,
    );
    result.add(
      EpubContentBlock(
        kind: EpubContentBlockKind.text,
        text: normalizedText,
        runs: runs.length == 1 && _isDefaultDocxStyle(runs.single.style)
            ? const <EpubTextRun>[]
            : List<EpubTextRun>.unmodifiable(runs),
        isHeading: isHeading,
        style: blockStyle,
      ),
    );
  }
  result.addAll(images);
  return result;
}

EpubContentBlock? _docxTableBlock(
  XmlElement table,
  Map<String, String> footnotes,
) {
  final rows = <String>[];
  for (final row in table.descendants.whereType<XmlElement>().where(
    (element) => element.name.local == 'tr',
  )) {
    final cells = <String>[];
    for (final cell in row.childElements.where(
      (element) => element.name.local == 'tc',
    )) {
      final text = _docxElementText(
        cell,
        footnotes: footnotes,
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      cells.add(text);
    }
    if (cells.any((cell) => cell.isNotEmpty)) rows.add(cells.join('　│　'));
  }
  if (rows.isEmpty) return null;
  return EpubContentBlock(
    kind: EpubContentBlockKind.text,
    text: rows.join('\n'),
    style: const EpubContentStyle(
      fontScale: 0.92,
      textIndentEm: 0,
      marginTopEm: 0.35,
      marginBottomEm: 0.35,
      backgroundColorArgb: 0x18000000,
    ),
  );
}

EpubContentStyle _docxRunStyle(XmlElement run) {
  final properties = run.childElements
      .where((element) => element.name.local == 'rPr')
      .firstOrNull;
  if (properties == null) return const EpubContentStyle(textIndentEm: 0);
  bool enabled(String name) {
    final element = properties.childElements
        .where((candidate) => candidate.name.local == name)
        .firstOrNull;
    if (element == null) return false;
    final value = _wordAttribute(element, 'val').toLowerCase();
    return value != '0' && value != 'false' && value != 'none';
  }

  final halfPoints = properties.childElements
      .where((element) => element.name.local == 'sz')
      .map((element) => double.tryParse(_wordAttribute(element, 'val')))
      .whereType<double>()
      .firstOrNull;
  final rawColor = properties.childElements
      .where((element) => element.name.local == 'color')
      .map((element) => _wordAttribute(element, 'val'))
      .where((value) => RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(value))
      .firstOrNull;
  final color = rawColor == null
      ? null
      : 0xff000000 | int.parse(rawColor, radix: 16);
  return EpubContentStyle(
    fontScale: halfPoints == null ? 1 : (halfPoints / 24).clamp(0.6, 2.5),
    fontWeight: enabled('b') || enabled('bCs') ? 700 : 400,
    italic: enabled('i') || enabled('iCs'),
    underline: enabled('u'),
    textIndentEm: 0,
    colorArgb: color,
  );
}

bool _isDefaultDocxStyle(EpubContentStyle style) =>
    style.fontScale == 1 &&
    style.fontWeight == 400 &&
    !style.italic &&
    !style.underline &&
    style.colorArgb == null;

String _docxElementText(
  XmlElement element, {
  Map<String, String> footnotes = const {},
}) {
  final output = StringBuffer();
  for (final node in element.descendants.whereType<XmlElement>()) {
    switch (node.name.local) {
      case 't':
        output.write(node.innerText);
      case 'tab':
        output.write('\t');
      case 'br':
      case 'cr':
        output.write('\n');
      case 'footnoteReference':
        final note = footnotes[_wordAttribute(node, 'id')];
        if (note != null) output.write('〔脚注：$note〕');
    }
  }
  return output.toString();
}

String _wordAttribute(XmlElement element, String localName) =>
    element.attributes
        .where((attribute) => attribute.name.local == localName)
        .map((attribute) => attribute.value)
        .firstOrNull ??
    '';

List<Chapter> _docxChapters(List<EpubContentBlock> blocks) {
  final chapterGroups = <({String title, List<EpubContentBlock> blocks})>[];
  final hasHeadings = blocks.any(
    (block) => block.isText && block.isHeading && block.text.trim().isNotEmpty,
  );
  var title = hasHeadings ? '开篇' : '全文';
  var active = <EpubContentBlock>[];

  void flush() {
    if (active.isEmpty) return;
    chapterGroups.add((title: title, blocks: active));
    active = <EpubContentBlock>[];
  }

  for (final block in blocks) {
    if (block.isText && block.isHeading && block.text.trim().isNotEmpty) {
      if (active.isNotEmpty) flush();
      title = block.text.trim();
    }
    active.add(block);
  }
  flush();
  if (chapterGroups.isEmpty) {
    throw const FormatException('DOCX 没有可保存的阅读内容');
  }

  String? activeVolume;
  return List<Chapter>.generate(chapterGroups.length, (index) {
    final group = chapterGroups[index];
    if (isVolumeChapterTitle(group.title)) activeVolume = group.title;
    var body = group.blocks.where(
      (block) =>
          block.isText && !block.isHeading && block.text.trim().isNotEmpty,
    );
    if (body.isEmpty) {
      body = group.blocks.where(
        (block) => block.isText && block.text.trim().isNotEmpty,
      );
    }
    return Chapter(
      index: index,
      title: group.title,
      content: body.map((block) => block.text.trim()).join('\n'),
      volumeTitle: isStandaloneChapterTitle(group.title) ? null : activeVolume,
      epubBlocks: List<EpubContentBlock>.unmodifiable(group.blocks),
    );
  }, growable: false);
}

class _DocxImageStore {
  final Map<String, ArchiveFile> archiveFiles;
  final Map<String, String> relationships;
  final Directory outputDirectory;
  final Map<String, EpubContentBlock?> _cache = <String, EpubContentBlock?>{};

  _DocxImageStore({
    required this.archiveFiles,
    required this.relationships,
    required this.outputDirectory,
  });

  EpubContentBlock? extract(String relationshipId) {
    if (relationshipId.isEmpty) return null;
    return _cache.putIfAbsent(relationshipId, () {
      final path = relationships[relationshipId];
      final file = path == null ? null : archiveFiles[path];
      if (path == null ||
          file == null ||
          file.size <= 0 ||
          file.size > 64 * 1024 * 1024) {
        return null;
      }
      final extension = p.posix.extension(path).toLowerCase();
      const allowed = <String>{
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.bmp',
        '.webp',
      };
      if (!allowed.contains(extension)) return null;
      final target = File(
        p.join(outputDirectory.path, 'image_${_cache.length}$extension'),
      );
      try {
        target.writeAsBytesSync(file.content as List<int>, flush: true);
      } on FileSystemException {
        return null;
      }
      return EpubContentBlock(
        kind: EpubContentBlockKind.image,
        imagePath: target.path,
        altText: p.posix.basename(path),
        style: const EpubContentStyle(
          textIndentEm: 0,
          marginTopEm: 0.35,
          marginBottomEm: 0.35,
        ),
      );
    });
  }
}
