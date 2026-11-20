import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart3_big5/big5.dart';
import 'package:fast_gbk/fast_gbk.dart';

/// Decodes one EPUB package or markup entry.
///
/// EPUB 2 books are regularly encoded with GBK, GB18030 or Big5 even though
/// the surrounding ZIP and OPF are UTF-8. The declared charset is honoured
/// first; an undeclared document is accepted only when strict UTF-8 succeeds
/// or a Chinese legacy codec produces plausible text. Anything else keeps the
/// old tolerant UTF-8 fallback instead of inventing a different encoding.
const _charsetProbeBytes = 4096;
const _big5ChunkBytes = 8192;

String decodeEpubMarkup(List<int> bytes) {
  if (bytes.isEmpty) return '';
  if (_hasPrefix(bytes, const <int>[0xef, 0xbb, 0xbf])) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (_hasPrefix(bytes, const <int>[0xff, 0xfe])) {
    return _decodeUtf16(bytes.sublist(2), Endian.little);
  }
  if (_hasPrefix(bytes, const <int>[0xfe, 0xff])) {
    return _decodeUtf16(bytes.sublist(2), Endian.big);
  }
  // BOM-less UTF-16 markup is common in older tools. Its ASCII tags leave a
  // regular NUL pattern that is read as garbage by a latin1 charset probe, so
  // recognise it before looking for an XML declaration.
  final bomlessEndian = _bomlessUtf16Endian(bytes);
  if (bomlessEndian != null) return _decodeUtf16(bytes, bomlessEndian);

  final declared = _declaredCharset(bytes);
  if (declared != null) {
    final decoded = _decodeDeclared(bytes, declared);
    if (decoded != null) return decoded;
  }
  return _decodeUndeclared(bytes);
}

String? _decodeDeclared(List<int> bytes, String rawLabel) {
  switch (_normalizeCharset(rawLabel)) {
    case 'utf-8':
      // An explicitly UTF-8 document with one damaged byte should stay UTF-8;
      // guessing a Chinese legacy codec would turn the whole chapter into
      // mojibake. The tolerant decoder replaces only the broken sequence.
      return _tryUtf8(bytes) ?? utf8.decode(bytes, allowMalformed: true);
    case 'gbk':
      final strict = _tryGbk(bytes);
      if (strict != null) return strict;
      // A mislabeled UTF-8 file is common enough to prefer it over replacing
      // every non-ASCII character with U+FFFD.
      return _tryUtf8(bytes) ??
          const GbkCodec(allowMalformed: true).decode(bytes);
    case 'big5':
      return _decodeBig5(bytes);
    case 'utf-16le':
      return _decodeUtf16(bytes, Endian.little);
    case 'utf-16be':
      return _decodeUtf16(bytes, Endian.big);
    case 'utf-16':
      return _decodeUtf16Auto(bytes);
    case 'windows-1252':
      return _decodeWindows1252(bytes);
    default:
      return _tryUtf8(bytes) ?? _decodeUndeclared(bytes);
  }
}

String _decodeUndeclared(List<int> bytes) {
  final utf8Text = _tryUtf8(bytes);
  if (utf8Text != null) return utf8Text;

  // One stray byte in otherwise valid UTF-8 is corruption, not a legacy
  // encoding. Two or more replacements are left to the Chinese codecs.
  final tolerantUtf8 = utf8.decode(bytes, allowMalformed: true);
  if (_replacementCount(tolerantUtf8) <= 1) return tolerantUtf8;

  final gbkText = _tryGbk(bytes);
  if (gbkText != null && _hasCjk(gbkText)) return gbkText;

  final big5Text = _decodeBig5(bytes);
  if (_hasCjk(big5Text) && _replacementCount(big5Text) < 3) {
    return big5Text;
  }

  if (_hasWindows1252Punctuation(bytes)) {
    return _decodeWindows1252(bytes);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

String? _tryUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return null;
  }
}

String? _tryGbk(List<int> bytes) {
  try {
    return const GbkCodec(allowMalformed: false).decode(bytes);
  } on Object {
    return null;
  }
}

String _decodeBig5(List<int> bytes) {
  if (bytes.length <= _big5ChunkBytes) return Big5.decode(bytes);
  final output = StringBuffer();
  var start = 0;
  while (start < bytes.length) {
    final desiredEnd = math.min(start + _big5ChunkBytes, bytes.length);
    final end = _big5SafeEnd(bytes, start, desiredEnd);
    output.write(Big5.decode(bytes.sublist(start, end)));
    start = end;
  }
  return output.toString();
}

/// Stops a Big5 chunk before a double-byte pair that would cross the boundary.
int _big5SafeEnd(List<int> bytes, int start, int desiredEnd) {
  if (desiredEnd >= bytes.length) return bytes.length;
  var index = start;
  while (index < desiredEnd) {
    final lead = bytes[index];
    if (lead < 0x80) {
      index++;
      continue;
    }
    if (lead >= 0x81 && lead < 0xff) {
      if (index + 1 >= desiredEnd) return index;
      index += 2;
      continue;
    }
    index++;
  }
  return desiredEnd;
}

