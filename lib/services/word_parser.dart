import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import 'txt_parser.dart';

const _documentChannel = MethodChannel('com.readvibe.app/document_parser');
const _maxWordFileBytes = 128 * 1024 * 1024;
const _maxDocxExpandedBytes = 320 * 1024 * 1024;

/// Word writes roughly fifteen bytes of markup for every byte of prose, so a
/// four megabyte novel arrives as sixty megabytes of XML. The main part is read
/// as a token stream rather than as a tree, which makes this cap a guard
/// against absurd input instead of the memory ceiling it used to be.
const _maxDocumentXmlBytes = 192 * 1024 * 1024;
const _maxFootnotesXmlBytes = 16 * 1024 * 1024;
const _maxRelationshipsXmlBytes = 8 * 1024 * 1024;
const _maxCorePropertiesBytes = 1024 * 1024;
const _maxArchiveEntries = 20000;
const _maxDocxImageBytes = 64 * 1024 * 1024;

/// Name of the inflated main part while it is being read. It lives inside the
/// book's own resource directory so an interrupted import cleans it up along
/// with everything else that import created.
const _docxBodySpillName = '.document.xml';

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
        () => _parseDocx(
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

Future<Book> _parseDocx(
  String filePath,
  String fileName,
  String bookId,
  DateTime importDate,
  String resourceDirectoryPath,
) async {
  final length = File(filePath).lengthSync();
  if (length <= 0) throw const FormatException('DOCX 文件为空');
  if (length > _maxWordFileBytes) {
    throw const FormatException('DOCX 文件过大，请选择小于 128 MB 的文档');
  }

  // Reading the container through a file stream keeps the compressed bytes off
  // the heap. Only the parts this parser opens are ever inflated.
  final input = InputFileStream(filePath);
  final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input);
  } on Object {
    input.closeSync();
    throw const FormatException('DOCX 文件无效、已损坏或已加密');
  }

  final resourceDirectory = Directory(resourceDirectoryPath)
    ..createSync(recursive: true);
  final spill = File(p.join(resourceDirectory.path, _docxBodySpillName));
  try {
    if (archive.files.length > _maxArchiveEntries) {
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
      final normalizedName = entry.name.replaceAll(r'\', '/').toLowerCase();
      archiveFiles.putIfAbsent(normalizedName, () => entry);
      if (normalizedName == 'word/document.xml') documentFile = entry;
    }
    if (documentFile == null) {
      throw const FormatException('DOCX 缺少主文档内容');
    }
    if (documentFile.size > _maxDocumentXmlBytes) {
      throw const FormatException('DOCX 正文过大，无法安全解析');
    }

    final relationships = _docxRelationships(archiveFiles);
    final footnotes = _docxFootnotes(archiveFiles);
    final imageStore = _DocxImageStore(
      archiveFiles: archiveFiles,
      relationships: relationships,
      outputDirectory: resourceDirectory,
    );

    // The main part is the only one that grows with the length of the book, so
    // it is inflated to disk and read back in chunks. A tree for the same part
    // costs more than ten times its size and is what used to exhaust memory on
    // an ordinary novel.
    _inflateToFile(documentFile, spill, _maxDocumentXmlBytes);
    final blocks = await _readDocxBody(spill, footnotes, imageStore);
    if (blocks.isEmpty) {
      throw const FormatException('DOCX 中没有可读取的正文、表格或图片');
    }

    final chapters = _docxChapters(blocks);
    final fallbackTitle = p.basenameWithoutExtension(fileName).trim();
    final metadata = _docxCoreProperties(archiveFiles);
    return Book(
      id: bookId,
      title: metadata.title.isNotEmpty
          ? metadata.title
          : (fallbackTitle.isEmpty ? '未命名书籍' : fallbackTitle),
      author: metadata.author,
      format: BookFormat.docx,
      chapters: chapters,
      importDate: importDate,
      fileSize: length,
      sourcePath: resourceDirectory.path,
    );
  } finally {
    try {
      if (spill.existsSync()) spill.deleteSync();
    } on FileSystemException {
      // The import rollback removes the whole resource directory, and storage
      // maintenance reclaims a spill file stranded by a crash.
    }
    input.closeSync();
  }
}

