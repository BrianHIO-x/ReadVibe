import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/book.dart';
import 'book_id.dart';
import 'epub_markup_decoder.dart';
import '../repositories/app_data_directory_provider.dart';

/// Resource limits are grouped so the security boundaries can be exercised by
/// small fixtures without allocating hundreds of megabytes in tests.
class EpubParseLimits {
  final int maxInputBytes;
  final int maxArchiveEntries;
  final int maxExpandedBytes;
  final int maxSingleImageBytes;

  const EpubParseLimits({
    this.maxInputBytes = 256 * 1024 * 1024,
    this.maxArchiveEntries = 20000,
    this.maxExpandedBytes = 512 * 1024 * 1024,
    this.maxSingleImageBytes = 64 * 1024 * 1024,
  }) : assert(maxInputBytes > 0),
       assert(maxArchiveEntries > 0),
       assert(maxExpandedBytes > 0),
       assert(maxSingleImageBytes > 0);
}

const _defaultEpubParseLimits = EpubParseLimits();

/// Parses an EPUB into the same chapter model used by TXT while retaining a
/// safe, offline subset of publisher CSS and local images.
Future<Book> parseEpub(
  String filePath,
  String fileName,
  AppDataDirectoryProvider storage, {
  EpubParseLimits limits = _defaultEpubParseLimits,
}) async {
  final now = DateTime.now();
  final bookId = nextBookId('epub', now: now);
  final root = await storage.getAppDataDirectory();
  final resourceDirectory = Directory(p.join(root.path, 'epub', bookId));
  // The worker gets a plain value object. It must not capture storage, a
  // Future or any callback, because the AOT isolate boundary only carries
  // sendable values.
  final task = _EpubParseTask(
    filePath: filePath,
    fileName: fileName,
    bookId: bookId,
    importMicroseconds: now.microsecondsSinceEpoch,
    resourceDirectoryPath: resourceDirectory.path,
    maxInputBytes: limits.maxInputBytes,
    maxArchiveEntries: limits.maxArchiveEntries,
    maxExpandedBytes: limits.maxExpandedBytes,
    maxSingleImageBytes: limits.maxSingleImageBytes,
  );
  try {
    return await Isolate.run(() => _parseEpubTask(task));
  } on Object {
    try {
      if (await resourceDirectory.exists()) {
        await resourceDirectory.delete(recursive: true);
      }
    } on FileSystemException {
      // The import error remains authoritative; cleanup can be retried when
      // the enclosing app data directory is next maintained.
    }
    rethrow;
  }
}

class _EpubParseTask {
  const _EpubParseTask({
    required this.filePath,
    required this.fileName,
    required this.bookId,
    required this.importMicroseconds,
    required this.resourceDirectoryPath,
    required this.maxInputBytes,
    required this.maxArchiveEntries,
    required this.maxExpandedBytes,
    required this.maxSingleImageBytes,
  });

  final String filePath;
  final String fileName;
  final String bookId;
  final int importMicroseconds;
  final String resourceDirectoryPath;
  final int maxInputBytes;
  final int maxArchiveEntries;
  final int maxExpandedBytes;
  final int maxSingleImageBytes;
}

Book _parseEpubTask(_EpubParseTask task) => _parseEpubSync(
  task.filePath,
  task.fileName,
  task.bookId,
  DateTime.fromMicrosecondsSinceEpoch(task.importMicroseconds),
  task.resourceDirectoryPath,
  EpubParseLimits(
    maxInputBytes: task.maxInputBytes,
    maxArchiveEntries: task.maxArchiveEntries,
    maxExpandedBytes: task.maxExpandedBytes,
    maxSingleImageBytes: task.maxSingleImageBytes,
  ),
);

Book _parseEpubSync(
  String filePath,
  String fileName,
  String bookId,
  DateTime importDate,
  String resourceDirectoryPath,
  EpubParseLimits limits,
) {
  final source = File(filePath);
  final stat = source.statSync();
  if (stat.type != FileSystemEntityType.file) {
    throw const FormatException('EPUB 文件不存在或无法读取');
  }
  final inputLength = source.lengthSync();
  if (inputLength <= 0) throw const FormatException('EPUB 文件为空');
  if (inputLength > limits.maxInputBytes) {
    throw FormatException(
      'EPUB 文件过大，请选择不超过 ${_formatMegabytes(limits.maxInputBytes)} MB 的文件',
    );
  }
  final bytes = source.readAsBytesSync();

  late final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on FormatException {
    throw const FormatException('无效的 EPUB 文件：ZIP 数据已损坏');
  }
  if (archive.files.length > limits.maxArchiveEntries) {
    throw const FormatException('EPUB 文件包含过多条目，无法安全解析');
  }

  var expandedBytes = 0;
  final archiveFiles = <String, ArchiveFile>{};
  for (final file in archive.files) {
    expandedBytes += file.size;
    if (expandedBytes > limits.maxExpandedBytes) {
      throw const FormatException('EPUB 解压后的内容过大，无法安全解析');
    }
    archiveFiles.putIfAbsent(_normalizeArchivePath(file.name), () => file);
  }
  final archiveLookup = _ArchiveLookup(archiveFiles);
  final encryptedPaths = _epubEncryptedPaths(archiveLookup);

  final containerFile = archiveLookup.find('META-INF/container.xml');
  if (containerFile == null) {
    throw const FormatException('无效的 EPUB 文件：缺少 container.xml');
  }
  final container = _parseXml(containerFile, 'container.xml', lenient: true);
  final opfSelection = _selectOpf(container, archiveLookup, encryptedPaths);
  final opf = opfSelection.opf;
  final opfPath = opfSelection.path;
  final opfDir = p.posix.dirname(opfPath);
  final title = _firstElementText(opf, 'title');
  final author = _firstElementText(opf, 'creator');
  final manifest = _extractManifest(opf, opfDir, archiveLookup);
  final navigation = _extractNavigation(opf, manifest, archiveLookup);
  final spineDocuments = _extractSpineDocuments(opf, manifest, archiveLookup);
  if (spineDocuments.any(
    (document) =>
        document.linear &&
        _isEncryptedPath(document.item.path, archiveLookup, encryptedPaths),
  )) {
    throw const FormatException('EPUB 正文章节受 DRM 或加密保护，无法离线解析');
  }

  final resourceDirectory = Directory(resourceDirectoryPath);
  resourceDirectory.createSync(recursive: true);
  final imageStore = _EpubImageStore(
    archiveLookup: archiveLookup,
    encryptedPaths: encryptedPaths,
    outputDirectory: resourceDirectory,
    maxSingleImageBytes: limits.maxSingleImageBytes,
  );
  final fontStore = _EpubFontStore(
    archiveLookup: archiveLookup,
    encryptedPaths: encryptedPaths,
    outputDirectory: resourceDirectory,
    bookId: bookId,
  );
  final coverArchivePath = _epubCoverArchivePath(opf, manifest);
  final coverImagePath = coverArchivePath == null
      ? null
      : imageStore.extractArchivePath(coverArchivePath)?.path;

  final assembler = _EpubBookAssembler(
    archiveLookup: archiveLookup,
    encryptedPaths: encryptedPaths,
    navigation: navigation,
    imageStore: imageStore,
    fontStore: fontStore,
  );

  // The reading order is the spine's linear order. Non-linear documents are
  // parsed only when links point at them (footnote pages) or when the linear
  // spine is too sparse to be the whole book.
  for (final document in spineDocuments) {
    if (!document.linear) continue;
    assembler.addDocument(document.item);
  }
  final sparseLinearText = assembler.plainTextLength < 400;
  if (sparseLinearText) {
    for (final document in spineDocuments) {
      if (document.linear) continue;
      assembler.addDocument(document.item);
    }
  }

  // Follow only newly discovered references. Rescanning every link and the
  // whole manifest each round would make a large book's import quadratic.
  final documentCandidates = <String, _ManifestItem>{};
  final manifestOrder = <String, int>{};
  var manifestIndex = 0;
  for (final item in manifest.values) {
    if (_documentKind(item, archiveLookup) == _EpubDocumentKind.unsupported) {
      continue;
    }
    documentCandidates[item.path] = item;
    manifestOrder.putIfAbsent(item.path, () => manifestIndex++);
  }
  final spineOrder = <String, int>{};
  for (var index = 0; index < spineDocuments.length; index++) {
    spineOrder[spineDocuments[index].item.path] = index;
  }
  int referenceRank(String path) {
    final spineIndex = spineOrder[path];
    if (spineIndex != null) return spineIndex;
    return spineDocuments.length + (manifestOrder[path] ?? 1 << 20);
  }

  final referenceQueue = ListQueue<String>();
  final queuedReferences = <String>{};
  void enqueueReferences(Iterable<String> references) {
    final ordered =
        references.where(documentCandidates.containsKey).toList(growable: false)
          ..sort(
            (first, second) =>
                referenceRank(first).compareTo(referenceRank(second)),
          );
    for (final path in ordered) {
      if (!queuedReferences.add(path) || assembler.hasProcessed(path)) {
        continue;
      }
      referenceQueue.add(path);
    }
  }

  enqueueReferences(assembler.takeNewReferences());
  var followGuard = 0;
  while (referenceQueue.isNotEmpty &&
      followGuard++ <= documentCandidates.length) {
    final path = referenceQueue.removeFirst();
    final item = documentCandidates[path];
    if (item == null || assembler.hasProcessed(path)) continue;
    if (assembler.addDocument(item)) {
      enqueueReferences(assembler.takeNewReferences());
    }
  }

  if (assembler.chapters.isEmpty) {
    // A damaged or empty spine is not a reason to reject a book whose manifest
    // still contains readable documents.
    for (final document in spineDocuments) {
      if (!document.linear) assembler.addDocument(document.item);
    }
    for (final item in manifest.values) {
      if (_documentKind(item, archiveLookup) != _EpubDocumentKind.unsupported) {
        assembler.addDocument(item);
      }
    }
  }
  if (assembler.chapters.isEmpty) {
    throw const FormatException('无法从 EPUB 中解析出任何章节内容或图片');
  }

  _resolveEpubLinks(
    assembler.chapters,
    pendingLinks: assembler.pendingLinks,
    chapterIndexByPath: assembler.chapterIndexByPath,
    anchorLocations: assembler.anchorLocations,
  );

  final fallbackTitle = fileName
      .replaceAll(RegExp(r'\.epub$', caseSensitive: false), '')
      .trim();
  return Book(
    id: bookId,
    title: title.isNotEmpty
        ? title
        : (fallbackTitle.isEmpty ? '未命名书籍' : fallbackTitle),
    author: author,
    format: BookFormat.epub,
    chapters: assembler.chapters,
    importDate: importDate,
    fileSize: inputLength,
    sourcePath: resourceDirectory.path,
    coverImagePath: coverImagePath,
    embeddedFonts: fontStore.embeddedFonts,
  );
}

/// Exact ZIP lookup with deterministic, ambiguity-free fallbacks.
///
/// A path is first matched byte-for-byte. Only when that misses do we try the
/// same path after URI decoding and then a single case-folded candidate. Two
/// entries that differ only by case are never guessed; an exact match still
/// wins over them.
class _ArchiveLookup {
  _ArchiveLookup(Map<String, ArchiveFile> files)
    : files = Map.unmodifiable(files) {
    for (final entry in files.entries) {
      _folded
          .putIfAbsent(entry.key.toLowerCase(), () => <String>[])
          .add(entry.key);
      final decoded = _normalizeArchivePath(_safeDecodeUriComponent(entry.key));
      final decodedKey = decoded.toLowerCase();
      if (decodedKey != entry.key.toLowerCase()) {
        _decoded.putIfAbsent(decodedKey, () => <String>[]).add(entry.key);
      }
    }
  }

  final Map<String, ArchiveFile> files;
  final Map<String, List<String>> _folded = <String, List<String>>{};
  final Map<String, List<String>> _decoded = <String, List<String>>{};

  ArchiveFile? find(String requestedPath) => resolve(requestedPath)?.file;

  /// Resolves a requested path to the actual normalized ZIP entry key.
  ///
  /// Callers that compare paths (DRM lists, manifest ids, links and anchors)
  /// must use this key on both sides; a case- or percent-variant of the same
  /// entry is not a different chapter.
  String? canonicalPath(String requestedPath) => resolve(requestedPath)?.path;

  ({String path, ArchiveFile file})? resolve(String requestedPath) {
    final normalized = _normalizeArchivePath(requestedPath);
    if (normalized.isEmpty) return null;
    final direct = files[normalized];
    if (direct != null) return (path: normalized, file: direct);

    final decodedPath = _normalizeArchivePath(
      _safeDecodeUriComponent(normalized),
    );
    if (decodedPath.isNotEmpty && decodedPath != normalized) {
      final decodedDirect = files[decodedPath];
      if (decodedDirect != null) {
        return (path: decodedPath, file: decodedDirect);
      }
    }

    final foldedPath = _uniquePath(_folded[normalized.toLowerCase()]);
    if (foldedPath != null) {
      return (path: foldedPath, file: files[foldedPath]!);
    }
    if (decodedPath.isNotEmpty) {
      final decodedFoldedPath = _uniquePath(
        _decoded[decodedPath.toLowerCase()],
      );
      if (decodedFoldedPath != null) {
        return (path: decodedFoldedPath, file: files[decodedFoldedPath]!);
      }
    }
    return null;
  }

