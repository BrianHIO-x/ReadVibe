part of '../epub_parser.dart';

/// Exact ZIP lookup with deterministic, ambiguity-free fallbacks.
///
/// A path is first matched byte-for-byte. Only when that misses do we try the
/// same path after URI decoding and then a single case-folded candidate. Two
/// entries that differ only by case are never guessed; an exact match still
/// wins over them.
class _ArchiveLookup {
  _ArchiveLookup(Map<String, ArchiveFile> files)
    : files = Map.unmodifiable(files) {
    void addUnique(Map<String, List<String>> map, String key, String value) {
      final bucket = map.putIfAbsent(key, () => <String>[]);
      if (!bucket.contains(value)) bucket.add(value);
    }

    for (final entry in files.entries) {
      addUnique(_folded, entry.key.toLowerCase(), entry.key);
      final decoded = _normalizeArchivePath(_safeDecodeUriComponent(entry.key));
      final decodedKey = decoded.toLowerCase();
      if (decodedKey != entry.key.toLowerCase()) {
        addUnique(_decoded, decodedKey, entry.key);
      }
      if (entry.key.codeUnits.any((u) => u >= 0x80 && u <= 0xff) &&
          entry.key.codeUnits.every((u) => u <= 0xff)) {
        final rawBytes = entry.key.codeUnits;
        for (final alt in _decodeArchiveEntryNameBytes(rawBytes)) {
          final normalizedAlt = _normalizeArchivePath(alt);
          if (normalizedAlt.isEmpty) continue;
          addUnique(_decoded, normalizedAlt.toLowerCase(), entry.key);
        }
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
  const _LoadedDocument(
    this.blocks,
    this.linkHrefs,
    this.documentTitle, {
    this.navigationBlocks = const <int>{},
  });

  final List<EpubContentBlock> blocks;
  final Map<int, Map<int, String>> linkHrefs;
  final String? documentTitle;

  /// Blocks this document recognized as directory rows. Links collected from
  /// one of these rows jump straight to their destination instead of opening
  /// the footnote preview.
  final Set<int> navigationBlocks;
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

class _EpubEncryptionInfo {
  const _EpubEncryptionInfo({
    this.drmEncryptedPaths = const <String>{},
    this.idpfObfuscatedFonts = const <String>{},
    this.adobeObfuscatedFonts = const <String>{},
  });

  final Set<String> drmEncryptedPaths;
  final Set<String> idpfObfuscatedFonts;
  final Set<String> adobeObfuscatedFonts;
}

_EpubEncryptionInfo _epubEncryptionInfo(_ArchiveLookup archiveLookup) {
  final encryption = archiveLookup.find('META-INF/encryption.xml');
  if (encryption == null) return const _EpubEncryptionInfo();
  try {
    // Encryption metadata is security-relevant: keep exact XML parsing here
    // and refuse the book when the list cannot be trusted.
    final document = _parseXml(encryption, 'encryption.xml');
    final drmPaths = <String>{};
    final idpfFonts = <String>{};
    final adobeFonts = <String>{};

    void recordPath(Set<String> target, String? rawUri) {
      if (rawUri == null || rawUri.trim().isEmpty) return;
      final path = _normalizeArchivePath(
        _safeDecodeUriComponent(rawUri.split('#').first.split('?').first),
      );
      if (path.isNotEmpty && path != '..' && !path.startsWith('../')) {
        target.add(path);
        final canonical = archiveLookup.canonicalPath(path);
        if (canonical != null) target.add(canonical);
      }
    }

    final coveredReferences = <XmlElement>{};
    for (final encryptedData in _elementsNamed(document, 'EncryptedData')) {
      final method = _elementsNamed(
        encryptedData,
        'EncryptionMethod',
      ).firstOrNull;
      final algorithm =
          method?.getAttribute('Algorithm')?.trim().toLowerCase() ?? '';
      final bucket = switch (algorithm) {
        'http://www.idpf.org/2008/embedding' => idpfFonts,
        'http://ns.adobe.com/pdf/enc#rc' => adobeFonts,
        _ => drmPaths,
      };
      for (final reference in _elementsNamed(
        encryptedData,
        'CipherReference',
      )) {
        coveredReferences.add(reference);
        recordPath(bucket, reference.getAttribute('URI'));
      }
    }
    for (final reference in _elementsNamed(document, 'CipherReference')) {
      if (!coveredReferences.contains(reference)) {
        recordPath(drmPaths, reference.getAttribute('URI'));
      }
    }
    return _EpubEncryptionInfo(
      drmEncryptedPaths: drmPaths,
      idpfObfuscatedFonts: idpfFonts,
      adobeObfuscatedFonts: adobeFonts,
    );
  } on FormatException {
    throw const FormatException('EPUB encryption.xml 已损坏，无法确认内容安全性');
  }
}

List<String> _decodeArchiveEntryNameBytes(List<int> rawBytes) {
  final results = <String>[];
  try {
    results.add(utf8.decode(rawBytes, allowMalformed: false));
  } on FormatException {
    // Try legacy encodings below when ZIP bit 11 UTF-8 flag is absent.
  }
  try {
    results.add(const GbkCodec(allowMalformed: false).decode(rawBytes));
  } on Object {
    // Ignore non-GBK bytes.
  }
  try {
    results.add(Big5.decode(rawBytes));
  } on Object {
    // Ignore non-Big5 bytes.
  }
  return results;
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
    var joined = '';
    final decodedLiteral = _safeDecodeUriComponent(href.trim());
    if (decodedLiteral.isNotEmpty) {
      final candidateRaw = p.posix.isAbsolute(decodedLiteral)
          ? decodedLiteral
          : p.posix.join(opfDir, decodedLiteral);
      final normalizedCandidate = _normalizeArchivePath(candidateRaw);
      if (normalizedCandidate.isNotEmpty &&
          normalizedCandidate != '..' &&
          !normalizedCandidate.startsWith('../') &&
          archiveLookup.resolve(normalizedCandidate) != null) {
        joined = normalizedCandidate;
      }
    }
    if (joined.isEmpty) {
      joined = _resolveArchiveReference(
        href,
        opfDir,
        baseIsDirectory: true,
      );
    }
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
  String opfDir,
  Map<String, _ManifestItem> manifest,
  _ArchiveLookup archiveLookup,
) {
  bool looksLikeImage(_ManifestItem item) {
    if (item.mediaType.startsWith('image/')) return true;
    final ext = p.posix.extension(item.path).toLowerCase();
    return ext == '.png' ||
        ext == '.jpg' ||
        ext == '.jpeg' ||
        ext == '.gif' ||
        ext == '.bmp' ||
        ext == '.webp';
  }

  for (final item in manifest.values) {
    if (item.properties.contains('cover-image') && looksLikeImage(item)) {
      return item.path;
    }
  }
  for (final meta in _elementsNamed(opf, 'meta')) {
    if (meta.getAttribute('name')?.trim().toLowerCase() != 'cover') continue;
    final idOrHref = meta.getAttribute('content')?.trim();
    if (idOrHref == null || idOrHref.isEmpty) continue;
    final item = manifest[idOrHref];
    if (item != null) {
      if (looksLikeImage(item)) return item.path;
      final wrapped = _extractCoverImageFromXhtml(item.path, archiveLookup);
      if (wrapped != null) return wrapped;
    }
    final resolved = _resolveArchiveReference(
      idOrHref,
      opfDir,
      baseIsDirectory: true,
    );
    if (resolved.isNotEmpty) {
      final canonical = archiveLookup.canonicalPath(resolved) ?? resolved;
      if (archiveLookup.find(canonical) != null) {
        final ext = p.posix.extension(canonical).toLowerCase();
        if (ext == '.png' ||
            ext == '.jpg' ||
            ext == '.jpeg' ||
            ext == '.gif' ||
            ext == '.bmp' ||
            ext == '.webp') {
          return canonical;
        }
      }
    }
  }
  for (final reference in _elementsNamed(opf, 'reference')) {
    final type = reference.getAttribute('type')?.trim().toLowerCase() ?? '';
    if (type != 'cover') continue;
    final href = reference.getAttribute('href');
    if (href == null || href.trim().isEmpty) continue;
    final resolved = _resolveArchiveReference(
      href,
      opfDir,
      baseIsDirectory: true,
    );
    if (resolved.isEmpty) continue;
    final canonical = archiveLookup.canonicalPath(resolved) ?? resolved;
    final ext = p.posix.extension(canonical).toLowerCase();
    if (ext == '.png' ||
        ext == '.jpg' ||
        ext == '.jpeg' ||
        ext == '.gif' ||
        ext == '.bmp' ||
        ext == '.webp') {
      return canonical;
    }
    final wrapped = _extractCoverImageFromXhtml(canonical, archiveLookup);
    if (wrapped != null) return wrapped;
  }
  for (final entry in manifest.entries) {
    if ((entry.key.toLowerCase().contains('cover') ||
            entry.value.path.toLowerCase().contains('cover')) &&
        looksLikeImage(entry.value)) {
      return entry.value.path;
    }
  }
  return null;
}

String? _extractCoverImageFromXhtml(String path, _ArchiveLookup archiveLookup) {
  final file = archiveLookup.find(path);
  if (file == null || file.size <= 0 || file.size > 4 * 1024 * 1024) {
    return null;
  }
  try {
    final doc = html_parser.parse(
      normalizeXhtmlSelfClosingTags(decodeEpubMarkup(_bytesOf(file))),
    );
    for (final element in doc.querySelectorAll('img, image')) {
      final src =
          _htmlAttribute(element, 'src') ??
          _htmlAttribute(element, 'xlink:href') ??
          _htmlAttribute(element, 'href');
      if (src == null || src.trim().isEmpty) continue;
      final resolved = _resolveArchiveReference(src, path);
      if (resolved.isEmpty) continue;
      final canonical = archiveLookup.canonicalPath(resolved) ?? resolved;
      if (archiveLookup.find(canonical) != null) return canonical;
    }
  } on Object {
    return null;
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
    final document = html_parser.parse(normalizeXhtmlSelfClosingTags(text));
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

const _htmlVoidElements = <String>{
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'image',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

/// Expands XHTML self-closing non-void elements (`<title/>`, `<script .../>`,
/// `<a id="x"/>`) into explicit `<tag ...></tag>` pairs before handing XHTML to
/// `package:html` (an HTML5 parser that otherwise swallows subsequent markup
/// inside RCDATA/RAWTEXT/script states).
String normalizeXhtmlSelfClosingTags(String markup) {
  if (!markup.contains('/>')) return markup;
  final out = StringBuffer();
  var i = 0;
  final len = markup.length;
  String? rawEndTag;

  while (i < len) {
    if (rawEndTag != null) {
      final closeIndex = markup.toLowerCase().indexOf(rawEndTag, i);
      if (closeIndex < 0) {
        out.write(markup.substring(i));
        break;
      }
      out.write(markup.substring(i, closeIndex + rawEndTag.length));
      i = closeIndex + rawEndTag.length;
      rawEndTag = null;
      continue;
    }

    final lt = markup.indexOf('<', i);
    if (lt < 0) {
      out.write(markup.substring(i));
      break;
    }
    if (lt > i) out.write(markup.substring(i, lt));

    if (markup.startsWith('<!--', lt)) {
      final end = markup.indexOf('-->', lt + 4);
      if (end < 0) {
        out.write(markup.substring(lt));
        break;
      }
      out.write(markup.substring(lt, end + 3));
      i = end + 3;
      continue;
    }
    if (markup.startsWith('<![CDATA[', lt)) {
      final end = markup.indexOf(']]>', lt + 9);
      if (end < 0) {
        out.write(markup.substring(lt));
        break;
      }
      out.write(markup.substring(lt, end + 3));
      i = end + 3;
      continue;
    }
    if (lt + 1 < len && (markup[lt + 1] == '?' || markup[lt + 1] == '!')) {
      final end = markup.indexOf('>', lt + 2);
      if (end < 0) {
        out.write(markup.substring(lt));
        break;
      }
      out.write(markup.substring(lt, end + 1));
      i = end + 1;
      continue;
    }

    if (lt + 1 >= len) {
      out.write('<');
      break;
    }
    final first = markup.codeUnitAt(lt + 1);
    final isTagChar =
        (first >= 0x41 && first <= 0x5a) || (first >= 0x61 && first <= 0x7a);
    if (!isTagChar) {
      out.write('<');
      i = lt + 1;
      continue;
    }

    // Parse tag name.
    var nameEnd = lt + 1;
    while (nameEnd < len) {
      final cu = markup.codeUnitAt(nameEnd);
      if (cu <= 0x20 || cu == 0x2f || cu == 0x3e) break; // space, '/', '>'
      nameEnd++;
    }
    final rawName = markup.substring(lt + 1, nameEnd);
    final colon = rawName.indexOf(':');
    final localName = (colon >= 0 ? rawName.substring(colon + 1) : rawName)
        .toLowerCase();

    // Scan until matching unquoted '>'.
    var j = nameEnd;
    var quote = 0;
    while (j < len) {
      final cu = markup.codeUnitAt(j);
      if (quote != 0) {
        if (cu == quote) quote = 0;
      } else if (cu == 0x22 || cu == 0x27) {
        quote = cu;
      } else if (cu == 0x3e) {
        break;
      }
      j++;
    }
    if (j >= len) {
      out.write(markup.substring(lt));
      break;
    }

    var slashPos = j - 1;
    while (slashPos >= nameEnd && markup.codeUnitAt(slashPos) <= 0x20) {
      slashPos--;
    }
    final isSelfClosing = slashPos >= nameEnd && markup[slashPos] == '/';
    if (isSelfClosing && !_htmlVoidElements.contains(localName)) {
      out.write(markup.substring(lt, slashPos));
      out.write('></');
      out.write(rawName);
      out.write('>');
    } else {
      out.write(markup.substring(lt, j + 1));
      if (!isSelfClosing &&
          (localName == 'script' || localName == 'style')) {
        rawEndTag = '</$localName';
      }
    }
    i = j + 1;
  }
  return out.toString();
}
