part of '../epub_parser.dart';

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

  /// Blocks recognized as directory rows with a trailing page number.
  final Set<int> navigationBlocks;

  const _ParsedDocument(this.blocks, this.linkHrefs, this.navigationBlocks);
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
  final navigationBlocks = <int>{};
  final pendingAnchorIds = <String>[];
  final root = document.body ?? document.documentElement;
  if (root == null) {
    return _ParsedDocument(blocks, linkHrefs, navigationBlocks);
  }

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

  void emitCollectedBlock(
    _CollectedRuns collected,
    EpubContentStyle blockStyle, {
    required bool isHeading,
  }) {
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

  void collectInlineNode(
    Node node,
    EpubContentStyle style,
    String? href, {
    required _EpubRunCollector Function() currentCollector,
    required void Function() flushText,
    bool preserveWhitespace = false,
    bool rubyHasRp = false,
  }) {
    if (node is Text) {
      currentCollector().add(
        node.data,
        style,
        href: href,
        preserveWhitespace: preserveWhitespace,
      );
      return;
    }
    if (node is! Element || resolver.isHidden(node)) return;
    final tag = node.localName;
    if (_nonContentElements.contains(tag)) return;
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
    if (tag == 'br') {
      currentCollector().addHardBreak(style, href: href);
      return;
    }
    if (tag == 'hr') {
      currentCollector().add(' ', style, href: href);
      return;
    }
    // An anchor nested inside another anchor is malformed markup; the
    // innermost href wins, matching how browsers resolve the same document.
    final childHref = tag == 'a'
        ? (resolveLinkHref(node.attributes['href'] ?? '') ?? href)
        : href;
    final childStyle = _normalizeInlineStyle(
      resolver.styleFor(node, inherited: style),
      inherited: style,
    );
    final childPreserve = preserveWhitespace || tag == 'pre';
    final childRubyHasRp = tag == 'ruby'
        ? node.querySelector('rp') != null
        : rubyHasRp;
    final wrapRt =
        (tag == 'rt' || tag == 'rtc') &&
        !rubyHasRp &&
        node.text.trim().isNotEmpty;
    if (wrapRt) {
      currentCollector().add('（', childStyle, href: childHref);
    }
    for (final child in node.nodes) {
      collectInlineNode(
        child,
        childStyle,
        childHref,
        currentCollector: currentCollector,
        flushText: flushText,
        preserveWhitespace: childPreserve,
        rubyHasRp: childRubyHasRp,
      );
    }
    if (wrapRt) {
      currentCollector().add('）', childStyle, href: childHref);
    }
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
    emitCollectedBlock(collected, blockStyle, isHeading: false);
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
      emitCollectedBlock(collected, blockStyle, isHeading: isHeading);
    }

    final preserve = element.localName == 'pre';
    for (final child in element.nodes) {
      collectInlineNode(
        child,
        blockStyle,
        null,
        currentCollector: () => collector,
        flushText: flushText,
        preserveWhitespace: preserve,
      );
    }
    flushText();
  }

  // Declared up front so the table helpers below can walk fallback content
  // that includes nested tables and other blocks.
  late void Function(Element element, EpubContentStyle inheritedStyle) walk;

  /// Collects one simple table row into a single readable text block.
  ///
  /// A row stays on this path only while its cells hold inline content. Rows
  /// with nested tables, images or block-level cells fall back to walking each
  /// cell, because those elements cannot live inside one paragraph.
  void appendTableRow(Element row, EpubContentStyle inheritedStyle) {
    if (resolver.isHidden(row)) return;
    noteAnchorId(row);
    final rowStyle = resolver.styleFor(row, inherited: inheritedStyle);
    final cells = <Element>[
      for (final child in row.children)
        if ((child.localName == 'td' || child.localName == 'th') &&
            !resolver.isHidden(child))
          child,
    ];
    if (cells.isEmpty) {
      for (final node in row.nodes) {
        if (node is Text) {
          appendDirectText(node.data, rowStyle);
        } else if (node is Element) {
          walk(node, rowStyle);
        }
      }
      return;
    }
    final hasDirectText = row.nodes.whereType<Text>().any(
      (node) => node.data.trim().isNotEmpty,
    );
    if (hasDirectText || cells.any(_cellNeedsBlockWalk)) {
      // The row is a container, never a leaf: walk its cells in document order
      // so nested tables keep their own rows and images keep their own blocks.
      for (final node in row.nodes) {
        if (node is Text) {
          appendDirectText(node.data, rowStyle);
        } else if (node is Element) {
          if (_nonContentElements.contains(node.localName)) continue;
          walk(node, rowStyle);
        }
      }
      return;
    }

    final cellStyles = <EpubContentStyle>[];
    final cellTexts = <String>[];
    final cellRuns = <List<_RawRun>>[];
    for (final cell in cells) {
      final cellStyle = resolver.styleFor(cell, inherited: rowStyle);
      cellStyles.add(cellStyle);
      noteAnchorId(cell);
      final collector = _EpubRunCollector();

      void visitInline(Node node, EpubContentStyle style, String? href) {
        if (node is Text) {
          collector.add(node.data, style, href: href);
          return;
        }
        if (node is! Element || resolver.isHidden(node)) return;
        final tag = node.localName;
        if (_nonContentElements.contains(tag)) return;
        noteAnchorId(node);
        if (tag == 'br') {
          collector.addHardBreak(style, href: href);
          return;
        }
        if (tag == 'hr') {
          collector.add(' ', style, href: href);
          return;
        }
        if (_mediaElements.contains(tag)) return;
        final childHref = tag == 'a'
            ? (resolveLinkHref(_htmlAttribute(node, 'href') ?? '') ?? href)
            : href;
        // The cell style is already the resolved cascade. Passing it straight
        // through keeps publisher font-size/weight on the cell's own runs.
        final childStyle = resolver.styleFor(node, inherited: style);
        for (final child in node.nodes) {
          visitInline(child, childStyle, childHref);
        }
      }

      for (final child in cell.nodes) {
        visitInline(child, cellStyle, null);
      }
      final collected = collector.finish();
      cellTexts.add(collected?.text ?? '');
      cellRuns.add(collected?.runs ?? const <_RawRun>[]);
    }

    final blockStyle = _tableRowBlockStyle(
      resolver: resolver,
      rowStyle: rowStyle,
      cells: cells,
      cellStyles: cellStyles,
    );
    final buffer = StringBuffer();
    final rawRuns = <_RawRun>[];
    var wroteCell = false;
    var lastCellStart = -1;
    for (var index = 0; index < cells.length; index++) {
      final cellText = cellTexts[index];
      if (cellText.isEmpty) continue;
      if (wroteCell) {
        buffer.write(' ');
        rawRuns.add(_RawRun(' ', blockStyle, null));
      }
      lastCellStart = buffer.length;
      buffer.write(cellText);
      rawRuns.addAll(cellRuns[index]);
      wroteCell = true;
    }
    final text = buffer.toString();
    if (text.isEmpty) return;

    int? trailingCellStart;
    double? trailingCellWidthEm;
    if (cells.length == 2 &&
        cellTexts[0].isNotEmpty &&
        cellTexts[1].isNotEmpty &&
        lastCellStart > 0 &&
        lastCellStart < text.length &&
        _isPageNumberText(cellTexts[1])) {
      final widthEm = _tableCellWidthEm(resolver, cells[1], cellStyles[1]);
      final endAligned = cellStyles[1].textAlign == 'end';
      if (endAligned || widthEm != null) {
        trailingCellStart = lastCellStart;
        trailingCellWidthEm = math
            .max(
              widthEm ?? 0,
              _estimatedTrailingCellWidthEm(cellTexts[1], cellStyles[1]),
            )
            .clamp(1.5, 16)
            .toDouble();
      }
    }

    final compact = _compactRuns(rawRuns, blockStyle);
    final hrefs = <int, String>{};
    for (var index = 0; index < compact.length; index++) {
      final href = compact[index].href;
      if (href != null) hrefs[index] = href;
    }
    if (hrefs.isNotEmpty) linkHrefs[blocks.length] = hrefs;
    blocks.add(
      EpubContentBlock(
        kind: EpubContentBlockKind.text,
        text: text,
        runs: List<EpubTextRun>.unmodifiable(<EpubTextRun>[
          for (final run in compact)
            EpubTextRun(text: run.text, style: run.style),
        ]),
        style: blockStyle,
        anchorIds: drainAnchorIds(),
        trailingCellStart: trailingCellStart,
        trailingCellWidthEm: trailingCellStart == null
            ? null
            : trailingCellWidthEm,
      ),
    );
    if (hrefs.isNotEmpty && trailingCellStart != null) {
      navigationBlocks.add(blocks.length - 1);
    }
  }

  /// Walks a table in document order, keeping captions, sections and rows.
  void walkTable(Element table, EpubContentStyle inheritedStyle) {
    final style = resolver.styleFor(table, inherited: inheritedStyle);
    for (final node in table.nodes) {
      if (node is Text) {
        appendDirectText(node.data, style);
        continue;
      }
      if (node is! Element) continue;
      final tag = node.localName;
      if (tag == 'caption') {
        walk(node, style);
        continue;
      }
      if (tag == 'thead' || tag == 'tbody' || tag == 'tfoot') {
        if (resolver.isHidden(node)) continue;
        noteAnchorId(node);
        final sectionStyle = resolver.styleFor(node, inherited: style);
        for (final rowNode in node.nodes) {
          if (rowNode is Text) {
            appendDirectText(rowNode.data, sectionStyle);
            continue;
          }
          if (rowNode is! Element) continue;
          if (rowNode.localName == 'tr') {
            appendTableRow(rowNode, sectionStyle);
          } else if (!_nonContentElements.contains(rowNode.localName)) {
            walk(rowNode, sectionStyle);
          }
        }
        continue;
      }
      if (tag == 'tr') {
        appendTableRow(node, style);
        continue;
      }
      if (tag == 'colgroup' || tag == 'col') continue;
      if (_nonContentElements.contains(tag)) continue;
      walk(node, style);
    }
  }

  walk = (Element element, EpubContentStyle inheritedStyle) {
    if (resolver.isHidden(element)) return;
    if (_nonContentElements.contains(element.localName)) return;
    noteAnchorId(element);
    final style = resolver.styleFor(element, inherited: inheritedStyle);
    if (element.localName == 'table') {
      walkTable(element, inheritedStyle);
      return;
    }
    if (element.localName == 'tr') {
      appendTableRow(element, inheritedStyle);
      return;
    }
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
    final containsBlockChild = _hasDescendantBlock(element);
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

    final inlineBlockStyle = _normalizeBlockStyle(
      style,
      tag: null,
      isHeading: false,
    );
    var inlineCollector = _EpubRunCollector();
    void flushInline() {
      final collected = inlineCollector.finish();
      inlineCollector = _EpubRunCollector();
      if (collected == null) return;
      emitCollectedBlock(collected, inlineBlockStyle, isHeading: false);
    }

    for (final node in element.nodes) {
      if (node is Text) {
        inlineCollector.add(node.data, inlineBlockStyle);
      } else if (node is Element) {
        if (resolver.isHidden(node) ||
            _nonContentElements.contains(node.localName)) {
          continue;
        }
        final tag = node.localName;
        final isInlineLeaf =
            !_blockElements.contains(tag) &&
            !_transparentContainers.contains(tag) &&
            tag != 'img' &&
            tag != 'image' &&
            tag != 'object' &&
            tag != 'embed' &&
            !_hasDescendantBlock(node);
        if (isInlineLeaf) {
          collectInlineNode(
            node,
            inlineBlockStyle,
            null,
            currentCollector: () => inlineCollector,
            flushText: flushInline,
          );
        } else {
          flushInline();
          walk(node, style);
        }
      }
    }
    flushInline();
  };

  walk(root, const EpubContentStyle(textIndentEm: 0));
  return _ParsedDocument(blocks, linkHrefs, navigationBlocks);
}