/// Writes one archive entry to [target] without keeping the inflated bytes.
/// The entry is refused as soon as it exceeds [maxBytes], so a container that
/// under-reports a part cannot fill the device while that part is inflated.
void _inflateToFile(ArchiveFile entry, File target, int maxBytes) {
  final output = _BoundedFileOutput(target.path, maxBytes);
  try {
    entry.writeContent(output);
  } finally {
    output.closeSync();
  }
}

/// A file sink that refuses to grow past [limit]. Inflating reads back recently
/// written bytes to resolve back-references, so [subset] stays delegated.
class _BoundedFileOutput extends OutputStream {
  _BoundedFileOutput(String path, this.limit)
    : _output = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);

  final OutputFileStream _output;
  final int limit;

  void _reserve(int count) {
    if (_output.length + count > limit) {
      throw const FormatException('DOCX 解压后的内容过大，无法安全解析');
    }
  }

  @override
  int get length => _output.length;

  @override
  bool get isOpen => _output.isOpen;

  @override
  void open() => _output.open();

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  void clear() => _output.clear();

  @override
  void flush() => _output.flush();

  @override
  void writeByte(int value) {
    _reserve(1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    _output.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    _output.writeStream(stream);
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
}

/// Reads the inflated main part as a token stream and returns the reading
/// blocks it describes. Only the paragraph or table being read is held, so the
/// walk costs the same for a short story and for a finished novel.
Future<List<EpubContentBlock>> _readDocxBody(
  File document,
  Map<String, String> footnotes,
  _DocxImageStore imageStore,
) async {
  final reader = _DocxBodyReader(footnotes: footnotes, imageStore: imageStore);
  try {
    await for (final events
        in document.openRead().transform(utf8.decoder).toXmlEvents()) {
      for (final event in events) {
        reader.handle(event);
      }
    }
  } on FormatException {
    throw const FormatException('DOCX 主文档数据已损坏');
  } on XmlException {
    throw const FormatException('DOCX 主文档数据已损坏');
  }
  if (!reader.sawBody) {
    throw const FormatException('DOCX 中没有可读取的正文');
  }
  return reader.blocks;
}

({String title, String author}) _docxCoreProperties(
  Map<String, ArchiveFile> archiveFiles,
) {
  final core = _parseDocxPart(
    archiveFiles,
    'docprops/core.xml',
    _maxCorePropertiesBytes,
  );
  if (core == null) return (title: '', author: '');
  String property(String name) =>
      core.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == name)
          .firstOrNull
          ?.innerText
          .trim() ??
      '';
  return (title: property('title'), author: property('creator'));
}

/// Parses one of the small side parts as a tree. These describe the document
/// rather than carry it, so their size does not follow the length of the book.
/// Each part is read once and then released; [ArchiveFile.clear] drops the
/// entry's own bytes as well, so no part may be parsed twice.
XmlDocument? _parseDocxPart(
  Map<String, ArchiveFile> archiveFiles,
  String path,
  int maxBytes,
) {
  final file = archiveFiles[path];
  if (file == null || file.size <= 0 || file.size > maxBytes) return null;
  try {
    return XmlDocument.parse(
      utf8.decode(file.readBytes() ?? const <int>[], allowMalformed: true),
    );
  } on Object {
    return null;
  } finally {
    file.clear();
  }
}

Map<String, String> _docxRelationships(Map<String, ArchiveFile> archiveFiles) {
  final document = _parseDocxPart(
    archiveFiles,
    'word/_rels/document.xml.rels',
    _maxRelationshipsXmlBytes,
  );
  if (document == null) return const {};
  final relationships = <String, String>{};
  for (final element in document.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'Relationship') continue;
    final id = _wordAttribute(element, 'Id');
    final target = _wordAttribute(element, 'Target');
    final targetMode = _wordAttribute(element, 'TargetMode').toLowerCase();
    if (id.isEmpty || target.isEmpty || targetMode == 'external') continue;
    final String decodedTarget;
    try {
      decodedTarget = Uri.decodeComponent(target);
    } on ArgumentError {
      continue;
    }
    final path = p.posix
        .normalize(p.posix.join('word', decodedTarget))
        .replaceFirst(RegExp(r'^/+'), '')
        .toLowerCase();
    if (path != '..' && !path.startsWith('../')) relationships[id] = path;
  }
  return relationships;
}