  String? _uniquePath(List<String>? candidates) {
    if (candidates == null || candidates.length != 1) return null;
    return candidates.single;
  }
}

class _AnchorLocation {
  const _AnchorLocation(this.chapterIndex, this.blockIndex);

  final int chapterIndex;
  final int blockIndex;
}

enum _EpubDocumentKind { markup, svg, raster, unsupported }

class _SpineDocument {
  const _SpineDocument(this.item, this.linear);

  final _ManifestItem item;
  final bool linear;
}

class _LoadedDocument {
  const _LoadedDocument(this.blocks, this.linkHrefs, this.documentTitle);

  final List<EpubContentBlock> blocks;
  final Map<int, Map<int, String>> linkHrefs;
  final String? documentTitle;
}

class _ChapterPlan {
  const _ChapterPlan(this.start, this.end, this.title, this.volumeTitle);

  final int start;
  final int end;
  final String? title;
  final String? volumeTitle;
}

class _ResolvedNavEntry {
  const _ResolvedNavEntry(this.entry, this.blockIndex);

  final _NavEntry entry;
  final int blockIndex;

  int get depth => entry.depth;
  String get title => entry.title;
  String? get parentTitle => entry.parentTitle;
}

class _EpubBookAssembler {
  _EpubBookAssembler({
    required this.archiveLookup,
    required this.encryptedPaths,
    required this.navigation,
    required this.imageStore,
    required this.fontStore,
  });

  final _ArchiveLookup archiveLookup;
  final Set<String> encryptedPaths;
  final _EpubNavigation navigation;
  final _EpubImageStore imageStore;
  final _EpubFontStore fontStore;

  final List<Chapter> chapters = <Chapter>[];
  final Map<String, int> chapterIndexByPath = <String, int>{};
  final Map<String, _AnchorLocation> anchorLocations =
      <String, _AnchorLocation>{};
  final Map<int, Map<int, Map<int, String>>> pendingLinks =
      <int, Map<int, Map<int, String>>>{};
  final Set<String> _processedPaths = <String>{};
  final Set<String> _newReferences = <String>{};
  final Map<String, String> _cssDocumentCache = <String, String>{};
  final Map<String, List<_CssRule>> _cssRulesCache = <String, List<_CssRule>>{};

  String? activeVolumeTitle;
  int plainTextLength = 0;

  bool hasProcessed(String path) => _processedPaths.contains(path);

  Set<String> takeNewReferences() {
    if (_newReferences.isEmpty) return const <String>{};
    final references = Set<String>.of(_newReferences);
    _newReferences.clear();
    return references;
  }

  bool addDocument(_ManifestItem item) {
    if (!_processedPaths.add(item.path)) return false;
    if (_isEncryptedPath(item.path, archiveLookup, encryptedPaths)) {
      // A link into a DRM-protected document must not read it either.
      return false;
    }
    final file = archiveLookup.find(item.path);
    if (file == null) return false;
    final kind = _documentKind(item, archiveLookup);
    if (kind == _EpubDocumentKind.unsupported) return false;
    _LoadedDocument? loaded;
    try {
      switch (kind) {
        case _EpubDocumentKind.markup:
          final document = html_parser.parse(decodeEpubMarkup(_bytesOf(file)));
          final cssText = _chapterCssText(
            document,
            item.path,
            archiveLookup,
            _cssDocumentCache,
          );
          fontStore.registerCss(cssText, basePath: item.path);
          final resolver = _EpubStyleResolver(
            cssText,
            rulesCache: _cssRulesCache,
            resolveImage: (rawUrl) =>
                imageStore.extract(rawUrl, relativeTo: item.path)?.path,
            resolveFontFamily: fontStore.resolveFamily,
          );
          final parsed = _documentToBlocks(
            document,
            item.path,
            resolver,
            imageStore,
            archiveLookup,
          );
          loaded = _LoadedDocument(
            parsed.blocks,
            parsed.linkHrefs,
            _extractDocumentTitle(document),
          );
        case _EpubDocumentKind.svg:
          loaded = _svgPageDocument(item.path, file, imageStore);
        case _EpubDocumentKind.raster:
          loaded = _rasterPageDocument(item.path, imageStore);
        case _EpubDocumentKind.unsupported:
          return false;
      }
    } on Object {
      // One unreadable document must not block the rest of the book. Broken
      // CSS, a corrupt image or malformed markup is isolated to this entry.
      return false;
    }
    if (loaded == null || loaded.blocks.isEmpty) return false;
    _appendDocument(item, loaded);
    return true;
  }

  void _appendDocument(_ManifestItem item, _LoadedDocument loaded) {
    final allBlocks = loaded.blocks;
    final plans = _chapterPlans(
      item.path,
      allBlocks,
      loaded.documentTitle,
      navigation,
    );
    for (final plan in plans) {
      final blocks = allBlocks.sublist(plan.start, plan.end);
      if (blocks.isEmpty) continue;

      final chapterIndex = chapters.length;
      chapterIndexByPath.putIfAbsent(item.path, () => chapterIndex);
      for (var localIndex = 0; localIndex < blocks.length; localIndex++) {
        for (final id in blocks[localIndex].anchorIds) {
          anchorLocations.putIfAbsent(
            '${item.path}#$id',
            () => _AnchorLocation(chapterIndex, localIndex),
          );
        }
      }

      final links = <int, Map<int, String>>{};
      for (final entry in loaded.linkHrefs.entries) {
        if (entry.key < plan.start || entry.key >= plan.end) continue;
        links[entry.key - plan.start] = entry.value;
      }
      if (links.isNotEmpty) {
        pendingLinks[chapterIndex] = links;
        for (final runLinks in links.values) {
          for (final href in runLinks.values) {
            final hash = href.indexOf('#');
            final path = hash < 0 ? href : href.substring(0, hash);
            if (path.isNotEmpty) _newReferences.add(path);
          }
        }
      }

      final embeddedHeading = blocks
          .where((block) => block.isText && block.isHeading)
          .firstOrNull;
      var chapterTitle = _normalizeVisibleText(plan.title ?? '');
      if (chapterTitle.isEmpty) {
        chapterTitle =
            (plans.length == 1
                ? navigation.firstTitleForPath(item.path)
                : null) ??
            _normalizeVisibleText(embeddedHeading?.text ?? '');
      }
      if (chapterTitle.isEmpty) {
        chapterTitle = _normalizeVisibleText(loaded.documentTitle ?? '');
      }
      if (chapterTitle.isEmpty) {
        chapterTitle = '章节 ${chapters.length + 1}';
      }
      if (embeddedHeading == null) {
        _promoteMatchingLeadingTitle(blocks, chapterTitle);
      }

      var plainTextBlocks = blocks.where(
        (block) =>
            block.isText && !block.isHeading && block.text.trim().isNotEmpty,
      );
      if (plainTextBlocks.isEmpty) {
        plainTextBlocks = blocks.where(
          (block) => block.isText && block.text.trim().isNotEmpty,
        );
      }
      final plainText = plainTextBlocks
          .map((block) => block.text.trim())
          .join('\n');
      plainTextLength += plainText.length;

      if (plan.volumeTitle == null && isVolumeChapterTitle(chapterTitle)) {
        activeVolumeTitle = chapterTitle;
      }
      var volumeTitle = plan.volumeTitle ?? activeVolumeTitle;
      if (isStandaloneChapterTitle(chapterTitle)) {
        volumeTitle = null;
      }
      chapters.add(
        Chapter(
          index: chapters.length,
          title: chapterTitle,
          content: plainText,
          volumeTitle: volumeTitle,
          epubBlocks: List<EpubContentBlock>.unmodifiable(blocks),
        ),
      );
    }
  }
}

List<_ChapterPlan> _chapterPlans(
  String path,
  List<EpubContentBlock> blocks,
  String? documentTitle,
  _EpubNavigation navigation,
) {
  if (blocks.isEmpty) return const <_ChapterPlan>[];
  final fallback = <_ChapterPlan>[
    _ChapterPlan(
      0,
      blocks.length,
      null,
      _documentVolumeTitle(path, navigation),
    ),
  ];
  final entries = navigation
      .entriesForPath(path)
      .where((entry) => entry.fragment != null && entry.fragment!.isNotEmpty)
      .toList(growable: false);
  if (entries.isEmpty) return fallback;

  final blockByAnchor = <String, int>{};
  for (var index = 0; index < blocks.length; index++) {
    for (final id in blocks[index].anchorIds) {
      blockByAnchor.putIfAbsent(id, () => index);
    }
  }
  final resolved = <_ResolvedNavEntry>[];
  final usedBlocks = <int>{};
  for (final entry in entries) {
    final blockIndex = blockByAnchor[entry.fragment!];
    if (blockIndex == null || !usedBlocks.add(blockIndex)) continue;
    resolved.add(_ResolvedNavEntry(entry, blockIndex));
  }
  if (resolved.length < 2) return fallback;

  final minDepth = resolved.map((entry) => entry.depth).reduce(math.min);
  final topLevel = resolved
      .where((entry) => entry.depth == minDepth)
      .toList(growable: false);
  List<_ResolvedNavEntry> chosen;
  if (topLevel.length >= 2) {
    chosen = topLevel.toList();
  } else {
    final depths = resolved.map((entry) => entry.depth).toSet().toList()
      ..sort();
    int? deeperDepth;
    for (final depth in depths) {
      if (depth <= minDepth) continue;
      if (resolved.where((entry) => entry.depth == depth).length >= 2) {
        deeperDepth = depth;
        break;
      }
    }
    if (deeperDepth == null ||
        !_shouldSplitDeeper(topLevel.firstOrNull, blocks.length)) {
      return fallback;
    }
    chosen = resolved
        .where((entry) => entry.depth == deeperDepth)
        .toList(growable: false);
  }
  chosen.sort((first, second) => first.blockIndex.compareTo(second.blockIndex));

  final plans = <_ChapterPlan>[];
  var cursor = 0;
  if (chosen.first.blockIndex > 0) {
    plans.add(_ChapterPlan(0, chosen.first.blockIndex, documentTitle, null));
    cursor = chosen.first.blockIndex;
  }
  for (var index = 0; index < chosen.length; index++) {
    final entry = chosen[index];
    final start = entry.blockIndex;
    final end = index + 1 < chosen.length
        ? chosen[index + 1].blockIndex
        : blocks.length;
    if (start < cursor || end <= start) continue;
    plans.add(_ChapterPlan(start, end, entry.title, _volumeTitleFor(entry)));
    cursor = end;
  }
  return plans.isEmpty ? fallback : plans;
}

String? _documentVolumeTitle(String path, _EpubNavigation navigation) {
  final first = navigation.entriesForPath(path).firstOrNull;
  final parent = _normalizeVisibleText(first?.parentTitle ?? '');
  if (parent.isEmpty || !_looksLikeVolumeTitle(parent)) return null;
  return parent;
}

bool _shouldSplitDeeper(_ResolvedNavEntry? parent, int blockCount) {
  if (blockCount >= 400) return true;
  final title = _normalizeVisibleText(parent?.title ?? '');
  if (title.isEmpty) return false;
  return _isTocLikeTitle(title) || _looksLikeVolumeTitle(title);
}

String? _volumeTitleFor(_ResolvedNavEntry entry) {
  final parent = _normalizeVisibleText(entry.parentTitle ?? '');
  if (parent.isEmpty || parent == entry.title) return null;
  if (_isTocLikeTitle(parent)) return null;
  return parent;
}

bool _looksLikeVolumeTitle(String title) {
  if (isVolumeChapterTitle(title)) return true;
  return RegExp(
    r'^(?:第[一二两三四五六七八九十百千万零〇０-９0-9]+[部篇]|(?:上|中|下)(?:卷|册|部)|(?:part|book|volume)\b)',
    caseSensitive: false,
  ).hasMatch(title.trim());
}

bool _isTocLikeTitle(String title) {
  final normalized = title.trim().toLowerCase();
  return normalized == '目录' ||
      normalized == '目錄' ||
      normalized == 'contents' ||
      normalized == 'table of contents' ||
      normalized == 'toc';
}