Endian? _bomlessUtf16Endian(List<int> bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] == 0x3c && bytes[1] == 0x00) return Endian.little;
  if (bytes[0] == 0x00 && bytes[1] == 0x3c) return Endian.big;
  final sample = math.min(bytes.length, 512);
  var pairs = 0;
  var evenZeros = 0;
  var oddZeros = 0;
  for (var index = 0; index + 1 < sample; index += 2) {
    pairs++;
    if (bytes[index] == 0) evenZeros++;
    if (bytes[index + 1] == 0) oddZeros++;
  }
  if (pairs < 4) return null;
  if (evenZeros > pairs * 0.4 && oddZeros < pairs * 0.1) {
    return Endian.big;
  }
  if (oddZeros > pairs * 0.4 && evenZeros < pairs * 0.1) {
    return Endian.little;
  }
  return null;
}

String _decodeUtf16Auto(List<int> bytes) {
  if (bytes.length < 2) return _decodeUtf16(bytes, Endian.little);
  var evenZero = 0;
  var oddZero = 0;
  final sample = math.min(bytes.length, 512);
  for (var index = 0; index + 1 < sample; index += 2) {
    if (bytes[index] == 0) evenZero++;
    if (bytes[index + 1] == 0) oddZero++;
  }
  return _decodeUtf16(bytes, evenZero > oddZero ? Endian.big : Endian.little);
}

String _decodeUtf16(List<int> bytes, Endian endian) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final codeUnits = <int>[];
  for (var offset = 0; offset + 1 < data.lengthInBytes; offset += 2) {
    codeUnits.add(data.getUint16(offset, endian));
  }
  return String.fromCharCodes(codeUnits);
}

const _windows1252Map = <int, int>{
  0x80: 0x20ac,
  0x82: 0x201a,
  0x83: 0x0192,
  0x84: 0x201e,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02c6,
  0x89: 0x2030,
  0x8a: 0x0160,
  0x8b: 0x2039,
  0x8c: 0x0152,
  0x8e: 0x017d,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201c,
  0x94: 0x201d,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02dc,
  0x99: 0x2122,
  0x9a: 0x0161,
  0x9b: 0x203a,
  0x9c: 0x0153,
  0x9e: 0x017e,
  0x9f: 0x0178,
};

String _decodeWindows1252(List<int> bytes) {
  final codeUnits = <int>[];
  for (final byte in bytes) {
    codeUnits.add(_windows1252Map[byte] ?? byte);
  }
  return String.fromCharCodes(codeUnits);
}

bool _hasWindows1252Punctuation(List<int> bytes) {
  for (final byte in bytes) {
    if (byte >= 0x80 && byte <= 0x9f) return true;
  }
  return false;
}

bool _hasCjk(String text) {
  var count = 0;
  for (final rune in text.runes) {
    final cjk =
        (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x4e00 && rune <= 0x9fff) ||
        (rune >= 0xf900 && rune <= 0xfaff);
    if (cjk) {
      count++;
      if (count >= 4) return true;
    }
  }
  return false;
}

int _replacementCount(String text) {
  var count = 0;
  for (final rune in text.runes) {
    if (rune == 0xfffd) count++;
  }
  return count;
}

String? _declaredCharset(List<int> bytes) {
  final length = math.min(bytes.length, _charsetProbeBytes);
  final probe = latin1.decode(bytes.sublist(0, length), allowInvalid: true);
  final xml = RegExp(
    r'''<\?xml[^>]*encoding\s*=\s*["']\s*([^"']+?)\s*["']''',
    caseSensitive: false,
  ).firstMatch(probe)?.group(1);
  if (xml != null && xml.trim().isNotEmpty) return xml;

  final meta = RegExp(
    r'''<meta[^>]+charset\s*=\s*["']?\s*([^"'\s/>;]+)''',
    caseSensitive: false,
  ).firstMatch(probe)?.group(1);
  if (meta != null && meta.trim().isNotEmpty) return meta;

  return RegExp(
    r'''<meta[^>]+content\s*=\s*["'][^"']*charset\s*=\s*([^"'\s;]+)''',
    caseSensitive: false,
  ).firstMatch(probe)?.group(1);
}

String _normalizeCharset(String raw) {
  var value = raw.trim().toLowerCase();
  value = value.replaceAll('_', '-').replaceAll('"', '').replaceAll("'", '');
  if (value == 'utf8' || value == 'unicode-1-1-utf-8') return 'utf-8';
  if (value == 'gb2312' ||
      value == 'gbk' ||
      value == 'gb18030' ||
      value == 'cp936' ||
      value == 'ms936' ||
      value == 'windows-936' ||
      value == 'x-gbk') {
    return 'gbk';
  }
  if (value == 'big5' ||
      value == 'big-5' ||
      value == 'cp950' ||
      value == 'windows-950' ||
      value == 'x-x-big5') {
    return 'big5';
  }
  if (value == 'utf-16le' || value == 'utf16le') return 'utf-16le';
  if (value == 'utf-16be' || value == 'utf16be') return 'utf-16be';
  if (value == 'utf-16' || value == 'utf16' || value == 'unicode') {
    return 'utf-16';
  }
  if (value == 'iso-8859-1' ||
      value == 'iso8859-1' ||
      value == 'latin1' ||
      value == 'latin-1' ||
      value == 'windows-1252' ||
      value == 'cp1252') {
    return 'windows-1252';
  }
  return value;
}

bool _hasPrefix(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}