/// Elements that force a table row onto the per-cell fallback path.
///
/// A simple row is one text block, so it can only hold inline content. Any
/// block-level or replaced element inside a cell would be lost by that path;
/// walking the cell instead preserves the nested table, image or paragraph.
const _tableRowComplexElements = <String>{
  'address',
  'article',
  'aside',
  'audio',
  'blockquote',
  'canvas',
  'dd',
  'div',
  'dl',
  'dt',
  'embed',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'iframe',
  'image',
  'img',
  'li',
  'main',
  'nav',
  'object',
  'ol',
  'p',
  'pre',
  'section',
  'svg',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
  'video',
};

const _nonContentElements = <String>{
  'head',
  'script',
  'style',
  'title',
  'desc',
  'noscript',
  'template',
};

bool _hasDescendantBlock(Element element) {
  for (final child in element.children) {
    final tag = child.localName;
    if (_nonContentElements.contains(tag)) continue;
    if (_blockElements.contains(tag)) return true;
    if (_hasDescendantBlock(child)) return true;
  }
  return false;
}

const _mediaElements = <String>{
  'audio',
  'canvas',
  'embed',
  'iframe',
  'image',
  'img',
  'object',
  'svg',
  'video',
};

bool _cellNeedsBlockWalk(Element cell) {
  bool scan(Element element) {
    for (final child in element.children) {
      if (_tableRowComplexElements.contains(child.localName)) return true;
      if (scan(child)) return true;
    }
    return false;
  }

  return scan(cell);
}