_LoadedDocument? _svgPageDocument(
  String path,
  ArchiveFile file,
  _EpubImageStore imageStore,
) {
  final document = html_parser.parse(decodeEpubMarkup(_bytesOf(file)));
  final documentTitle = _extractDocumentTitle(document);
  final imageElements = <Element>[];
  final root = document.documentElement;
  if (root != null) {
    void collect(Element element) {
      if (element.localName == 'image' || element.localName == 'img') {
        imageElements.add(element);
      }
      for (final child in element.children) {
        collect(child);
      }
    }

    collect(root);
  }
  final blocks = <EpubContentBlock>[];
  final extractedPaths = <String>{};
  for (final element in imageElements) {
    final rawSource =
        _htmlAttribute(element, 'xlink:href') ??
        _htmlAttribute(element, 'href') ??
        _htmlAttribute(element, 'src');
    if (rawSource == null || rawSource.trim().isEmpty) continue;
    final extracted = imageStore.extract(rawSource, relativeTo: path);
    if (extracted == null || !extractedPaths.add(extracted.path)) continue;
    final width = _cssOrAttributePixels(element.attributes['width']);
    final height = _cssOrAttributePixels(element.attributes['height']);
    blocks.add(
      EpubContentBlock(
        kind: EpubContentBlockKind.image,
        imagePath: extracted.path,
        altText:
            element.attributes['alt']?.trim() ??
            element.attributes['aria-label']?.trim() ??
            documentTitle,
        imageWidth: width ?? extracted.width,
        imageHeight: height ?? extracted.height,
        style: const EpubContentStyle(textIndentEm: 0),
      ),
    );
  }
  if (blocks.isEmpty) return null;
  return _LoadedDocument(
    blocks,
    const <int, Map<int, String>>{},
    documentTitle,
  );
}

_LoadedDocument? _rasterPageDocument(String path, _EpubImageStore imageStore) {
  final extracted = imageStore.extractArchivePath(path);
  if (extracted == null) return null;
  return _LoadedDocument(
    <EpubContentBlock>[
      EpubContentBlock(
        kind: EpubContentBlockKind.image,
        imagePath: extracted.path,
        altText: p.posix.basenameWithoutExtension(path),
        imageWidth: extracted.width,
        imageHeight: extracted.height,
        style: const EpubContentStyle(textIndentEm: 0),
      ),
    ],
    const <int, Map<int, String>>{},
    null,
  );
}

/// Rewrites collected anchor hrefs into chapter and block coordinates.
///
/// A reference the spine does not contain is dropped rather than kept as a
/// dead tap target; the text stays readable and simply is not a link.
void _resolveEpubLinks(
  List<Chapter> chapters, {
  required Map<int, Map<int, Map<int, String>>> pendingLinks,
  required Map<String, int> chapterIndexByPath,
  required Map<String, _AnchorLocation> anchorLocations,
}) {
  for (final entry in pendingLinks.entries) {
    final chapter = chapters[entry.key];
    final blocks = chapter.epubBlocks.toList();
    var changed = false;
    for (final blockEntry in entry.value.entries) {
      final blockIndex = blockEntry.key;
      if (blockIndex < 0 || blockIndex >= blocks.length) continue;
      final block = blocks[blockIndex];
      final runs = block.runs.toList();
      var blockChanged = false;
      for (final runEntry in blockEntry.value.entries) {
        final runIndex = runEntry.key;
        if (runIndex < 0 || runIndex >= runs.length) continue;
        final target = _epubLinkTarget(
          runEntry.value,
          chapterIndexByPath: chapterIndexByPath,
          anchorLocations: anchorLocations,
        );
        if (target == null) continue;
        runs[runIndex] = runs[runIndex].withLink(target);
        blockChanged = true;
      }
      if (!blockChanged) continue;
      blocks[blockIndex] = block.withRuns(runs);
      changed = true;
    }
    if (!changed) continue;
    chapters[entry.key] = Chapter(
      index: chapter.index,
      title: chapter.title,
      content: chapter.content,
      volumeTitle: chapter.volumeTitle,
      epubBlocks: List<EpubContentBlock>.unmodifiable(blocks),
    );
  }
}

EpubLinkTarget? _epubLinkTarget(
  String href, {
  required Map<String, int> chapterIndexByPath,
  required Map<String, _AnchorLocation> anchorLocations,
}) {
  final hashIndex = href.indexOf('#');
  final path = hashIndex < 0 ? href : href.substring(0, hashIndex);
  final firstChapter = chapterIndexByPath[path];
  if (firstChapter == null) return null;
  if (hashIndex < 0) return EpubLinkTarget(chapterIndex: firstChapter);
  final location = anchorLocations[href];
  if (location == null) {
    return EpubLinkTarget(chapterIndex: firstChapter);
  }
  return EpubLinkTarget(
    chapterIndex: location.chapterIndex,
    blockIndex: location.blockIndex,
  );
}

Set<String> _epubEncryptedPaths(_ArchiveLookup archiveLookup) {
  final encryption = archiveLookup.find('META-INF/encryption.xml');
  if (encryption == null) return const <String>{};
  try {
    // Encryption metadata is security-relevant: keep exact XML parsing here
    // and refuse the book when the list cannot be trusted.
    final document = _parseXml(encryption, 'encryption.xml');
    final paths = <String>{};
    for (final reference in _elementsNamed(document, 'CipherReference')) {
      final rawUri = reference.getAttribute('URI');
      if (rawUri == null || rawUri.trim().isEmpty) continue;
      final path = _normalizeArchivePath(
        _safeDecodeUriComponent(rawUri.split('#').first.split('?').first),
      );
      if (path.isNotEmpty && path != '..' && !path.startsWith('../')) {
        paths.add(path);
        final canonical = archiveLookup.canonicalPath(path);
        if (canonical != null) paths.add(canonical);
      }
    }
    return paths;
  } on FormatException {
    throw const FormatException('EPUB encryption.xml 已损坏，无法确认内容安全性');
  }
}

bool _isEncryptedPath(
  String requestedPath,
  _ArchiveLookup archiveLookup,
  Set<String> encryptedPaths,
) {
  if (encryptedPaths.contains(requestedPath)) return true;
  final canonical = archiveLookup.canonicalPath(requestedPath);
  return canonical != null && encryptedPaths.contains(canonical);
}

class _ManifestItem {
  const _ManifestItem(
    this.id,
    this.path,
    this.mediaType,
    this.properties,
    this.fallbackId,
  );

  final String id;
  final String path;
  final String mediaType;
  final Set<String> properties;
  final String? fallbackId;
}

Map<String, _ManifestItem> _extractManifest(
  XmlDocument opf,
  String opfDir,
  _ArchiveLookup archiveLookup,
) {
  final manifest = <String, _ManifestItem>{};
  for (final item in _elementsNamed(opf, 'item')) {
    final id = item.getAttribute('id')?.trim();
    final href = item.getAttribute('href');
    if (id == null || id.isEmpty || href == null) continue;
    final joined = _resolveArchiveReference(
      href,
      opfDir,
      baseIsDirectory: true,
    );
    if (joined.isEmpty) continue;
    final canonicalPath = archiveLookup.canonicalPath(joined) ?? joined;
    manifest[id] = _ManifestItem(
      id,
      canonicalPath,
      _normalizeMediaType(item.getAttribute('media-type') ?? ''),
      (item.getAttribute('properties') ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((value) => value.isNotEmpty)
          .toSet(),
      item.getAttribute('fallback')?.trim(),
    );
  }
  return manifest;
}

String _normalizeMediaType(String raw) =>
    raw.split(';').first.trim().toLowerCase();

String? _epubCoverArchivePath(
  XmlDocument opf,
  Map<String, _ManifestItem> manifest,
) {
  for (final item in manifest.values) {
    if (item.properties.contains('cover-image') &&
        item.mediaType.startsWith('image/')) {
      return item.path;
    }
  }
  for (final meta in _elementsNamed(opf, 'meta')) {
    if (meta.getAttribute('name')?.trim().toLowerCase() != 'cover') continue;
    final id = meta.getAttribute('content')?.trim();
    final item = id == null ? null : manifest[id];
    if (item != null && item.mediaType.startsWith('image/')) return item.path;
  }
  for (final entry in manifest.entries) {
    if (entry.key.toLowerCase().contains('cover') &&
        entry.value.mediaType.startsWith('image/')) {
      return entry.value.path;
    }
  }
  return null;
}

List<_SpineDocument> _extractSpineDocuments(
  XmlDocument opf,
  Map<String, _ManifestItem> manifest,
  _ArchiveLookup archiveLookup,
) {
  final documents = <_SpineDocument>[];
  final indexByPath = <String, int>{};
  for (final itemref in _elementsNamed(opf, 'itemref')) {
    final idref = itemref.getAttribute('idref')?.trim();
    if (idref == null || idref.isEmpty) continue;
    final item = _resolveSpineManifestItem(
      manifest[idref],
      manifest,
      archiveLookup,
    );
    if (item == null) continue;
    final linear = itemref.getAttribute('linear')?.toLowerCase().trim() != 'no';
    final existingIndex = indexByPath[item.path];
    if (existingIndex != null) {
      if (linear && !documents[existingIndex].linear) {
        documents[existingIndex] = _SpineDocument(item, true);
      }
      continue;
    }
    indexByPath[item.path] = documents.length;
    documents.add(_SpineDocument(item, linear));
  }
  return documents;
}

_ManifestItem? _resolveSpineManifestItem(
  _ManifestItem? item,
  Map<String, _ManifestItem> manifest,
  _ArchiveLookup archiveLookup,
) {
  final seen = <String>{};
  var current = item;
  while (current != null) {
    if (!seen.add(current.id)) return null;
    if (_documentKind(current, archiveLookup) !=
            _EpubDocumentKind.unsupported &&
        archiveLookup.find(current.path) != null) {
      return current;
    }
    final fallbackId = current.fallbackId;
    if (fallbackId == null || fallbackId.isEmpty) return null;
    current = manifest[fallbackId];
  }
  return null;
}

const _markupExtensions = <String>{'.xhtml', '.html', '.htm'};
const _rasterExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
};

bool _isMarkupMediaType(String mediaType) =>
    mediaType == 'application/xhtml+xml' ||
    mediaType == 'text/html' ||
    mediaType == 'application/xml' ||
    mediaType == 'text/xml' ||
    mediaType == 'text/xhtml';

bool _isRasterImageMediaType(String mediaType) =>
    mediaType.startsWith('image/') && mediaType != 'image/svg+xml';

bool _isKnownBinaryMediaType(String mediaType) =>
    mediaType.startsWith('image/') ||
    mediaType.startsWith('audio/') ||
    mediaType.startsWith('video/') ||
    mediaType.startsWith('font/') ||
    mediaType == 'application/pdf' ||
    mediaType == 'application/zip' ||
    mediaType == 'application/x-dtbncx+xml';

_EpubDocumentKind _documentKind(
  _ManifestItem item,
  _ArchiveLookup archiveLookup,
) {
  final mediaType = item.mediaType;
  final extension = p.posix.extension(item.path).toLowerCase();
  if (_isMarkupMediaType(mediaType)) return _EpubDocumentKind.markup;
  if (mediaType == 'image/svg+xml') return _EpubDocumentKind.svg;
  if (_isRasterImageMediaType(mediaType)) return _EpubDocumentKind.raster;
  final looselyTyped =
      mediaType.isEmpty ||
      mediaType == 'application/octet-stream' ||
      mediaType == 'binary/octet-stream' ||
      mediaType == 'text/plain';
  final extensionIsTrustworthy =
      looselyTyped || !_isKnownBinaryMediaType(mediaType);
  if (extensionIsTrustworthy && _markupExtensions.contains(extension)) {
    return _EpubDocumentKind.markup;
  }
  if (extensionIsTrustworthy && extension == '.svg') {
    return _EpubDocumentKind.svg;
  }
  if (extensionIsTrustworthy && _rasterExtensions.contains(extension)) {
    return _EpubDocumentKind.raster;
  }
  return _EpubDocumentKind.unsupported;
}

({XmlDocument opf, String path}) _selectOpf(
  XmlDocument container,
  _ArchiveLookup archiveLookup,
  Set<String> encryptedPaths,
) {
  FormatException? firstError;
  var sawEncrypted = false;
  for (final rootfile in _elementsNamed(container, 'rootfile')) {
    final rawPath = rootfile.getAttribute('full-path');
    if (rawPath == null || rawPath.trim().isEmpty) continue;
    final path = _normalizeArchivePath(
      _safeDecodeUriComponent(rawPath.split('#').first.split('?').first),
    );
    if (path.isEmpty || path == '..' || path.startsWith('../')) continue;
    if (_isEncryptedPath(path, archiveLookup, encryptedPaths)) {
      sawEncrypted = true;
      continue;
    }
    final file = archiveLookup.find(path);
    if (file == null) continue;
    try {
      final opf = _parseXml(file, 'OPF', lenient: true);
      if (_elementsNamed(opf, 'manifest').isEmpty) {
        firstError ??= const FormatException('OPF 中缺少 manifest');
        continue;
      }
      return (opf: opf, path: path);
    } on FormatException catch (error) {
      firstError ??= error;
    }
  }
  if (sawEncrypted) {
    throw const FormatException('EPUB 包内容受 DRM 或加密保护，无法离线解析');
  }
  throw firstError ?? const FormatException('无效的 EPUB 文件：无法读取 OPF');
}

class _NavEntry {
  const _NavEntry(
    this.path,
    this.fragment,
    this.title,
    this.depth,
    this.parentTitle,
  );