Map<String, String> _docxFootnotes(Map<String, ArchiveFile> archiveFiles) {
  final document = _parseDocxPart(
    archiveFiles,
    'word/footnotes.xml',
    _maxFootnotesXmlBytes,
  );
  if (document == null) return const {};
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
}

String _localName(String qualifiedName) {
  final separator = qualifiedName.indexOf(':');
  return separator < 0 ? qualifiedName : qualifiedName.substring(separator + 1);
}

String _eventAttribute(XmlStartElementEvent event, String localName) {
  for (final attribute in event.attributes) {
    if (_localName(attribute.name) == localName) return attribute.value;
  }
  return '';
}

/// True unless the toggle carries a value that switches it off. Word omits the
/// value when a property is on, so a bare `<w:b/>` means bold.
bool _docxToggleEnabled(String value) {
  final normalized = value.toLowerCase();
  return normalized != '0' && normalized != 'false' && normalized != 'none';
}

/// Rebuilds the reading blocks of `word/document.xml` from its token stream.
///
/// The element stack is kept as local names only, which is enough to reproduce
/// what the tree walk used to see while holding nothing but the current
/// paragraph. Paragraphs nested in a content control are read as well, so a
/// document whose body Word wrapped in `w:sdt` no longer imports empty.
class _DocxBodyReader {
  _DocxBodyReader({required this.footnotes, required this.imageStore});

  final Map<String, String> footnotes;
  final _DocxImageStore imageStore;
  final blocks = <EpubContentBlock>[];

  bool sawBody = false;

  /// Local names of the elements enclosing the current position.
  final _open = <String>[];

  int? _bodyDepth;
  int? _paragraphDepth;
  int? _tableDepth;

  // Paragraph being read.
  int? _paragraphPropertiesDepth;
  String _paragraphStyle = '';
  String _paragraphAlignment = '';
  final _paragraphRuns = <EpubTextRun>[];
  final _paragraphText = StringBuffer();
  final _paragraphImages = <EpubContentBlock>[];

  // Run being read.
  int? _runDepth;
  int? _runPropertiesDepth;
  int? _textDepth;
  final _runText = StringBuffer();
  bool? _runBold;
  bool? _runBoldComplex;
  bool? _runItalic;
  bool? _runItalicComplex;
  bool? _runUnderline;
  double? _runHalfPoints;
  int? _runColor;

  // Table being read.
  final _tableRows = <String>[];
  int? _rowDepth;
  final _rowCells = <String>[];
  int? _cellDepth;
  final _cellText = StringBuffer();

  void handle(XmlEvent event) {
    if (event is XmlStartElementEvent) {
      final local = _localName(event.name);
      _start(local, event);
      if (event.isSelfClosing) {
        _end(local);
      } else {
        _open.add(local);
      }
      return;
    }
    if (event is XmlEndElementEvent) {
      if (_open.isEmpty) return;
      _open.removeLast();
      _end(_localName(event.name));
      return;
    }
    if (event is XmlTextEvent) {
      _write(event.value);
    } else if (event is XmlCDATAEvent) {
      _write(event.value);
    }
  }

  int get _depth => _open.length;

  void _write(String value) {
    if (_textDepth == null || value.isEmpty) return;
    if (_cellDepth != null) {
      _cellText.write(value);
    } else {
      _runText.write(value);
    }
  }

  void _start(String local, XmlStartElementEvent event) {
    if (_bodyDepth == null) {
      if (local == 'body') {
        _bodyDepth = _depth;
        sawBody = true;
      }
      return;
    }
    if (_tableDepth != null) {
      _startInTable(local, event);
      return;
    }
    if (_paragraphDepth != null) {
      _startInParagraph(local, event);
      return;
    }
    if (local == 'p') {
      _paragraphDepth = _depth;
    } else if (local == 'tbl') {
      _tableDepth = _depth;
    }
  }