/// The block style of a simple row, resolved from the row and its cells.
///
/// Chapter rows carry a bold face and top padding, section rows indent their
/// first cell. Both are presentation only: a directory row stays an ordinary
/// text block and is never promoted to a semantic heading.
EpubContentStyle _tableRowBlockStyle({
  required _EpubStyleResolver resolver,
  required EpubContentStyle rowStyle,
  required List<Element> cells,
  required List<EpubContentStyle> cellStyles,
}) {
  var fontWeight = 400;
  var fontScale = 1.0;
  var marginTopEm = rowStyle.marginTopEm;
  for (var index = 0; index < cells.length; index++) {
    final style = cellStyles[index];
    fontWeight = math.max(fontWeight, style.fontWeight);
    fontScale = math.max(fontScale, style.fontScale);
    marginTopEm = math.max(
      marginTopEm,
      _resolvedPaddingEm(resolver, cells[index], 'top'),
    );
  }
  final firstCell = cells.first;
  final declaredIndent = resolver.propertyFor(firstCell, 'text-indent');
  final indent = math.max(
    _resolvedPaddingEm(resolver, firstCell, 'left'),
    declaredIndent == null ? 0.0 : _emLength(declaredIndent, fallback: 0),
  );
  return EpubContentStyle(
    fontFamily: rowStyle.fontFamily,
    fontScale: fontScale.clamp(0.6, 2.5).toDouble(),
    fontWeight: fontWeight.clamp(100, 900),
    textAlign: 'start',
    textIndentEm: indent.clamp(0, 8).toDouble(),
    marginTopEm: marginTopEm.clamp(0, 2).toDouble(),
    colorArgb: rowStyle.colorArgb,
    backgroundColorArgb: rowStyle.backgroundColorArgb,
    backgroundImagePath: rowStyle.backgroundImagePath,
  );
}