  final String path;
  final String? fragment;
  final String title;
  final int depth;
  final String? parentTitle;
}

class _EpubNavigation {
  _EpubNavigation(List<_NavEntry> source)
    : entries = List.unmodifiable(source) {
    for (final entry in source) {
      _byPath.putIfAbsent(entry.path, () => <_NavEntry>[]).add(entry);
      if (entry.fragment == null) {
        _firstTitle.putIfAbsent(entry.path, () => entry.title);
      }
    }
    for (final entry in source) {
      _firstTitle.putIfAbsent(entry.path, () => entry.title);
    }
  }

  final List<_NavEntry> entries;
  final Map<String, List<_NavEntry>> _byPath = <String, List<_NavEntry>>{};
  final Map<String, String> _firstTitle = <String, String>{};

  List<_NavEntry> entriesForPath(String path) =>
      _byPath[path] ?? const <_NavEntry>[];

  String? firstTitleForPath(String path) => _firstTitle[path];
}

_EpubNavigation _extractNavigation(
  XmlDocument opf,
  Map<String, _ManifestItem> manifest,
  _ArchiveLookup archiveLookup,
) {
  final entries = <_NavEntry>[];
  final seen = <String>{};
  var parsedNavigationDocument = false;

  for (final item in manifest.values) {
    if (!item.properties.contains('nav')) continue;
    final file = archiveLookup.find(item.path);
    if (file == null) continue;
    try {
      final document = html_parser.parse(decodeEpubMarkup(_bytesOf(file)));
      final navigation = _findTocNavigation(document);
      if (navigation == null) continue;
      final list =
          _directChild(navigation, 'ol') ??
          _directChild(navigation, 'ul') ??
          navigation.querySelector('ol') ??
          navigation.querySelector('ul');
      if (list == null) continue;
      final before = entries.length;
      _walkNavigationList(
        list,
        0,
        null,
        item.path,
        archiveLookup,
        entries,
        seen,
      );
      if (entries.length > before) parsedNavigationDocument = true;
    } on Object {
      // Navigation is optional for reading; a damaged nav document falls back
      // to a damaged NCX only when it produced no usable entries at all.
    }
  }

  if (!parsedNavigationDocument) {
    final spine = _elementsNamed(opf, 'spine').firstOrNull;
    final ncxId = spine?.getAttribute('toc')?.trim();
    final candidates = <_ManifestItem>[
      if (ncxId != null && manifest[ncxId] != null) manifest[ncxId]!,
      ...manifest.values.where(
        (item) => item.mediaType == 'application/x-dtbncx+xml',
      ),
    ];
    final seenNcx = <String>{};
    for (final item in candidates) {
      if (!seenNcx.add(item.path)) continue;
      final file = archiveLookup.find(item.path);
      if (file == null) continue;
      try {
        final ncx = _parseXml(file, 'NCX', lenient: true);
        final navMap = _elementsNamed(ncx, 'navMap').firstOrNull;
        if (navMap == null) continue;
        for (final navPoint in navMap.children.whereType<XmlElement>().where(
          (element) => _xmlNameIs(element, 'navPoint'),
        )) {
          _walkNcxPoint(
            navPoint,
            0,
            null,
            item.path,
            archiveLookup,
            entries,
            seen,
          );
        }
      } on Object {
        // Ignore a damaged NCX and use embedded chapter headings instead.
      }
    }
  }

  if (entries.isEmpty) return _EpubNavigation(const <_NavEntry>[]);
  final minDepth = entries.map((entry) => entry.depth).reduce(math.min);
  if (minDepth == 0) return _EpubNavigation(entries);
  return _EpubNavigation(<_NavEntry>[
    for (final entry in entries)
      _NavEntry(
        entry.path,
        entry.fragment,
        entry.title,
        entry.depth - minDepth,
        entry.parentTitle,
      ),
  ]);
}

Element? _findTocNavigation(Document document) {
  final navigationElements = document.querySelectorAll('nav');
  for (final element in navigationElements) {
    final type =
        _htmlAttribute(element, 'epub:type') ??
        _htmlAttribute(element, 'type') ??
        _htmlAttribute(element, 'role') ??
        '';
    final isToc = type
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .any((value) => value == 'toc' || value == 'doc-toc');
    if (isToc) return element;
  }
  for (final element in navigationElements) {
    if (element.querySelector('a[href]') != null) return element;
  }
  return null;
}

Element? _directChild(Element parent, String localName) {
  for (final child in parent.children) {
    if (child.localName == localName) return child;
  }
  return null;
}

void _walkNavigationList(
  Element list,
  int depth,
  String? parentTitle,
  String basePath,
  _ArchiveLookup archiveLookup,
  List<_NavEntry> entries,
  Set<String> seen,
) {
  for (final item in list.children) {
    if (item.localName != 'li') continue;
    final anchor = _navigationAnchor(item);
    final rawTitle = _normalizeVisibleText(
      anchor?.text ?? _navigationOwnLabel(item),
    );
    final title = rawTitle.isEmpty
        ? _normalizeVisibleText(anchor?.attributes['title'] ?? '')
        : rawTitle;
    final href = anchor == null ? null : _htmlAttribute(anchor, 'href');
    if (href != null) {
      _addNavEntry(
        rawHref: href,
        title: title,
        depth: depth,
        parentTitle: parentTitle,
        basePath: basePath,
        archiveLookup: archiveLookup,
        entries: entries,
        seen: seen,
      );
    }
    final childParentTitle = title.isNotEmpty ? title : parentTitle;
    for (final child in item.children) {
      if (child.localName == 'ol' || child.localName == 'ul') {
        _walkNavigationList(
          child,
          depth + 1,
          childParentTitle,
          basePath,
          archiveLookup,
          entries,
          seen,
        );
      }
    }
  }
}

Element? _navigationAnchor(Element item) {
  Element? find(Element parent) {
    for (final child in parent.children) {
      if (child.localName == 'ol' || child.localName == 'ul') continue;
      if (child.localName == 'a' &&
          (_htmlAttribute(child, 'href') ?? '').trim().isNotEmpty) {
        return child;
      }
      final nested = find(child);
      if (nested != null) return nested;
    }
    return null;
  }

  return find(item);
}

String _navigationOwnLabel(Element item) {
  final buffer = StringBuffer();
  for (final node in item.nodes) {
    if (node is Text) {
      buffer.write(node.data);
    } else if (node is Element &&
        node.localName != 'ol' &&
        node.localName != 'ul' &&
        node.localName != 'a') {
      buffer.write(node.text);
    }
  }
  return buffer.toString();
}

void _walkNcxPoint(
  XmlElement navPoint,
  int depth,
  String? parentTitle,
  String basePath,
  _ArchiveLookup archiveLookup,
  List<_NavEntry> entries,
  Set<String> seen,
) {
  final content = navPoint.children
      .whereType<XmlElement>()
      .where((element) => _xmlNameIs(element, 'content'))
      .firstOrNull;
  final label = navPoint.children
      .whereType<XmlElement>()
      .where((element) => _xmlNameIs(element, 'navLabel'))
      .firstOrNull;
  final title = _normalizeVisibleText(label?.innerText ?? '');
  _addNavEntry(
    rawHref: content?.getAttribute('src'),
    title: title,
    depth: depth,
    parentTitle: parentTitle,
    basePath: basePath,
    archiveLookup: archiveLookup,
    entries: entries,
    seen: seen,
  );
  final childParentTitle = title.isNotEmpty ? title : parentTitle;
  for (final child in navPoint.children.whereType<XmlElement>().where(
    (element) => _xmlNameIs(element, 'navPoint'),
  )) {
    _walkNcxPoint(
      child,
      depth + 1,
      childParentTitle,
      basePath,
      archiveLookup,
      entries,
      seen,
    );
  }
}

void _addNavEntry({
  required String? rawHref,
  required String title,
  required int depth,
  required String? parentTitle,
  required String basePath,
  required _ArchiveLookup archiveLookup,
  required List<_NavEntry> entries,
  required Set<String> seen,
}) {
  if (rawHref == null || rawHref.trim().isEmpty || title.isEmpty) return;
  final target = _resolveNavTarget(rawHref, basePath, archiveLookup);
  if (target == null) return;
  final key = '${target.path}\u0000${target.fragment ?? ''}';
  if (!seen.add(key)) return;
  final normalizedParent = _normalizeVisibleText(parentTitle ?? '');
  entries.add(
    _NavEntry(
      target.path,
      target.fragment,
      title,
      depth,
      normalizedParent.isEmpty ? null : normalizedParent,
    ),
  );
}

({String path, String? fragment})? _resolveNavTarget(
  String rawHref,
  String basePath,
  _ArchiveLookup archiveLookup,
) {
  final value = rawHref.trim();
  if (value.isEmpty || _uriSchemePattern.hasMatch(value)) return null;
  final hashIndex = value.indexOf('#');
  final rawPath = hashIndex < 0 ? value : value.substring(0, hashIndex);
  final rawFragment = hashIndex < 0 ? '' : value.substring(hashIndex + 1);
  final resolvedPath = rawPath.trim().isEmpty
      ? basePath
      : _resolveArchiveReference(rawPath, basePath);
  if (resolvedPath.isEmpty) return null;
  final path = archiveLookup.canonicalPath(resolvedPath) ?? resolvedPath;
  final fragment = _safeDecodeUriComponent(rawFragment).trim();
  return (path: path, fragment: fragment.isEmpty ? null : fragment);
}

String _chapterCssText(
  Document document,
  String contentPath,
  _ArchiveLookup archiveLookup,
  Map<String, String> documentCache,
) {
  final output = StringBuffer();
  final visited = <String>{};

  void appendCssPath(String rawPath, String relativeTo) {
    final resolvedPath = _resolveArchiveReference(rawPath, relativeTo);
    if (resolvedPath.isEmpty) return;
    final cssPath = archiveLookup.canonicalPath(resolvedPath) ?? resolvedPath;
    if (!visited.add(cssPath)) return;
    final css = documentCache.putIfAbsent(cssPath, () {
      try {
        final file = archiveLookup.find(cssPath);
        if (file == null || file.size > 8 * 1024 * 1024) return '';
        return decodeEpubMarkup(_bytesOf(file));
      } on Object {
        // One damaged stylesheet must not fail the whole chapter.
        return '';
      }
    });
    if (css.isEmpty) return;
    for (final match in RegExp(
      r'''@import\s+(?:url\()?\s*["']?([^"')\s;]+)''',
      caseSensitive: false,
    ).allMatches(css)) {
      final imported = match.group(1);
      if (imported != null) appendCssPath(imported, cssPath);
    }
    output.writeln(_rewriteCssUrls(css, cssPath));
  }

  for (final link in document.querySelectorAll('link[href]')) {
    final rel = link.attributes['rel']?.toLowerCase() ?? '';
    final type = link.attributes['type']?.toLowerCase() ?? '';
    if (!rel.split(RegExp(r'\s+')).contains('stylesheet') &&
        type != 'text/css') {
      continue;
    }
    appendCssPath(link.attributes['href']!, contentPath);
  }
  for (final style in document.querySelectorAll('style')) {
    output.writeln(_rewriteCssUrls(style.text, contentPath));
  }
  return output.toString();
}

String _rewriteCssUrls(String css, String cssPath) {
  return css.replaceAllMapped(
    RegExp(r'''url\(\s*(["']?)([^"')]+)\1\s*\)''', caseSensitive: false),
    (match) {
      final raw = match.group(2)?.trim() ?? '';
      if (raw.isEmpty ||
          raw.startsWith('data:') ||
          raw.startsWith('http:') ||
          raw.startsWith('https:')) {
        return match.group(0)!;
      }
      final resolved = _resolveArchiveReference(raw, cssPath);
      return resolved.isEmpty ? match.group(0)! : 'url("/$resolved")';
    },
  );
}

/// Blocks of one spine document plus the anchor hrefs found inside them.
///
/// Hrefs stay unresolved here: a link can point at a later spine item, so the
/// mapping to chapter and block coordinates only exists after the whole spine
/// has been read.
class _ParsedDocument {
  final List<EpubContentBlock> blocks;

  /// blockIndex -> runIndex -> normalized `path` or `path#fragment`.
  final Map<int, Map<int, String>> linkHrefs;

  const _ParsedDocument(this.blocks, this.linkHrefs);
}

