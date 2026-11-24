part of '../epub_parser.dart';

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
