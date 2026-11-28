import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dart3_big5/big5.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/book.dart';
import 'book_id.dart';
import 'epub_markup_decoder.dart';
import '../repositories/app_data_directory_provider.dart';

part 'epub/epub_archive_utils.dart';
part 'epub/epub_css_resolver.dart';
part 'epub/epub_document_parser.dart';
part 'epub/epub_media_store.dart';
part 'epub/epub_navigation.dart';

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
  final input = InputFileStream(filePath);
  try {
    late final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
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
    final encryptionInfo = _epubEncryptionInfo(archiveLookup);
    final encryptedPaths = encryptionInfo.drmEncryptedPaths;

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
    final packageIdentifiers = _opfIdentifiers(opf);
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
      idpfObfuscatedFonts: encryptionInfo.idpfObfuscatedFonts,
      adobeObfuscatedFonts: encryptionInfo.adobeObfuscatedFonts,
      packageIdentifiers: packageIdentifiers,
      outputDirectory: resourceDirectory,
      bookId: bookId,
    );
    final coverArchivePath = _epubCoverArchivePath(
      opf,
      opfDir,
      manifest,
      archiveLookup,
    );
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
          references
              .where(documentCandidates.containsKey)
              .toList(growable: false)
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
        if (_documentKind(item, archiveLookup) !=
            _EpubDocumentKind.unsupported) {
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
      navigationBlocks: assembler.navigationBlocks,
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
  } finally {
    input.closeSync();
  }
}

List<String> _opfIdentifiers(XmlDocument opf) {
  final uniqueId = _elementsNamed(opf, 'package')
      .firstOrNull
      ?.getAttribute('unique-identifier')
      ?.trim();
  final ordered = <String>[];
  final others = <String>[];
  for (final element in _elementsNamed(opf, 'identifier')) {
    final text = element.innerText.trim();
    if (text.isEmpty) continue;
    final id = element.getAttribute('id')?.trim();
    if (uniqueId != null && uniqueId.isNotEmpty && id == uniqueId) {
      ordered.add(text);
    } else {
      others.add(text);
    }
  }
  return <String>[...ordered, ...others];
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
  final Map<int, Set<int>> navigationBlocks = <int, Set<int>>{};
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
          final document = html_parser.parse(
            normalizeXhtmlSelfClosingTags(decodeEpubMarkup(_bytesOf(file))),
          );
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
            navigationBlocks: parsed.navigationBlocks,
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

      if (loaded.navigationBlocks.isNotEmpty) {
        final localNavigationBlocks = <int>{
          for (final blockIndex in loaded.navigationBlocks)
            if (blockIndex >= plan.start && blockIndex < plan.end)
              blockIndex - plan.start,
        };
        if (localNavigationBlocks.isNotEmpty) {
          navigationBlocks[chapterIndex] = localNavigationBlocks;
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
  final entries = navigation.entriesForPath(path);
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
    final fragment = entry.fragment;
    final blockIndex = (fragment == null || fragment.isEmpty)
        ? 0
        : blockByAnchor[fragment];
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
  final document = html_parser.parse(
    normalizeXhtmlSelfClosingTags(decodeEpubMarkup(_bytesOf(file))),
  );
  final documentTitle = _extractDocumentTitle(document);
  final imageElements = <Element>[];
  final textElements = <Element>[];
  final root = document.documentElement;
  if (root != null) {
    void collect(Element element) {
      if (element.localName == 'image' || element.localName == 'img') {
        imageElements.add(element);
      } else if (element.localName == 'text') {
        textElements.add(element);
        return;
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
  for (final element in textElements) {
    final text = _normalizeVisibleText(element.text);
    if (text.isEmpty) continue;
    blocks.add(
      EpubContentBlock(
        kind: EpubContentBlockKind.text,
        text: text,
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
  required Map<int, Set<int>> navigationBlocks,
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
          needDirectJump:
              navigationBlocks[entry.key]?.contains(blockIndex) ?? false,
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
  required bool needDirectJump,
}) {
  final hashIndex = href.indexOf('#');
  final path = hashIndex < 0 ? href : href.substring(0, hashIndex);
  final firstChapter = chapterIndexByPath[path];
  if (firstChapter == null) return null;
  if (hashIndex < 0) {
    return EpubLinkTarget(
      chapterIndex: firstChapter,
      needDirectJump: needDirectJump,
    );
  }
  final location = anchorLocations[href];
  if (location == null) {
    return EpubLinkTarget(
      chapterIndex: firstChapter,
      needDirectJump: needDirectJump,
    );
  }
  return EpubLinkTarget(
    chapterIndex: location.chapterIndex,
    blockIndex: location.blockIndex,
    needDirectJump: needDirectJump,
  );
}