_ParsedDocument _documentToBlocks(
  Document document,
  String contentPath,
  _EpubStyleResolver resolver,
  _EpubImageStore imageStore,
  _ArchiveLookup archiveLookup,
) {
  final blocks = <EpubContentBlock>[];
  final linkHrefs = <int, Map<int, String>>{};
  final pendingAnchorIds = <String>[];
  final root = document.body ?? document.documentElement;
  if (root == null) return _ParsedDocument(blocks, linkHrefs);

  void noteAnchorId(Element element) {
    var id = element.attributes['id']?.trim();
    if (id == null || id.isEmpty) {
      id = _htmlAttribute(element, 'xml:id')?.trim();
    }
    if ((id == null || id.isEmpty) && element.localName == 'a') {
      // EPUB 2 footnote targets frequently use <a name="...">.
      id = _htmlAttribute(element, 'name')?.trim();
    }
    if (id == null || id.isEmpty || id.length > 256) return;
    if (pendingAnchorIds.length >= 64 || pendingAnchorIds.contains(id)) return;
    pendingAnchorIds.add(id);
  }

  List<String> drainAnchorIds() {
    if (pendingAnchorIds.isEmpty) return const <String>[];
    final ids = List<String>.unmodifiable(pendingAnchorIds);
    pendingAnchorIds.clear();
    return ids;
  }

  /// Resolves an anchor href against this document. Returns null for external
  /// schemes and for empty references, which stay ordinary text.
  String? resolveLinkHref(String rawHref) {
    final value = rawHref.trim();
    if (value.isEmpty) return null;
    if (_uriSchemePattern.hasMatch(value)) return null;
    final hashIndex = value.indexOf('#');
    final rawPath = hashIndex < 0 ? value : value.substring(0, hashIndex);
    final rawFragment = hashIndex < 0 ? '' : value.substring(hashIndex + 1);
    final resolvedPath = rawPath.trim().isEmpty
        ? contentPath
        : _resolveArchiveReference(rawPath, contentPath);
    if (resolvedPath.isEmpty) return null;
    final path = archiveLookup.canonicalPath(resolvedPath) ?? resolvedPath;
    final fragment = _safeDecodeUriComponent(rawFragment).trim();
    return fragment.isEmpty ? path : '$path#$fragment';
  }

  bool appendImageSource(
    Element image,
    String rawSource,
    EpubContentStyle inheritedStyle,
  ) {
    final extracted = imageStore.extract(rawSource, relativeTo: contentPath);
    if (extracted == null) return false;
    final style = _normalizeImageStyle(
      resolver.styleFor(image, inherited: inheritedStyle),
    );
    final width = _cssOrAttributePixels(
      image.attributes['width'] ?? resolver.propertyFor(image, 'width'),
    );
    final height = _cssOrAttributePixels(
      image.attributes['height'] ?? resolver.propertyFor(image, 'height'),
    );
    var resolvedWidth = width ?? extracted.width;
    var resolvedHeight = height ?? extracted.height;
    if (width != null &&
        height == null &&
        extracted.width != null &&
        extracted.height != null &&
        extracted.width! > 0) {
      resolvedHeight = width * extracted.height! / extracted.width!;
    } else if (height != null &&
        width == null &&
        extracted.width != null &&
        extracted.height != null &&
        extracted.height! > 0) {
      resolvedWidth = height * extracted.width! / extracted.height!;
    }
    blocks.add(
      EpubContentBlock(
        kind: EpubContentBlockKind.image,
        imagePath: extracted.path,
        altText: image.attributes['alt']?.trim(),
        imageWidth: resolvedWidth,
        imageHeight: resolvedHeight,
        style: style,
        anchorIds: drainAnchorIds(),
      ),
    );
    return true;
  }

  bool appendImage(Element image, EpubContentStyle inheritedStyle) {
    var rawSource =
        _htmlAttribute(image, 'src') ??
        _htmlAttribute(image, 'xlink:href') ??
        _htmlAttribute(image, 'href');
    if (rawSource == null || rawSource.trim().isEmpty) {
      rawSource = _firstSrcsetCandidate(_htmlAttribute(image, 'srcset'));
    }
    if (rawSource == null || rawSource.trim().isEmpty) return false;
    return appendImageSource(image, rawSource, inheritedStyle);
  }

  void appendDirectText(String rawText, EpubContentStyle inheritedStyle) {
    if (rawText.trim().isEmpty) return;
    final blockStyle = _normalizeBlockStyle(
      inheritedStyle,
      tag: null,
      isHeading: false,
    );
    final collector = _EpubRunCollector()..add(rawText, inheritedStyle);
    final collected = collector.finish();
    if (collected == null) return;
    final compact = _compactRuns(collected.runs, blockStyle);
    final hrefs = <int, String>{};
    for (var index = 0; index < compact.length; index++) {
      final href = compact[index].href;
      if (href != null) hrefs[index] = href;
    }
    if (hrefs.isNotEmpty) linkHrefs[blocks.length] = hrefs;
    blocks.add(
      EpubContentBlock(
        kind: EpubContentBlockKind.text,
        text: collected.text,
        runs: List<EpubTextRun>.unmodifiable(<EpubTextRun>[
          for (final run in compact)
            EpubTextRun(text: run.text, style: run.style),
        ]),
        style: blockStyle,
        anchorIds: drainAnchorIds(),
      ),
    );
  }

  void appendLeaf(Element element, EpubContentStyle inheritedStyle) {
    final resolvedStyle = resolver.styleFor(element, inherited: inheritedStyle);
    final isHeading = _isSemanticHeading(element, resolvedStyle);
    final blockStyle = _normalizeBlockStyle(
      resolvedStyle,
      tag: element.localName,
      isHeading: isHeading,
    );
    if (resolver.isHidden(element)) return;
    var collector = _EpubRunCollector();

    void flushText() {
      final collected = collector.finish();
      collector = _EpubRunCollector();
      if (collected == null) return;
      final compact = _compactRuns(collected.runs, blockStyle);
      final hrefs = <int, String>{};
      for (var index = 0; index < compact.length; index++) {
        final href = compact[index].href;
        if (href != null) hrefs[index] = href;
      }
      if (hrefs.isNotEmpty) linkHrefs[blocks.length] = hrefs;
      blocks.add(
        EpubContentBlock(
          kind: EpubContentBlockKind.text,
          text: collected.text,
          runs: List<EpubTextRun>.unmodifiable(<EpubTextRun>[
            for (final run in compact)
              EpubTextRun(text: run.text, style: run.style),
          ]),
          isHeading: isHeading,
          style: blockStyle,
          anchorIds: drainAnchorIds(),
        ),
      );
    }

    void visit(Node node, EpubContentStyle style, String? href) {
      if (node is Text) {
        collector.add(node.data, style, href: href);
        return;
      }
      if (node is! Element || resolver.isHidden(node)) return;
      final tag = node.localName;
      if (tag == 'script' || tag == 'style' || tag == 'head') return;
      if (tag == 'img' || tag == 'image') {
        // Flush first: an anchor on the image belongs to the image block, not
        // to the text that happens to precede it.
        flushText();
        noteAnchorId(node);
        appendImage(node, style);
        return;
      }
      if (tag == 'object' || tag == 'embed') {
        final rawSource = tag == 'object'
            ? _htmlAttribute(node, 'data')
            : _htmlAttribute(node, 'src');
        if (rawSource != null && rawSource.trim().isNotEmpty) {
          flushText();
          noteAnchorId(node);
          if (appendImageSource(node, rawSource, style)) return;
        }
      }
      noteAnchorId(node);
      if (tag == 'br' || tag == 'hr') collector.add(' ', style, href: href);
      // An anchor nested inside another anchor is malformed markup; the
      // innermost href wins, matching how browsers resolve the same document.
      final childHref = tag == 'a'
          ? (resolveLinkHref(node.attributes['href'] ?? '') ?? href)
          : href;
      final childStyle = _normalizeInlineStyle(
        resolver.styleFor(node, inherited: style),
        inherited: style,
      );
      for (final child in node.nodes) {
        visit(child, childStyle, childHref);
      }
    }

    for (final child in element.nodes) {
      visit(child, blockStyle, null);
    }
    flushText();
  }

  void walk(Element element, EpubContentStyle inheritedStyle) {
    if (resolver.isHidden(element)) return;
    noteAnchorId(element);
    final style = resolver.styleFor(element, inherited: inheritedStyle);
    if (element.localName == 'img' || element.localName == 'image') {
      appendImage(element, inheritedStyle);
      return;
    }
    if (element.localName == 'object' || element.localName == 'embed') {
      final rawSource = element.localName == 'object'
          ? _htmlAttribute(element, 'data')
          : _htmlAttribute(element, 'src');
      if (rawSource != null &&
          rawSource.trim().isNotEmpty &&
          appendImageSource(element, rawSource, inheritedStyle)) {
        return;
      }
    }
    final containsBlockChild = element.children.any(
      (child) => _blockElements.contains(child.localName),
    );
    // Inline wrappers such as <span> or <b> legitimately hold chapter text in
    // real-world EPUBs. Treating only block tags as leaves silently dropped
    // that text whenever the wrapper sat next to block-level siblings.
    if (!containsBlockChild &&
        !_transparentContainers.contains(element.localName) &&
        (_blockElements.contains(element.localName) ||
            element.text.trim().isNotEmpty)) {
      appendLeaf(element, inheritedStyle);
      return;
    }
    for (final node in element.nodes) {
      if (node is Text) {
        // Mixed content such as <body>开场<p>中间</p>结尾</body> is valid
        // HTML. element.children alone would silently drop the direct text.
        appendDirectText(node.data, style);
      } else if (node is Element) {
        walk(node, style);
      }
    }
  }

  walk(root, const EpubContentStyle(textIndentEm: 0));
  return _ParsedDocument(blocks, linkHrefs);
}

String? _firstSrcsetCandidate(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final comma = value.indexOf(',');
  final first = comma < 0 ? value : value.substring(0, comma);
  final space = first.indexOf(RegExp(r'\s'));
  final candidate = (space < 0 ? first : first.substring(0, space)).trim();
  return candidate.isEmpty ? null : candidate;
}

/// Matches any URI scheme, so http, mailto, tel and data links stay plain text.
final _uriSchemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

/// Reads an HTML attribute whose key may carry a namespace (xlink:href,
/// epub:type, xml:id). package:html keeps the qualified key object, so a plain
/// map lookup misses those names even though [Element.attributes] prints them.
String? _htmlAttribute(Element element, String name) {
  final direct = element.attributes[name];
  if (direct != null) return direct;
  final lower = name.toLowerCase();
  for (final entry in element.attributes.entries) {
    if (entry.key.toString().toLowerCase() == lower) return entry.value;
  }
  return null;
}

const _blockElements = <String>{
  'address',
  'article',
  'aside',
  'blockquote',
  'dd',
  'div',
  'dt',
  'figcaption',
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
  'p',
  'pre',
  'section',
  'td',
  'th',
  'tr',
};

