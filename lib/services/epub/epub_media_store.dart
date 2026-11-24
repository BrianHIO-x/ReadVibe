part of '../epub_parser.dart';

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