  void _end(String local) {
    if (_bodyDepth == null) return;
    if (_textDepth == _depth) _textDepth = null;
    if (_runPropertiesDepth == _depth) _runPropertiesDepth = null;
    if (_paragraphPropertiesDepth == _depth) _paragraphPropertiesDepth = null;
    if (_runDepth == _depth) {
      _closeRun();
      return;
    }
    if (_cellDepth == _depth) {
      _closeCell();
      return;
    }
    if (_rowDepth == _depth) {
      _closeRow();
      return;
    }
    if (_paragraphDepth == _depth) {
      _closeParagraph();
      return;
    }
    if (_tableDepth == _depth) {
      _closeTable();
      return;
    }
    if (_bodyDepth == _depth) _bodyDepth = null;
  }

  void _startInParagraph(String local, XmlStartElementEvent event) {
    if (_runDepth != null) {
      _startInRun(local, event);
      return;
    }
    if (local == 'r') {
      _runDepth = _depth;
      return;
    }
    if (_paragraphPropertiesDepth != null) {
      if (local == 'pStyle' && _paragraphStyle.isEmpty) {
        _paragraphStyle = _eventAttribute(event, 'val');
      } else if (local == 'jc' && _paragraphAlignment.isEmpty) {
        _paragraphAlignment = _eventAttribute(event, 'val');
      }
      return;
    }
    if (local == 'pPr' && _depth == _paragraphDepth! + 1) {
      _paragraphPropertiesDepth = _depth;
    }
  }

  void _startInRun(String local, XmlStartElementEvent event) {
    if (_runPropertiesDepth != null) {
      if (_depth == _runPropertiesDepth! + 1) _readRunProperty(local, event);
      return;
    }
    if (local == 'rPr' && _depth == _runDepth! + 1) {
      _runPropertiesDepth = _depth;
      return;
    }
    switch (local) {
      case 't':
      case 'delText':
      case 'instrText':
        _textDepth ??= _depth;
      case 'tab':
        _runText.write('\t');
      case 'br':
      case 'cr':
        _runText.write('\n');
      case 'noBreakHyphen':
        _runText.write('‑');
      case 'footnoteReference':
        final note = footnotes[_eventAttribute(event, 'id')];
        if (note != null) _runText.write('〔脚注：$note〕');
      case 'blip':
        final image = imageStore.extract(_eventAttribute(event, 'embed'));
        if (image != null) _paragraphImages.add(image);
    }
  }

  void _readRunProperty(String local, XmlStartElementEvent event) {
    switch (local) {
      case 'b':
        _runBold ??= _docxToggleEnabled(_eventAttribute(event, 'val'));
      case 'bCs':
        _runBoldComplex ??= _docxToggleEnabled(_eventAttribute(event, 'val'));
      case 'i':
        _runItalic ??= _docxToggleEnabled(_eventAttribute(event, 'val'));
      case 'iCs':
        _runItalicComplex ??= _docxToggleEnabled(_eventAttribute(event, 'val'));
      case 'u':
        _runUnderline ??= _docxToggleEnabled(_eventAttribute(event, 'val'));
      case 'sz':
        _runHalfPoints ??= double.tryParse(_eventAttribute(event, 'val'));
      case 'color':
        if (_runColor != null) return;
        final value = _eventAttribute(event, 'val');
        if (RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(value)) {
          _runColor = 0xff000000 | int.parse(value, radix: 16);
        }
    }
  }

  void _startInTable(String local, XmlStartElementEvent event) {
    if (_cellDepth != null) {
      switch (local) {
        case 't':
          _textDepth ??= _depth;
        case 'tab':
          _cellText.write('\t');
        case 'br':
        case 'cr':
          _cellText.write('\n');
        case 'footnoteReference':
          final note = footnotes[_eventAttribute(event, 'id')];
          if (note != null) _cellText.write('〔脚注：$note〕');
      }
      return;
    }
    if (_rowDepth != null) {
      if (local == 'tc' && _depth == _rowDepth! + 1) _cellDepth = _depth;
      return;
    }
    if (local == 'tr') _rowDepth = _depth;
  }