const _headingElements = <String>{'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

bool _isSemanticHeading(Element element, EpubContentStyle style) {
  if (_headingElements.contains(element.localName)) return true;
  final roleTokens = <String>[
    _htmlAttribute(element, 'role') ?? '',
    _htmlAttribute(element, 'epub:type') ?? '',
    _htmlAttribute(element, 'type') ?? '',
  ].expand((value) => value.toLowerCase().split(RegExp(r'\s+')));
  if (roleTokens.any(
    (value) =>
        value == 'heading' ||
        value == 'title' ||
        value == 'chapter-title' ||
        value == 'chaptertitle',
  )) {
    return true;
  }
  final identityTokens = <String>{
    element.id.toLowerCase(),
    ...element.classes.map((value) => value.toLowerCase()),
  };
  final namedAsHeading = identityTokens.any(
    (value) => RegExp(
      r'(^|[-_])(chapter[-_]?title|chaptertitle|title|heading|head)([-_]|$)',
    ).hasMatch(value),
  );
  if (namedAsHeading) return true;
  return style.fontScale >= 1.12 &&
      style.fontWeight >= 600 &&
      (style.textIndentEm == 0 || style.textAlign == 'center');
}

bool _promoteMatchingLeadingTitle(
  List<EpubContentBlock> blocks,
  String chapterTitle,
) {
  final normalizedTitle = _normalizeVisibleText(chapterTitle);
  if (normalizedTitle.isEmpty) return false;
  for (var index = 0; index < blocks.length; index++) {
    final block = blocks[index];
    if (!block.isText || block.text.trim().isEmpty) continue;
    if (_normalizeVisibleText(block.text) != normalizedTitle) return false;
    final style = block.style;
    blocks[index] = EpubContentBlock(
      kind: block.kind,
      text: block.text,
      runs: block.runs
          .map(
            (run) => EpubTextRun(
              text: run.text,
              link: run.link,
              style: EpubContentStyle(
                fontFamily: run.style.fontFamily,
                fontScale: math.max(1.2, run.style.fontScale),
                fontWeight: math.max(600, run.style.fontWeight),
                italic: run.style.italic,
                underline: run.style.underline,
                textAlign: style.textAlign,
                textIndentEm: 0,
                colorArgb: run.style.colorArgb,
                backgroundColorArgb: run.style.backgroundColorArgb,
              ),
            ),
          )
          .toList(growable: false),
      isHeading: true,
      imagePath: block.imagePath,
      altText: block.altText,
      imageWidth: block.imageWidth,
      imageHeight: block.imageHeight,
      anchorIds: block.anchorIds,
      style: EpubContentStyle(
        fontFamily: style.fontFamily,
        fontScale: math.max(1.2, style.fontScale),
        fontWeight: math.max(600, style.fontWeight),
        italic: style.italic,
        underline: style.underline,
        textAlign: style.textAlign,
        textIndentEm: 0,
        marginBottomEm: math.max(0.45, style.marginBottomEm),
        colorArgb: style.colorArgb,
        backgroundColorArgb: style.backgroundColorArgb,
        backgroundImagePath: style.backgroundImagePath,
      ),
    );
    return true;
  }
  return false;
}

EpubContentStyle _normalizeBlockStyle(
  EpubContentStyle style, {
  required String? tag,
  required bool isHeading,
}) {
  if (isHeading) {
    return EpubContentStyle(
      fontFamily: style.fontFamily,
      fontScale: style.fontScale,
      fontWeight: math.max(600, style.fontWeight),
      italic: style.italic,
      underline: style.underline,
      textAlign: style.textAlign,
      textIndentEm: 0,
      marginTopEm: style.marginTopEm.clamp(0, 1.2),
      marginBottomEm: style.marginBottomEm.clamp(0.25, 0.8),
      colorArgb: style.colorArgb,
      backgroundColorArgb: style.backgroundColorArgb,
      backgroundImagePath: style.backgroundImagePath,
    );
  }
  final withoutIndent =
      tag == 'blockquote' || tag == 'figcaption' || tag == 'li' || tag == 'pre';
  return EpubContentStyle(
    fontFamily: style.fontFamily,
    fontWeight: 400,
    italic: style.italic,
    underline: style.underline,
    textAlign: 'start',
    textIndentEm: withoutIndent ? 0 : 2,
    colorArgb: style.colorArgb,
    backgroundColorArgb: style.backgroundColorArgb,
    backgroundImagePath: style.backgroundImagePath,
  );
}

EpubContentStyle _normalizeInlineStyle(
  EpubContentStyle style, {
  required EpubContentStyle inherited,
}) {
  return EpubContentStyle(
    fontFamily: style.fontFamily ?? inherited.fontFamily,
    fontScale: inherited.fontScale,
    fontWeight: style.fontWeight,
    italic: style.italic,
    underline: style.underline,
    textAlign: inherited.textAlign,
    textIndentEm: inherited.textIndentEm,
    colorArgb: style.colorArgb,
    backgroundColorArgb: style.backgroundColorArgb,
  );
}

EpubContentStyle _normalizeImageStyle(EpubContentStyle style) {
  return EpubContentStyle(
    textAlign: style.textAlign,
    textIndentEm: 0,
    marginTopEm: style.marginTopEm.clamp(0, 1),
    marginBottomEm: style.marginBottomEm.clamp(0, 1),
    backgroundColorArgb: style.backgroundColorArgb,
    backgroundImagePath: style.backgroundImagePath,
  );
}

List<_RawRun> _compactRuns(List<_RawRun> source, EpubContentStyle blockStyle) {
  if (source.isEmpty) return const <_RawRun>[];
  final compact = <_RawRun>[];
  for (final run in source) {
    // Two runs merge only when they also share a link target, otherwise a
    // footnote marker would dissolve into the sentence around it.
    if (compact.isNotEmpty &&
        compact.last.href == run.href &&
        _sameEpubStyle(compact.last.style, run.style)) {
      final previous = compact.removeLast();
      compact.add(previous.withText('${previous.text}${run.text}'));
    } else {
      compact.add(run);
    }
  }
  // A paragraph whose runs all match the block style needs no run list, unless
  // one of them carries a link that only the run list can hold.
  if (compact.every(
    (run) => run.href == null && _sameEpubStyle(run.style, blockStyle),
  )) {
    return const <_RawRun>[];
  }
  return List<_RawRun>.unmodifiable(compact);
}

bool _sameEpubStyle(EpubContentStyle first, EpubContentStyle second) =>
    first.fontFamily == second.fontFamily &&
    first.fontScale == second.fontScale &&
    first.fontWeight == second.fontWeight &&
    first.italic == second.italic &&
    first.underline == second.underline &&
    first.textAlign == second.textAlign &&
    first.lineHeightScale == second.lineHeightScale &&
    first.letterSpacingEm == second.letterSpacingEm &&
    first.textIndentEm == second.textIndentEm &&
    first.marginTopEm == second.marginTopEm &&
    first.marginBottomEm == second.marginBottomEm &&
    first.colorArgb == second.colorArgb &&
    first.backgroundColorArgb == second.backgroundColorArgb &&
    first.backgroundImagePath == second.backgroundImagePath;

/// Structural containers that must always be walked into, never collapsed
/// into a single leaf block — flattening `<html>`/`<body>` would merge every
/// paragraph of a chapter into one run.
const _transparentContainers = <String>{'html', 'body'};

/// A run before its anchor href has been resolved to a chapter and block.
///
/// The spine is still being read while blocks are built, so a link can only be
/// turned into coordinates once every chapter exists. [href] holds the
/// normalized `path` or `path#fragment` until that second pass runs.
class _RawRun {
  final String text;
  final EpubContentStyle style;
  final String? href;

  const _RawRun(this.text, this.style, this.href);

  _RawRun withText(String replacement) => _RawRun(replacement, style, href);
}

class _CollectedRuns {
  final String text;
  final List<_RawRun> runs;

  const _CollectedRuns(this.text, this.runs);
}

class _EpubRunCollector {
  final List<_RawRun> _runs = <_RawRun>[];
  var _hasText = false;
  var _endsWithSpace = false;

  void add(String rawText, EpubContentStyle style, {String? href}) {
    if (rawText.isEmpty) return;
    var text = rawText.replaceAll(RegExp(r'\s+'), ' ');
    if (!_hasText) text = text.trimLeft();
    if (_endsWithSpace) text = text.trimLeft();
    if (text.isEmpty) return;
    _runs.add(_RawRun(text, style, href));
    _hasText = true;
    _endsWithSpace = text.endsWith(' ');
  }

  _CollectedRuns? finish() {
    if (_runs.isEmpty) return null;
    final last = _runs.removeLast();
    final lastText = last.text.trimRight();
    if (lastText.isNotEmpty) _runs.add(last.withText(lastText));
    final text = _runs.map((run) => run.text).join().trim();
    if (text.isEmpty) return null;
    return _CollectedRuns(text, List<_RawRun>.unmodifiable(_runs));
  }
}

class _CssRule {
  final String selector;
  final Map<String, String> declarations;
  final int specificity;
  final int order;

  const _CssRule({
    required this.selector,
    required this.declarations,
    required this.specificity,
    required this.order,
  });
}

class _EpubStyleResolver {
  final List<_CssRule> _rules;
  final String? Function(String rawUrl) resolveImage;
  final String? Function(String rawFamily) resolveFontFamily;
  final Expando<Map<String, String>> _declarationCache =
      Expando<Map<String, String>>('epub-css-declarations');

  _EpubStyleResolver(
    String cssText, {
    required Map<String, List<_CssRule>> rulesCache,
    required this.resolveImage,
    required this.resolveFontFamily,
  }) : _rules = rulesCache.putIfAbsent(
         cssText,
         () => List<_CssRule>.unmodifiable(_parseCssRules(cssText)),
       );

  bool isHidden(Element element) {
    final display = propertyFor(element, 'display')?.toLowerCase();
    final visibility = propertyFor(element, 'visibility')?.toLowerCase();
    return display == 'none' || visibility == 'hidden';
  }

  String? propertyFor(Element element, String property) {
    final declarations = _declarationsFor(element);
    return declarations[property.toLowerCase()];
  }

  EpubContentStyle styleFor(
    Element element, {
    required EpubContentStyle inherited,
  }) {
    final tag = element.localName;
    var fontScale = inherited.fontScale;
    var fontFamily = inherited.fontFamily;
    var fontWeight = inherited.fontWeight;
    var italic = inherited.italic;
    var underline = inherited.underline;
    var textAlign = inherited.textAlign;
    var lineHeightScale = inherited.lineHeightScale;
    var letterSpacingEm = inherited.letterSpacingEm;
    var colorArgb = inherited.colorArgb;
    var backgroundColorArgb = inherited.backgroundColorArgb;
    var textIndentEm = _blockElements.contains(tag)
        ? 2.0
        : inherited.textIndentEm;
    var marginTopEm = 0.0;
    var marginBottomEm = 0.0;
    String? backgroundImagePath;

    if (tag == 'h1') {
      fontScale = 1.55;
      fontWeight = 700;
      textIndentEm = 0;
      marginTopEm = 0.8;
      marginBottomEm = 0.55;
    } else if (tag == 'h2') {
      fontScale = 1.35;
      fontWeight = 700;
      textIndentEm = 0;
      marginTopEm = 0.7;
      marginBottomEm = 0.45;
    } else if (tag == 'h3' || tag == 'h4' || tag == 'h5' || tag == 'h6') {
      fontScale = 1.15;
      fontWeight = 600;
      textIndentEm = 0;
      marginTopEm = 0.6;
      marginBottomEm = 0.35;
    } else if (tag == 'blockquote') {
      textIndentEm = 0;
      marginTopEm = 0.4;
      marginBottomEm = 0.4;
    } else if (tag == 'li' || tag == 'figcaption' || tag == 'pre') {
      textIndentEm = 0;
    } else if (tag == 'strong' || tag == 'b') {
      fontWeight = math.max(700, fontWeight);
    } else if (tag == 'em' || tag == 'i' || tag == 'cite') {
      italic = true;
    } else if (tag == 'u') {
      underline = true;
    } else if (tag == 'small') {
      fontScale *= 0.85;
    } else if (tag == 'big') {
      fontScale *= 1.15;
    }

    final declarations = _declarationsFor(element);
    final declaredFamily = declarations['font-family'];
    if (declaredFamily != null) {
      fontFamily = resolveFontFamily(declaredFamily) ?? fontFamily;
    }
    fontScale = _fontScale(declarations['font-size'], fontScale);
    fontWeight = _fontWeight(declarations['font-weight'], fontWeight);
    final fontStyle = declarations['font-style']?.toLowerCase();
    if (fontStyle != null) {
      italic = fontStyle.contains('italic') || fontStyle.contains('oblique');
    }
    final decoration = declarations['text-decoration']?.toLowerCase();
    if (decoration != null) underline = decoration.contains('underline');
    textAlign = _textAlign(declarations['text-align']) ?? textAlign;
    lineHeightScale = _lineHeightScale(
      declarations['line-height'],
      lineHeightScale,
      fontScale,
    );
    letterSpacingEm = _emLength(
      declarations['letter-spacing'],
      fallback: letterSpacingEm,
    );
    textIndentEm = _emLength(
      declarations['text-indent'],
      fallback: textIndentEm,
    );
    marginTopEm = _emLength(declarations['margin-top'], fallback: marginTopEm);
    marginBottomEm = _emLength(
      declarations['margin-bottom'],
      fallback: marginBottomEm,
    );
    final margin = declarations['margin'];
    if (margin != null) {
      final values = margin.trim().split(RegExp(r'\s+'));
      if (values.isNotEmpty) {
        marginTopEm = _emLength(values.first, fallback: marginTopEm);
        marginBottomEm = _emLength(
          values.length >= 3 ? values[2] : values.first,
          fallback: marginBottomEm,
        );
      }
    }
    colorArgb = _parseCssColor(declarations['color']) ?? colorArgb;
    backgroundColorArgb =
        _parseCssColor(declarations['background-color']) ?? backgroundColorArgb;
    final background =
        declarations['background-image'] ?? declarations['background'];
    final backgroundUrl = _cssUrl(background);
    if (backgroundUrl != null) {
      backgroundImagePath = resolveImage(backgroundUrl);
    }

    return EpubContentStyle(
      fontFamily: fontFamily,
      fontScale: fontScale.clamp(0.6, 2.5),
      fontWeight: fontWeight.clamp(100, 900),
      italic: italic,
      underline: underline,
      textAlign: textAlign,
      lineHeightScale: lineHeightScale.clamp(0.7, 1.8),
      letterSpacingEm: letterSpacingEm.clamp(-0.15, 0.5),
      textIndentEm: textIndentEm.clamp(0, 8),
      marginTopEm: marginTopEm.clamp(0, 6),
      marginBottomEm: marginBottomEm.clamp(0, 6),
      colorArgb: colorArgb,
      backgroundColorArgb: backgroundColorArgb,
      backgroundImagePath: backgroundImagePath,
    );
  }

  Map<String, String> _declarationsFor(Element element) {
    final cached = _declarationCache[element];
    if (cached != null) return cached;
    final matched =
        _rules
            .where((rule) => _matchesSelector(element, rule.selector))
            .toList()
          ..sort((a, b) {
            final specificity = a.specificity.compareTo(b.specificity);
            return specificity != 0 ? specificity : a.order.compareTo(b.order);
          });
    final declarations = <String, String>{};
    for (final rule in matched) {
      declarations.addAll(rule.declarations);
    }
    final inline = element.attributes['style'];
    if (inline != null) declarations.addAll(_parseDeclarations(inline));
    _declarationCache[element] = declarations;
    return declarations;
  }
}

List<_CssRule> _parseCssRules(String cssText) {
  if (cssText.trim().isEmpty) return const <_CssRule>[];
  final clean = cssText
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(
        RegExp(r'@(?:import|charset)\b[^;]*;', caseSensitive: false),
        '',
      );
  final rules = <_CssRule>[];
  var order = 0;
  for (final match in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(clean)) {
    final body = match.group(2);
    if (body == null) continue;
    final declarations = _parseDeclarations(body);
    if (declarations.isEmpty) continue;
    for (final rawSelector in (match.group(1) ?? '').split(',')) {
      final selector = rawSelector.trim();
      if (selector.isEmpty || selector.startsWith('@')) continue;
      rules.add(
        _CssRule(
          selector: selector,
          declarations: declarations,
          specificity: _selectorSpecificity(selector),
          order: order++,
        ),
      );
    }
  }
  return rules;
}

Map<String, String> _parseDeclarations(String body) {
  final declarations = <String, String>{};
  for (final part in body.split(';')) {
    final colon = part.indexOf(':');
    if (colon <= 0) continue;
    final property = part.substring(0, colon).trim().toLowerCase();
    final value = part
        .substring(colon + 1)
        .trim()
        .replaceAll(RegExp(r'\s*!important\s*$', caseSensitive: false), '');
    if (property.isNotEmpty && value.isNotEmpty) declarations[property] = value;
  }
  return declarations;
}

int _selectorSpecificity(String selector) {
  final ids = RegExp(r'#[\w-]+').allMatches(selector).length;
  final classes = RegExp(
    r'\.[\w-]+|\[[^\]]+\]|:[\w-]+',
  ).allMatches(selector).length;
  final tags = selector
      .split(RegExp(r'\s+|>'))
      .where((part) => RegExp(r'^[a-zA-Z][\w-]*').hasMatch(part))
      .length;
  return ids * 100 + classes * 10 + tags;
}

bool _matchesSelector(Element element, String rawSelector) {
  if (rawSelector.contains('+') || rawSelector.contains('~')) return false;
  final selector = rawSelector
      .replaceAll(RegExp(r'::?[\w-]+(?:\([^)]*\))?'), '')
      .replaceAll(RegExp(r'\[[^\]]+\]'), '')
      .trim();
  if (selector.isEmpty) return false;
  final tokens = selector
      .replaceAllMapped(RegExp(r'\s*>\s*'), (_) => ' > ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  final parts = <String>[];
  final childRelations = <bool>[];
  var nextIsChild = false;
  for (final token in tokens) {
    if (token == '>') {
      nextIsChild = true;
      continue;
    }
    if (parts.isNotEmpty) childRelations.add(nextIsChild);
    parts.add(token);
    nextIsChild = false;
  }
  if (parts.isEmpty || !_matchesCompoundSelector(element, parts.last)) {
    return false;
  }
  var matchedElement = element;
  for (var index = parts.length - 2; index >= 0; index--) {
    Element? candidate = matchedElement.parent;
    if (childRelations[index]) {
      if (candidate == null ||
          !_matchesCompoundSelector(candidate, parts[index])) {
        return false;
      }
    } else {
      while (candidate != null &&
          !_matchesCompoundSelector(candidate, parts[index])) {
        candidate = candidate.parent;
      }
      if (candidate == null) return false;
    }
    matchedElement = candidate;
  }
  return true;
}

bool _matchesCompoundSelector(Element element, String selector) {
  if (selector == '*') return true;
  final tag = RegExp(r'^[a-zA-Z][\w-]*').firstMatch(selector)?.group(0);
  if (tag != null &&
      (element.localName ?? '').toLowerCase() != tag.toLowerCase()) {
    return false;
  }
  final id = RegExp(r'#([\w-]+)').firstMatch(selector)?.group(1);
  if (id != null && element.id != id) return false;
  for (final match in RegExp(r'\.([\w-]+)').allMatches(selector)) {
    if (!element.classes.contains(match.group(1))) return false;
  }
  return true;
}

double _fontScale(String? value, double inherited) {
  if (value == null) return inherited;
  final normalized = value.trim().toLowerCase();
  const keywords = <String, double>{
    'xx-small': 0.6,
    'x-small': 0.75,
    'small': 0.875,
    'medium': 1,
    'large': 1.125,
    'x-large': 1.35,
    'xx-large': 1.6,
    'smaller': 0.85,
    'larger': 1.2,
  };
  final keyword = keywords[normalized];
  if (keyword != null) {
    return normalized == 'smaller' || normalized == 'larger'
        ? inherited * keyword
        : keyword;
  }
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite) return inherited;
  if (normalized.endsWith('%')) return inherited * number / 100;
  if (normalized.endsWith('rem')) return number;
  if (normalized.endsWith('em')) return inherited * number;
  if (normalized.endsWith('pt')) return number / 12;
  if (normalized.endsWith('px')) return number / 16;
  return number;
}

int _fontWeight(String? value, int inherited) {
  if (value == null) return inherited;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'bold' || normalized == 'bolder') {
    return math.max(700, inherited);
  }
  if (normalized == 'normal') return 400;
  if (normalized == 'lighter') return math.max(100, inherited - 200);
  return double.tryParse(normalized)?.round().clamp(100, 900) ?? inherited;
}

