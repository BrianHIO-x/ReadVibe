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
import 'storage_service.dart';

const _maxArchiveEntries = 20000;
const _maxExpandedBytes = 512 * 1024 * 1024;
const _maxSingleImageBytes = 64 * 1024 * 1024;

/// Parses an EPUB into the same chapter model used by TXT while retaining a
/// safe, offline subset of publisher CSS and local images.
Future<Book> parseEpub(
  String filePath,
  String fileName,
  StorageService storage,
) async {
  final now = DateTime.now();
  final bookId = 'epub_${now.microsecondsSinceEpoch}';
  final root = await storage.getAppDataDirectory();
  final resourceDirectory = Directory(p.join(root.path, 'epub', bookId));
  try {
    return await Isolate.run(
      () => _parseEpubSync(
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
      // The import error remains authoritative; cleanup can be retried when
      // the enclosing app data directory is next maintained.
    }
    rethrow;
  }
}

Book _parseEpubSync(
  String filePath,
  String fileName,
  String bookId,
  DateTime importDate,
  String resourceDirectoryPath,
) {
  final bytes = File(filePath).readAsBytesSync();
  if (bytes.isEmpty) throw const FormatException('EPUB 文件为空');

  late final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on FormatException {
    throw const FormatException('无效的 EPUB 文件：ZIP 数据已损坏');
  }
  if (archive.files.length > _maxArchiveEntries) {
    throw const FormatException('EPUB 文件包含过多条目，无法安全解析');
  }

  var expandedBytes = 0;
  final archiveFiles = <String, ArchiveFile>{};
  for (final file in archive.files) {
    expandedBytes += file.size;
    if (expandedBytes > _maxExpandedBytes) {
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
  final navigationTitles = _extractNavigationTitles(
    opf,
    manifest,
    archiveFiles,
  );
  final spineIds = _elementsNamed(opf, 'itemref')
      .where(
        (element) =>
            element.getAttribute('linear')?.toLowerCase().trim() != 'no',
      )
      .map((element) => element.getAttribute('idref'))
      .whereType<String>()
      .toList(growable: false);

  final resourceDirectory = Directory(resourceDirectoryPath);
  resourceDirectory.createSync(recursive: true);
  final imageStore = _EpubImageStore(
    archiveFiles: archiveFiles,
    outputDirectory: resourceDirectory,
  );
  final chapters = <Chapter>[];
  String? activeVolumeTitle;
  final cssDocumentCache = <String, String>{};
  final cssRulesCache = <String, List<_CssRule>>{};

  for (final itemId in spineIds) {
    final manifestItem = manifest[itemId];
    if (manifestItem == null || !_isMarkupMediaType(manifestItem.mediaType)) {
      continue;
    }
    final contentFile = _findArchiveFile(archiveFiles, manifestItem.path);
    if (contentFile == null) continue;

    final document = html_parser.parse(_decodeMarkup(_bytesOf(contentFile)));
    final cssText = _chapterCssText(
      document,
      manifestItem.path,
      archiveFiles,
      cssDocumentCache,
    );
    final resolver = _EpubStyleResolver(
      cssText,
      rulesCache: cssRulesCache,
      resolveImage: (rawUrl) =>
          imageStore.extract(rawUrl, relativeTo: manifestItem.path)?.path,
    );
    final blocks = _documentToBlocks(
      document,
      manifestItem.path,
      resolver,
      imageStore,
    );

    if (blocks.isEmpty) continue;

    final embeddedHeading = blocks
        .where((block) => block.isText && block.isHeading)
        .firstOrNull;
    final chapterTitle =
        navigationTitles[manifestItem.path] ??
        embeddedHeading?.text.trim() ??
        _extractDocumentTitle(document) ??
        '章节 ${chapters.length + 1}';
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
    if (isVolumeChapterTitle(chapterTitle)) {
      activeVolumeTitle = chapterTitle;
    }
    chapters.add(
      Chapter(
        index: chapters.length,
        title: chapterTitle,
        content: plainText,
        volumeTitle: isStandaloneChapterTitle(chapterTitle)
            ? null
            : activeVolumeTitle,
        epubBlocks: List<EpubContentBlock>.unmodifiable(blocks),
      ),
    );
  }

  if (chapters.isEmpty) {
    throw const FormatException('无法从 EPUB 中解析出任何章节内容或图片');
  }

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
    chapters: chapters,
    importDate: importDate,
    fileSize: bytes.length,
    sourcePath: resourceDirectory.path,
  );
}

class _ManifestItem {
  final String path;
  final String mediaType;
  final Set<String> properties;

  const _ManifestItem(this.path, this.mediaType, this.properties);
}

Map<String, _ManifestItem> _extractManifest(XmlDocument opf, String opfDir) {
  final manifest = <String, _ManifestItem>{};
  for (final item in _elementsNamed(opf, 'item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id == null || href == null) continue;
    final joined = _resolveArchiveReference(
      href,
      opfDir,
      baseIsDirectory: true,
    );
    if (joined.isEmpty) continue;
    manifest[id] = _ManifestItem(
      joined,
      item.getAttribute('media-type')?.trim().toLowerCase() ?? '',
      (item.getAttribute('properties') ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((value) => value.isNotEmpty)
          .toSet(),
    );
  }
  return manifest;
}

Map<String, String> _extractNavigationTitles(
  XmlDocument opf,
  Map<String, _ManifestItem> manifest,
  Map<String, ArchiveFile> archiveFiles,
) {
  final titles = <String, String>{};

  void addTitle(String? rawReference, String? rawTitle, String relativeTo) {
    final title = _normalizeVisibleText(rawTitle ?? '');
    if (rawReference == null || title.isEmpty) return;
    final path = _resolveArchiveReference(rawReference, relativeTo);
    if (path.isNotEmpty) titles.putIfAbsent(path, () => title);
  }

  for (final item in manifest.values.where(
    (candidate) => candidate.properties.contains('nav'),
  )) {
    final file = _findArchiveFile(archiveFiles, item.path);
    if (file == null) continue;
    try {
      final document = html_parser.parse(_decodeMarkup(_bytesOf(file)));
      final navigationElements = document.querySelectorAll('nav');
      final toc = navigationElements.where((element) {
        final type =
            element.attributes['epub:type'] ??
            element.attributes['type'] ??
            element.attributes['role'] ??
            '';
        return type
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .any((value) => value == 'toc' || value == 'doc-toc');
      }).firstOrNull;
      final scope = toc ?? navigationElements.firstOrNull ?? document.body;
      for (final anchor
          in scope?.querySelectorAll('a[href]') ?? const <Element>[]) {
        addTitle(anchor.attributes['href'], anchor.text, item.path);
      }
    } on Object {
      // A malformed navigation document must not make readable spine content
      // impossible to import; the document heading remains the fallback.
    }
  }

  final spine = _elementsNamed(opf, 'spine').firstOrNull;
  final ncxId = spine?.getAttribute('toc');
  final ncxCandidates = <_ManifestItem>{
    if (ncxId != null && manifest[ncxId] != null) manifest[ncxId]!,
    ...manifest.values.where(
      (item) => item.mediaType == 'application/x-dtbncx+xml',
    ),
  };
  for (final item in ncxCandidates) {
    final file = _findArchiveFile(archiveFiles, item.path);
    if (file == null) continue;
    try {
      final ncx = _parseXml(file, 'NCX');
      for (final navPoint in _elementsNamed(ncx, 'navPoint')) {
        final content = navPoint.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'content')
            .firstOrNull;
        final label = navPoint.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'navLabel')
            .firstOrNull;
        addTitle(content?.getAttribute('src'), label?.innerText, item.path);
      }
    } on Object {
      // EPUB 2 navigation is optional for rendering. Ignore a damaged NCX and
      // use the embedded chapter heading instead.
    }
  }
  return titles;
}

bool _isMarkupMediaType(String mediaType) =>
    mediaType.isEmpty ||
    mediaType == 'application/xhtml+xml' ||
    mediaType == 'text/html' ||
    mediaType == 'application/xml';

String _chapterCssText(
  Document document,
  String contentPath,
  Map<String, ArchiveFile> archiveFiles,
  Map<String, String> documentCache,
) {
  final output = StringBuffer();
  final visited = <String>{};

  void appendCssPath(String rawPath, String relativeTo) {
    final cssPath = _resolveArchiveReference(rawPath, relativeTo);
    if (cssPath.isEmpty || !visited.add(cssPath)) return;
    final css = documentCache.putIfAbsent(cssPath, () {
      final file = _findArchiveFile(archiveFiles, cssPath);
      if (file == null || file.size > 8 * 1024 * 1024) return '';
      return _decodeMarkup(_bytesOf(file));
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
    output.writeln(style.text);
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

List<EpubContentBlock> _documentToBlocks(
  Document document,
  String contentPath,
  _EpubStyleResolver resolver,
  _EpubImageStore imageStore,
) {
  final blocks = <EpubContentBlock>[];
  final root = document.body ?? document.documentElement;
  if (root == null) return blocks;

  void appendImage(Element image, EpubContentStyle inheritedStyle) {
    final rawSource =
        image.attributes['src'] ??
        image.attributes['xlink:href'] ??
        image.attributes['href'];
    if (rawSource == null || rawSource.trim().isEmpty) return;
    final extracted = imageStore.extract(rawSource, relativeTo: contentPath);
    if (extracted == null) return;
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
      blocks.add(
        EpubContentBlock(
          kind: EpubContentBlockKind.text,
          text: collected.text,
          runs: _compactRuns(collected.runs, blockStyle),
          isHeading: isHeading,
          style: blockStyle,
        ),
      );
    }

    void visit(Node node, EpubContentStyle style) {
      if (node is Text) {
        collector.add(node.data, style);
        return;
      }
      if (node is! Element || resolver.isHidden(node)) return;
      final tag = node.localName;
      if (tag == 'script' || tag == 'style' || tag == 'head') return;
      if (tag == 'img' || tag == 'image') {
        flushText();
        appendImage(node, style);
        return;
      }
      if (tag == 'br' || tag == 'hr') collector.add(' ', style);
      final childStyle = _normalizeInlineStyle(
        resolver.styleFor(node, inherited: style),
        inherited: style,
      );
      for (final child in node.nodes) {
        visit(child, childStyle);
      }
    }

    for (final child in element.nodes) {
      visit(child, blockStyle);
    }
    flushText();
  }

  void walk(Element element, EpubContentStyle inheritedStyle) {
    if (resolver.isHidden(element)) return;
    final style = resolver.styleFor(element, inherited: inheritedStyle);
    if (element.localName == 'img' || element.localName == 'image') {
      appendImage(element, inheritedStyle);
      return;
    }
    final containsBlockChild = element.children.any(
      (child) => _blockElements.contains(child.localName),
    );
    // Inline wrappers such as `<span>` or `<b>` legitimately hold chapter text
    // in real-world EPUBs. Treating only block tags as leaves silently dropped
    // that text whenever the wrapper sat next to block-level siblings.
    if (!containsBlockChild &&
        !_transparentContainers.contains(element.localName) &&
        (_blockElements.contains(element.localName) ||
            element.text.trim().isNotEmpty)) {
      appendLeaf(element, inheritedStyle);
      return;
    }
    for (final child in element.children) {
      walk(child, style);
    }
    if (element == root && blocks.isEmpty && element.text.trim().isNotEmpty) {
      appendLeaf(element, inheritedStyle);
    }
  }

  walk(root, const EpubContentStyle(textIndentEm: 0));
  return blocks;
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
    element.attributes['role'] ?? '',
    element.attributes['epub:type'] ?? '',
    element.attributes['type'] ?? '',
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
              style: EpubContentStyle(
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
      style: EpubContentStyle(
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

List<EpubTextRun> _compactRuns(
  List<EpubTextRun> source,
  EpubContentStyle blockStyle,
) {
  if (source.isEmpty) return const <EpubTextRun>[];
  final compact = <EpubTextRun>[];
  for (final run in source) {
    if (compact.isNotEmpty && _sameEpubStyle(compact.last.style, run.style)) {
      final previous = compact.removeLast();
      compact.add(
        EpubTextRun(text: '${previous.text}${run.text}', style: run.style),
      );
    } else {
      compact.add(run);
    }
  }
  if (compact.every((run) => _sameEpubStyle(run.style, blockStyle))) {
    return const <EpubTextRun>[];
  }
  return List<EpubTextRun>.unmodifiable(compact);
}

bool _sameEpubStyle(EpubContentStyle first, EpubContentStyle second) =>
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

class _CollectedRuns {
  final String text;
  final List<EpubTextRun> runs;

  const _CollectedRuns(this.text, this.runs);
}

class _EpubRunCollector {
  final List<EpubTextRun> _runs = <EpubTextRun>[];
  var _hasText = false;
  var _endsWithSpace = false;

  void add(String rawText, EpubContentStyle style) {
    if (rawText.isEmpty) return;
    var text = rawText.replaceAll(RegExp(r'\s+'), ' ');
    if (!_hasText) text = text.trimLeft();
    if (_endsWithSpace) text = text.trimLeft();
    if (text.isEmpty) return;
    _runs.add(EpubTextRun(text: text, style: style));
    _hasText = true;
    _endsWithSpace = text.endsWith(' ');
  }

  _CollectedRuns? finish() {
    if (_runs.isEmpty) return null;
    final last = _runs.removeLast();
    final lastText = last.text.trimRight();
    if (lastText.isNotEmpty) {
      _runs.add(EpubTextRun(text: lastText, style: last.style));
    }
    final text = _runs.map((run) => run.text).join().trim();
    if (text.isEmpty) return null;
    return _CollectedRuns(text, List<EpubTextRun>.unmodifiable(_runs));
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
  final Expando<Map<String, String>> _declarationCache =
      Expando<Map<String, String>>('epub-css-declarations');

  _EpubStyleResolver(
    String cssText, {
    required Map<String, List<_CssRule>> rulesCache,
    required this.resolveImage,
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

class _ExtractedImage {
  final String path;
  final double? width;
  final double? height;

  const _ExtractedImage(this.path, this.width, this.height);
}

class _EpubImageStore {
  final Map<String, ArchiveFile> archiveFiles;
  final Directory outputDirectory;
  final Map<String, _ExtractedImage?> _cache = <String, _ExtractedImage?>{};
  var _dataImageIndex = 0;

  _EpubImageStore({required this.archiveFiles, required this.outputDirectory});

  _ExtractedImage? extract(String rawReference, {required String relativeTo}) {
    final reference = rawReference.trim();
    final lowerReference = reference.toLowerCase();
    if (reference.isEmpty || reference.startsWith('//')) return null;
    if (lowerReference.startsWith('data:image/')) {
      return _extractDataImage(reference);
    }
    final parsedReference = Uri.tryParse(reference);
    if (parsedReference?.hasScheme == true) return null;
    final archivePath = _resolveArchiveReference(reference, relativeTo);
    if (archivePath.isEmpty) return null;
    return _cache.putIfAbsent(archivePath, () {
      final file = _findArchiveFile(archiveFiles, archivePath);
      if (file == null || file.size <= 0 || file.size > _maxSingleImageBytes) {
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
    });
  }

  _ExtractedImage? _extractDataImage(String reference) {
    final comma = reference.indexOf(',');
    if (comma <= 0 ||
        !reference.substring(0, comma).toLowerCase().contains(';base64')) {
      return null;
    }
    try {
      final bytes = base64.decode(reference.substring(comma + 1));
      if (bytes.isEmpty || bytes.length > _maxSingleImageBytes) return null;
      final extension = _safeImageExtension(
        reference.substring(0, comma),
        bytes,
      );
      if (extension == null) return null;
      final key =
          'data:${base64Url.encode(bytes.take(math.min(48, bytes.length)).toList())}:${bytes.length}';
      return _cache.putIfAbsent(key, () {
        final target = File(
          p.join(outputDirectory.path, 'inline_${_dataImageIndex++}$extension'),
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
      });
    } on FormatException {
      return null;
    }
  }
}

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
  } on RangeError {
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

Iterable<XmlElement> _elementsNamed(XmlNode node, String localName) => node
    .descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == localName);

String _firstElementText(XmlDocument document, String localName) =>
    _elementsNamed(document, localName).firstOrNull?.innerText.trim() ?? '';

ArchiveFile? _findArchiveFile(
  Map<String, ArchiveFile> archiveFiles,
  String requestedPath,
) => archiveFiles[_normalizeArchivePath(requestedPath)];

String _safeDecodeUriComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
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
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    return _decodeUtf16(bytes.sublist(2), Endian.little);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    return _decodeUtf16(bytes.sublist(2), Endian.big);
  }
  var payload = bytes;
  if (payload.length >= 3 &&
      payload[0] == 0xef &&
      payload[1] == 0xbb &&
      payload[2] == 0xbf) {
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

String? _extractDocumentTitle(Document document) {
  final title = document.querySelector('title')?.text.trim();
  return title == null || title.isEmpty ? null : title;
}

String _normalizeVisibleText(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();