  void _closeRun() {
    _runDepth = null;
    final value = _runText.toString();
    _runText.clear();
    final style = EpubContentStyle(
      fontScale: _runHalfPoints == null
          ? 1
          : (_runHalfPoints! / 24).clamp(0.6, 2.5),
      fontWeight: (_runBold ?? false) || (_runBoldComplex ?? false) ? 700 : 400,
      italic: (_runItalic ?? false) || (_runItalicComplex ?? false),
      underline: _runUnderline ?? false,
      textIndentEm: 0,
      colorArgb: _runColor,
    );
    _runBold = null;
    _runBoldComplex = null;
    _runItalic = null;
    _runItalicComplex = null;
    _runUnderline = null;
    _runHalfPoints = null;
    _runColor = null;
    if (value.isEmpty) return;
    _paragraphRuns.add(EpubTextRun(text: value, style: style));
    _paragraphText.write(value);
  }

  void _closeParagraph() {
    _paragraphDepth = null;
    final normalizedText = _paragraphText.toString().trimRight();
    final normalizedStyleName = _paragraphStyle.toLowerCase();
    final isHeading =
        normalizedText.isNotEmpty &&
        (normalizedStyleName.startsWith('heading') ||
            normalizedStyleName.startsWith('标题') ||
            normalizedStyleName == 'title' ||
            detectTxtChapterTitle(normalizedText) != null);
    final alignment = switch (_paragraphAlignment.toLowerCase()) {
      'center' => 'center',
      'right' || 'end' => 'end',
      'both' || 'distribute' || 'thai_distribute' => 'justify',
      _ => 'start',
    };
    if (normalizedText.isNotEmpty) {
      blocks.add(
        EpubContentBlock(
          kind: EpubContentBlockKind.text,
          text: normalizedText,
          runs:
              _paragraphRuns.length == 1 &&
                  _isDefaultDocxStyle(_paragraphRuns.single.style)
              ? const <EpubTextRun>[]
              : List<EpubTextRun>.unmodifiable(_paragraphRuns),
          isHeading: isHeading,
          style: EpubContentStyle(
            fontScale: isHeading ? 1.25 : 1,
            fontWeight: isHeading ? 700 : 400,
            textAlign: alignment,
            textIndentEm: isHeading ? 0 : 2,
            marginTopEm: isHeading ? 0.65 : 0,
            marginBottomEm: isHeading ? 0.45 : 0,
          ),
        ),
      );
    }
    blocks.addAll(_paragraphImages);
    _paragraphStyle = '';
    _paragraphAlignment = '';
    _paragraphRuns.clear();
    _paragraphText.clear();
    _paragraphImages.clear();
  }

  void _closeCell() {
    _cellDepth = null;
    _rowCells.add(
      _cellText.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
    _cellText.clear();
  }

  void _closeRow() {
    _rowDepth = null;
    if (_rowCells.any((cell) => cell.isNotEmpty)) {
      _tableRows.add(_rowCells.join('　│　'));
    }
    _rowCells.clear();
  }

  void _closeTable() {
    _tableDepth = null;
    if (_tableRows.isNotEmpty) {
      blocks.add(
        EpubContentBlock(
          kind: EpubContentBlockKind.text,
          text: _tableRows.join('\n'),
          style: const EpubContentStyle(
            fontScale: 0.92,
            textIndentEm: 0,
            marginTopEm: 0.35,
            marginBottomEm: 0.35,
            backgroundColorArgb: 0x18000000,
          ),
        ),
      );
    }
    _tableRows.clear();
  }
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
          file.size > _maxDocxImageBytes) {
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
        // Word keeps pictures at their original resolution, so the bytes are
        // moved straight to disk instead of through a buffer.
        _inflateToFile(file, target, _maxDocxImageBytes);
      } on FileSystemException {
        return null;
      } on FormatException {
        // The entry inflated past what its header declared. A picture that
        // cannot be trusted is dropped; the prose around it still imports.
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