String? _textAlign(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'left' || 'start' => 'start',
    'right' || 'end' => 'end',
    'center' => 'center',
    'justify' => 'justify',
    _ => null,
  };
}

double _lineHeightScale(String? value, double inherited, double fontScale) {
  if (value == null || value.trim().toLowerCase() == 'normal') return inherited;
  final normalized = value.trim().toLowerCase();
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite || number <= 0) return inherited;
  final ratio = normalized.endsWith('%')
      ? number / 100
      : normalized.endsWith('px')
      ? number / math.max(1, 16 * fontScale)
      : normalized.endsWith('pt')
      ? number / math.max(1, 12 * fontScale)
      : number;
  return ratio / 1.5;
}

double _emLength(String? value, {required double fallback}) {
  if (value == null) return fallback;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'normal' || normalized == 'auto') return fallback;
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite) return fallback;
  if (normalized.endsWith('px')) return number / 16;
  if (normalized.endsWith('pt')) return number / 12;
  if (normalized.endsWith('%')) return number / 100;
  return number;
}

double? _cssOrAttributePixels(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toLowerCase();
  if (normalized.endsWith('%') || normalized == 'auto') return null;
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite || number <= 0) return null;
  if (normalized.endsWith('em') || normalized.endsWith('rem')) {
    return number * 16;
  }
  if (normalized.endsWith('pt')) return number * 4 / 3;
  return number;
}

int? _parseCssColor(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'transparent' || normalized == 'currentcolor') return null;
  const names = <String, int>{
    'black': 0xff000000,
    'white': 0xffffffff,
    'red': 0xffff0000,
    'green': 0xff008000,
    'blue': 0xff0000ff,
    'gray': 0xff808080,
    'grey': 0xff808080,
    'yellow': 0xffffff00,
    'orange': 0xffffa500,
    'purple': 0xff800080,
    'brown': 0xffa52a2a,
  };
  if (names.containsKey(normalized)) return names[normalized];
  if (normalized.startsWith('#')) {
    final hex = normalized.substring(1);
    if (hex.length == 3) {
      final expanded = hex.split('').map((part) => '$part$part').join();
      final parsed = int.tryParse(expanded, radix: 16);
      return parsed == null ? null : 0xff000000 | parsed;
    }
    if (hex.length == 6) {
      final parsed = int.tryParse(hex, radix: 16);
      return parsed == null ? null : 0xff000000 | parsed;
    }
    if (hex.length == 8) {
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed != null) {
        final rgb = parsed >> 8;
        final alpha = parsed & 0xff;
        return (alpha << 24) | rgb;
      }
    }
  }
  final rgb = RegExp(r'rgba?\(([^)]+)\)').firstMatch(normalized)?.group(1);
  if (rgb != null) {
    final parts = rgb.split(',').map((part) => part.trim()).toList();
    if (parts.length >= 3) {
      int channel(String part) {
        if (part.endsWith('%')) {
          return ((double.tryParse(part.substring(0, part.length - 1)) ?? 0) *
                  2.55)
              .round()
              .clamp(0, 255);
        }
        return (double.tryParse(part) ?? 0).round().clamp(0, 255);
      }

      final alpha = parts.length >= 4
          ? (parts[3].endsWith('%')
                ? ((double.tryParse(
                                parts[3].substring(0, parts[3].length - 1),
                              ) ??
                              100) *
                          2.55)
                      .round()
                      .clamp(0, 255)
                : ((double.tryParse(parts[3]) ?? 1) * 255).round().clamp(
                    0,
                    255,
                  ))
          : 255;
      return (alpha << 24) |
          (channel(parts[0]) << 16) |
          (channel(parts[1]) << 8) |
          channel(parts[2]);
    }
  }
  return null;
}

String? _cssUrl(String? value) {
  if (value == null) return null;
  return RegExp(
    r'''url\(\s*["']?([^"')]+)["']?\s*\)''',
    caseSensitive: false,
  ).firstMatch(value)?.group(1)?.trim();
}

class _EpubFontStore {
  _EpubFontStore({
    required this.archiveLookup,
    required this.encryptedPaths,
    required this.outputDirectory,
    required this.bookId,
  });

  final _ArchiveLookup archiveLookup;
  final Set<String> encryptedPaths;
  final Directory outputDirectory;
  final String bookId;
  final Map<String, String> _declaredFamilies = <String, String>{};
  final Map<String, String> _embeddedFonts = <String, String>{};

  Map<String, String> get embeddedFonts =>
      Map<String, String>.unmodifiable(_embeddedFonts);

  void registerCss(String cssText, {String? basePath}) {
    for (final match in RegExp(
      r'@font-face\s*\{([^{}]*)\}',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(cssText)) {
      final declarations = _parseDeclarations(match.group(1) ?? '');
      final rawFamily = declarations['font-family'];
      final rawSources =
          RegExp(r'''url\(\s*["']?([^"')]+)["']?\s*\)''', caseSensitive: false)
              .allMatches(declarations['src'] ?? '')
              .map((match) => match.group(1)?.trim() ?? '')
              .where((value) => value.isNotEmpty);
      if (rawFamily == null) continue;
      final normalizedFamily = _normalizeFontFamilyName(
        rawFamily.split(',').first,
      );
      if (normalizedFamily.isEmpty ||
          _declaredFamilies.containsKey(normalizedFamily)) {
        continue;
      }
      for (final rawSource in rawSources) {
        if (rawSource.startsWith('data:')) continue;
        final resolvedPath = _resolveArchiveReference(
          rawSource,
          basePath ?? '',
        );
        if (resolvedPath.isEmpty) continue;
        final archivePath =
            archiveLookup.canonicalPath(resolvedPath) ?? resolvedPath;
        final extension = p.posix.extension(archivePath).toLowerCase();
        if (extension != '.ttf' && extension != '.otf') continue;
        if (_isEncryptedPath(archivePath, archiveLookup, encryptedPaths)) {
          continue;
        }
        final source = archiveLookup.find(archivePath);
        if (source == null ||
            source.size <= 0 ||
            source.size > 64 * 1024 * 1024) {
          continue;
        }
        final safeToken = base64Url
            .encode(utf8.encode('$bookId:$normalizedFamily'))
            .replaceAll('=', '')
            .replaceAll('-', '_');
        final family =
            'ReadVibeEpub_${safeToken.substring(0, math.min(48, safeToken.length))}';
        final target = File(
          p.join(
            outputDirectory.path,
            'font_${_embeddedFonts.length}$extension',
          ),
        );
        try {
          target.writeAsBytesSync(_bytesOf(source), flush: true);
          _declaredFamilies[normalizedFamily] = family;
          _embeddedFonts[family] = target.path;
          break;
        } on Object {
          // A broken optional publisher font must not make the book unreadable.
        }
      }
    }
  }

  String? resolveFamily(String rawFamily) {
    for (final candidate in rawFamily.split(',')) {
      final family = _declaredFamilies[_normalizeFontFamilyName(candidate)];
      if (family != null) return family;
    }
    return null;
  }
}

String _normalizeFontFamilyName(String value) => value
    .trim()
    .replaceAll(RegExp(r'''^["']|["']$'''), '')
    .trim()
    .toLowerCase();

class _ExtractedImage {
  final String path;
  final double? width;
  final double? height;

  const _ExtractedImage(this.path, this.width, this.height);
}

class _EpubImageStore {
  _EpubImageStore({
    required this.archiveLookup,
    required this.encryptedPaths,
    required this.outputDirectory,
    required this.maxSingleImageBytes,
  });

  final _ArchiveLookup archiveLookup;
  final Set<String> encryptedPaths;
  final Directory outputDirectory;
  final int maxSingleImageBytes;
  final Map<String, _ExtractedImage?> _cache = <String, _ExtractedImage?>{};
  var _dataImageIndex = 0;