double _resolvedPaddingEm(
  _EpubStyleResolver resolver,
  Element element,
  String side,
) {
  final direct = resolver.propertyFor(element, 'padding-$side');
  final shorthand = resolver.propertyFor(element, 'padding');
  final raw =
      direct ??
      (shorthand == null ? null : _paddingShorthandValue(shorthand, side));
  if (raw == null) return 0;
  final value = _emLength(raw, fallback: 0);
  return value.isFinite && value > 0 ? value : 0;
}

String? _paddingShorthandValue(String shorthand, String side) {
  final parts = shorthand.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) return null;
  if (parts.length == 1) return parts[0];
  if (parts.length == 2) {
    return side == 'top' || side == 'bottom' ? parts[0] : parts[1];
  }
  if (parts.length == 3) {
    if (side == 'top') return parts[0];
    if (side == 'bottom') return parts[2];
    return parts[1];
  }
  return switch (side) {
    'top' => parts[0],
    'right' => parts[1],
    'bottom' => parts[2],
    _ => parts[3],
  };
}

/// A publisher width for a page-number cell, as em of the reader's base font.
///
/// Percentages are not a column width this reader can honor without the
/// table's own width, so they are ignored and the row stays a plain line.
double? _tableCellWidthEm(
  _EpubStyleResolver resolver,
  Element cell,
  EpubContentStyle style,
) {
  final raw =
      resolver.propertyFor(cell, 'width') ??
      resolver.propertyFor(cell, 'min-width');
  if (raw == null) return null;
  final normalized = raw.trim().toLowerCase();
  if (normalized.isEmpty ||
      normalized == 'auto' ||
      normalized == 'normal' ||
      normalized.endsWith('%')) {
    return null;
  }
  final value = _emLength(normalized, fallback: 0);
  if (!value.isFinite || value < 1 || value > 16) return null;
  return (value * style.fontScale.clamp(0.6, 2.0)).toDouble();
}