  _ExtractedImage? extract(String rawReference, {required String relativeTo}) {
    final reference = rawReference.trim();
    final lowerReference = reference.toLowerCase();
    if (reference.isEmpty || reference.startsWith('//')) return null;
    if (lowerReference.startsWith('data:image/')) {
      return _extractDataImage(reference);
    }
    try {
      final parsedReference = Uri.tryParse(reference);
      if (parsedReference?.hasScheme == true) return null;
      final archivePath = _resolveArchiveReference(reference, relativeTo);
      if (archivePath.isEmpty) return null;
      return extractArchivePath(archivePath);
    } on Object {
      return null;
    }
  }

  _ExtractedImage? extractArchivePath(String rawArchivePath) {
    final requestedPath = _normalizeArchivePath(rawArchivePath);
    if (requestedPath.isEmpty) return null;
    final archivePath =
        archiveLookup.canonicalPath(requestedPath) ?? requestedPath;
    if (_isEncryptedPath(archivePath, archiveLookup, encryptedPaths)) {
      return null;
    }
    return _cache.putIfAbsent(archivePath, () {
      try {
        final file = archiveLookup.find(archivePath);
        if (file == null || file.size <= 0 || file.size > maxSingleImageBytes) {
          return null;
        }
        final bytes = Uint8List.fromList(_bytesOf(file));
        final extension = _safeImageExtension(archivePath, bytes);
        if (extension == null) return null;
        final encodedName = base64Url
            .encode(utf8.encode(archivePath))
            .replaceAll('=', '');
        final target = File(
          p.join(outputDirectory.path, '$encodedName$extension'),
        );
        target.writeAsBytesSync(bytes);
        final dimensions = _imageDimensions(bytes, extension);
        return _ExtractedImage(
          target.path,
          dimensions?.width,
          dimensions?.height,
        );
      } on Object {
        // A corrupt single image is an omitted illustration, not a failed book.
        return null;
      }
    });
  }

  _ExtractedImage? _extractDataImage(String reference) {
    final comma = reference.indexOf(',');
    if (comma <= 0 ||
        !reference.substring(0, comma).toLowerCase().contains(';base64')) {
      return null;
    }
    try {
      final payloadStart = comma + 1;
      if (!_base64PayloadFitsByteLimit(
        reference,
        payloadStart,
        maxSingleImageBytes,
      )) {
        return null;
      }
      final payload = reference.substring(payloadStart);
      final bytes = base64.decode(payload);
      if (bytes.isEmpty || bytes.length > maxSingleImageBytes) return null;
      final extension = _safeImageExtension(
        reference.substring(0, comma),
        bytes,
      );
      if (extension == null) return null;
      final key =
          'data:${base64Url.encode(bytes.take(math.min(48, bytes.length)).toList())}:${bytes.length}';
      return _cache.putIfAbsent(key, () {
        try {
          final target = File(
            p.join(
              outputDirectory.path,
              'inline_${_dataImageIndex++}$extension',
            ),
          );
          target.writeAsBytesSync(bytes);
          final dimensions = _imageDimensions(
            Uint8List.fromList(bytes),
            extension,
          );
          return _ExtractedImage(
            target.path,
            dimensions?.width,
            dimensions?.height,
          );
        } on Object {
          return null;
        }
      });
    } on Object {
      return null;
    }
  }
}

bool _base64PayloadFitsByteLimit(String source, int start, int maxBytes) {
  if (start < 0 || start >= source.length || maxBytes <= 0) return false;
  final maxEncodedCharacters = ((maxBytes + 2) ~/ 3) * 4;
  // Base64Codec normalizes whitespace before decoding. Bound the original
  // string too so a whitespace-heavy data URI cannot force a huge temporary
  // normalization allocation despite decoding to only a few bytes.
  if (source.length - start > maxEncodedCharacters) return false;

  var symbols = 0;
  var previousSymbol = -1;
  var lastSymbol = -1;
  for (var index = start; index < source.length; index++) {
    final codeUnit = source.codeUnitAt(index);
    if (_isAsciiWhitespace(codeUnit)) continue;
    symbols++;
    previousSymbol = lastSymbol;
    lastSymbol = codeUnit;
  }
  if (symbols == 0 || symbols % 4 == 1) return false;

  final fullGroups = symbols ~/ 4;
  final remainder = symbols % 4;
  var decodedBytes = fullGroups * 3;
  if (remainder == 2) decodedBytes += 1;
  if (remainder == 3) decodedBytes += 2;
  if (remainder == 0 && lastSymbol == 0x3d) {
    decodedBytes--;
    if (previousSymbol == 0x3d) decodedBytes--;
  }
  return decodedBytes >= 0 && decodedBytes <= maxBytes;
}

bool _isAsciiWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0d;

int _formatMegabytes(int bytes) => (bytes / (1024 * 1024)).ceil();

String? _safeImageExtension(String pathOrMime, Uint8List bytes) {
  final value = pathOrMime.toLowerCase();
  if (value.contains('image/png') ||
      _hasBytes(bytes, const [0x89, 0x50, 0x4e, 0x47])) {
    return '.png';
  }
  if (value.contains('image/jpeg') ||
      value.contains('image/jpg') ||
      _hasBytes(bytes, const [0xff, 0xd8])) {
    return '.jpg';
  }
  if (value.contains('image/gif') || _hasAscii(bytes, 0, 'GIF8')) return '.gif';
  if (value.contains('image/webp') ||
      (_hasAscii(bytes, 0, 'RIFF') && _hasAscii(bytes, 8, 'WEBP'))) {
    return '.webp';
  }
  if (value.contains('image/bmp') || _hasAscii(bytes, 0, 'BM')) return '.bmp';
  return null;
}

({double width, double height})? _imageDimensions(
  Uint8List bytes,
  String extension,
) {
  try {
    final data = ByteData.sublistView(bytes);
    if (extension == '.png' && bytes.length >= 24) {
      return (
        width: data.getUint32(16, Endian.big).toDouble(),
        height: data.getUint32(20, Endian.big).toDouble(),
      );
    }
    if (extension == '.gif' && bytes.length >= 10) {
      return (
        width: data.getUint16(6, Endian.little).toDouble(),
        height: data.getUint16(8, Endian.little).toDouble(),
      );
    }
    if (extension == '.bmp' && bytes.length >= 26) {
      return (
        width: data.getInt32(18, Endian.little).abs().toDouble(),
        height: data.getInt32(22, Endian.little).abs().toDouble(),
      );
    }
    if (extension == '.jpg') {
      var offset = 2;
      while (offset + 9 < bytes.length) {
        if (bytes[offset] != 0xff) {
          offset++;
          continue;
        }
        final marker = bytes[offset + 1];
        if (marker >= 0xc0 && marker <= 0xc3) {
          return (
            width: data.getUint16(offset + 7, Endian.big).toDouble(),
            height: data.getUint16(offset + 5, Endian.big).toDouble(),
          );
        }
        if (offset + 4 > bytes.length) break;
        final length = data.getUint16(offset + 2, Endian.big);
        if (length < 2) break;
        offset += 2 + length;
      }
    }
    if (extension == '.webp' && bytes.length >= 30) {
      if (_hasAscii(bytes, 12, 'VP8X')) {
        int u24(int offset) =>
            bytes[offset] |
            (bytes[offset + 1] << 8) |
            (bytes[offset + 2] << 16);
        return (
          width: (u24(24) + 1).toDouble(),
          height: (u24(27) + 1).toDouble(),
        );
      }
      if (_hasAscii(bytes, 12, 'VP8 ') &&
          bytes.length >= 30 &&
          bytes[23] == 0x9d &&
          bytes[24] == 0x01 &&
          bytes[25] == 0x2a) {
        return (
          width: (data.getUint16(26, Endian.little) & 0x3fff).toDouble(),
          height: (data.getUint16(28, Endian.little) & 0x3fff).toDouble(),
        );
      }
      if (_hasAscii(bytes, 12, 'VP8L') &&
          bytes.length >= 25 &&
          bytes[20] == 0x2f) {
        final bits =
            bytes[21] |
            (bytes[22] << 8) |
            (bytes[23] << 16) |
            (bytes[24] << 24);
        return (
          width: ((bits & 0x3fff) + 1).toDouble(),
          height: (((bits >> 14) & 0x3fff) + 1).toDouble(),
        );
      }
    }
  } on Object {
    return null;
  }
  return null;
}

bool _hasBytes(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

bool _hasAscii(Uint8List bytes, int offset, String text) {
  if (offset < 0 || offset + text.length > bytes.length) return false;
  for (var index = 0; index < text.length; index++) {
    if (bytes[offset + index] != text.codeUnitAt(index)) return false;
  }
  return true;
}

String _resolveArchiveReference(
  String rawReference,
  String relativeTo, {
  bool baseIsDirectory = false,
}) {
  final withoutFragment = rawReference.split('#').first.split('?').first.trim();
  if (withoutFragment.isEmpty) return '';
  final decoded = _safeDecodeUriComponent(withoutFragment);
  final baseDirectory = baseIsDirectory
      ? relativeTo
      : p.posix.dirname(relativeTo);
  final joined = p.posix.isAbsolute(decoded)
      ? decoded
      : p.posix.join(baseDirectory, decoded);
  final normalized = _normalizeArchivePath(joined);
  if (normalized == '..' || normalized.startsWith('../')) return '';
  return normalized;
}

Iterable<XmlElement> _elementsNamed(XmlNode node, String localName) sync* {
  final exact = node.descendants.whereType<XmlElement>().where(
    (element) => element.name.local == localName,
  );
  if (exact.isNotEmpty) {
    yield* exact;
    return;
  }
  // The lenient HTML fallback lowercases element names. Only when the exact
  // XML name is absent do we accept the case-folded spelling; an NCX repaired
  // this way must still yield navMap/navPoint/navLabel.
  final lower = localName.toLowerCase();
  yield* node.descendants.whereType<XmlElement>().where(
    (element) => element.name.local.toLowerCase() == lower,
  );
}

bool _xmlNameIs(XmlElement element, String localName) =>
    element.name.local == localName ||
    element.name.local.toLowerCase() == localName.toLowerCase();

String _firstElementText(XmlDocument document, String localName) =>
    _elementsNamed(document, localName).firstOrNull?.innerText.trim() ?? '';

String _safeDecodeUriComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}

/// Normalizes a container-internal ZIP path.
///
/// A leading slash means the container root, never the device filesystem.
/// Parent traversal is rejected by [_resolveArchiveReference] before lookup.
String _normalizeArchivePath(String value) {
  var normalized = value.replaceAll('\\', '/');
  if (normalized.isEmpty) return '';
  normalized = p.posix.normalize(normalized);
  while (normalized.startsWith('/')) {
    normalized = normalized.substring(1);
  }
  if (normalized == '.') return '';
  return normalized;
}

List<int> _bytesOf(ArchiveFile file) {
  try {
    return file.content;
  } on Object {
    throw FormatException('EPUB 条目已损坏：${file.name}');
  }
}

XmlDocument _parseXml(ArchiveFile file, String label, {bool lenient = false}) {
  final text = decodeEpubMarkup(_bytesOf(file));
  try {
    return XmlDocument.parse(text);
  } on XmlException {
    if (lenient) {
      final repaired = _parseXmlThroughHtml(text);
      if (repaired != null) return repaired;
    }
    throw FormatException('$label 格式错误，无法解析 EPUB');
  }
}

/// Last-resort repair for package documents with mismatched tags.
///
/// Exact XML is tried first. Only after it fails do we let the HTML parser
/// repair the tree, then rebuild a minimal XML document for the existing
/// local-name lookups. Prefixes are dropped from names because the parser only
/// reads local names (title, item, itemref, navPoint, content, ...).
XmlDocument? _parseXmlThroughHtml(String text) {
  try {
    final document = html_parser.parse(text);
    final builder = XmlBuilder();
    void copyNode(Node node) {
      if (node is Text) {
        builder.text(node.data);
        return;
      }
      if (node is! Element) return;
      final attributes = <String, String>{};
      node.attributes.forEach((key, value) {
        final name = _xmlSafeName(key.toString());
        if (name.isNotEmpty) attributes[name] = value;
      });
      builder.element(
        _xmlSafeName(node.localName ?? ''),
        attributes: attributes,
        nest: () {
          for (final child in node.nodes) {
            copyNode(child);
          }
        },
      );
    }

    for (final node in document.nodes) {
      copyNode(node);
    }
    return builder.buildDocument();
  } on Object {
    return null;
  }
}

String _xmlSafeName(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  final colon = value.indexOf(':');
  if (colon >= 0 && colon + 1 < value.length) {
    value = value.substring(colon + 1);
  }
  value = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  if (value.isEmpty) return '';
  if (RegExp(r'^[0-9.-]').hasMatch(value)) return 'n_$value';
  return value;
}

String? _extractDocumentTitle(Document document) {
  final title = document.querySelector('title')?.text.trim();
  return title == null || title.isEmpty ? null : title;
}

String _normalizeVisibleText(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();