double _estimatedTrailingCellWidthEm(String text, EpubContentStyle style) {
  final count = text.trim().length.clamp(1, 7);
  final scale = style.fontScale.clamp(0.6, 2.0);
  return (count * 0.62 * scale + 0.4).clamp(2.0, 6.0).toDouble();
}

bool _isPageNumberText(String text) {
  final value = text.trim();
  if (value.isEmpty || value.length > 16) return false;
  return RegExp(
    r'^(?:[0-9０-９]+(?:\s*[-–—~〜]\s*[0-9０-９]+)?|[ivxlcdmIVXLCDM]{1,7})$',
  ).hasMatch(value);
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
  'caption',
  'center',
  'dd',
  'details',
  'div',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'summary',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
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
  final textLen = _normalizeVisibleText(element.text).length;
  if (textLen == 0 || textLen > 80) return false;
  final identityTokens = <String>{
    element.id.toLowerCase(),
    ...element.classes.map((value) => value.toLowerCase()),
  };
  final excluded = identityTokens.any(
    (value) => RegExp(
      r'(^|[-_])(sub[-_]?title|subtitle|figure|image|img|caption|table|running|page|foot)([-_]|$)',
    ).hasMatch(value),
  );
  if (!excluded) {
    final namedAsHeading = identityTokens.any(
      (value) => RegExp(
        r'^(?:chapter[-_]?title|chaptertitle|title|heading|head|chap[-_]?title|chapter[-_]?head)$',
      ).hasMatch(value),
    );
    if (namedAsHeading) return true;
  }
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
      trailingCellStart: block.trailingCellStart,
      trailingCellWidthEm: block.trailingCellWidthEm,
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
      tag == 'blockquote' ||
      tag == 'figcaption' ||
      tag == 'li' ||
      tag == 'pre' ||
      tag == 'dt' ||
      tag == 'dd';
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

  void add(
    String rawText,
    EpubContentStyle style, {
    String? href,
    bool preserveWhitespace = false,
  }) {
    if (rawText.isEmpty) return;
    if (preserveWhitespace) {
      var text = rawText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      if (!_hasText) text = text.replaceFirst(RegExp(r'^[ \t\n]+'), '');
      if (text.isEmpty) return;
      _runs.add(_RawRun(text, style, href));
      _hasText = true;
      _endsWithSpace =
          text.endsWith(' ') || text.endsWith('\t') || text.endsWith('\n');
      return;
    }
    var text = rawText.replaceAll(RegExp(r'\s+'), ' ');
    if (!_hasText) text = text.trimLeft();
    if (_endsWithSpace) text = text.trimLeft();
    if (text.isEmpty) return;
    _runs.add(_RawRun(text, style, href));
    _hasText = true;
    _endsWithSpace = text.endsWith(' ');
  }

  /// Records an explicit author line break.
  ///
  /// A `<br>` is content, not spacing between words: keeping it as a newline
  /// preserves the line while the runs, their links and every text offset still
  /// describe the same visible paragraph.
  void addHardBreak(EpubContentStyle style, {String? href}) {
    if (!_hasText || _runs.isEmpty) return;
    final last = _runs.last;
    final trimmed = last.text.replaceFirst(RegExp(r' +$'), '');
    if (trimmed != last.text) {
      if (trimmed.isEmpty) {
        _runs.removeLast();
      } else {
        _runs[_runs.length - 1] = last.withText(trimmed);
      }
    }
    _runs.add(_RawRun('\n', style, href));
    _endsWithSpace = true;
  }

  _CollectedRuns? finish() {
    if (_runs.isEmpty) return null;
    // Drop every trailing whitespace run, not only the last one. Two <br> at
    // the end of a cell leave two newline runs, while the visible text ends
    // before them; keeping one would make the runs and the text disagree.
    while (_runs.isNotEmpty) {
      final last = _runs.last;
      final trimmed = last.text.trimRight();
      if (trimmed.isEmpty) {
        _runs.removeLast();
        continue;
      }
      if (trimmed != last.text) {
        _runs[_runs.length - 1] = last.withText(trimmed);
      }
      break;
    }
    if (_runs.isEmpty) return null;
    final text = _runs.map((run) => run.text).join().trim();
    if (text.isEmpty) return null;
    return _CollectedRuns(text, List<_RawRun>.unmodifiable(_runs));
  }
}
