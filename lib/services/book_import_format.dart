import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';

const unsupportedBookFormatMessage =
    '不支持的文件格式，请选择 TXT、EPUB、MOBI、AZW、AZW3、PDF、DOCX 或 DOC';

const androidPackageImportMessage = '这是 Android 安装包，不是书籍';

const _headerSampleBytes = 68;
const _textSampleBytes = 8192;

/// Turns a failed system file picker into a short Chinese message.
String describeFilePickerFailure(Object error) {
  if (error is PlatformException) {
    final code = error.code;
    final message = error.message?.trim() ?? '';
    if (code == 'already_active') {
      return '文件选择器已打开，请完成当前选择';
    }
    if (code == 'invalid_format_type' ||
        message.contains("Can't handle the provided file type")) {
      return '无法打开系统文件选择器';
    }
    if (code == 'unknown_path') {
      return '无法读取所选文件';
    }
    if (message.isNotEmpty) return message;
  }
  return '无法选择文件';
}

/// Writes picker bytes to a cache file when the plugin did not return a path.
Future<String?> materializePickedLocalFile({
  required String? path,
  required List<int>? bytes,
  required String fileName,
}) async {
  if (path != null && path.isNotEmpty) return path;
  if (bytes == null || bytes.isEmpty) return null;
  final directory = Directory('${Directory.systemTemp.path}/readvibe_picked');
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  final safeName = fileName
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '_')
      .trim();
  final file = File(
    '${directory.path}/${DateTime.now().microsecondsSinceEpoch}_${safeName.isEmpty ? 'file' : safeName}',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Resolves a supported book format from names first, then file contents.
///
/// Throws [FormatException] for an Android package or an unrecognized file.
BookFormat detectBookImportFormat({
  required String path,
  required String fileName,
  List<int>? bytes,
}) {
  final named = _formatFromNames(path, fileName);
  if (named != null) return _bookFormat(named);

  final header = _sample(path, bytes, _headerSampleBytes);
  if (header.isEmpty) {
    throw const FormatException(unsupportedBookFormatMessage);
  }
  if (_isPdfHeader(header)) return BookFormat.pdf;
  if (_isZipHeader(header)) {
    final zipFormat = _formatFromZip(path, bytes);
    if (zipFormat != null) return _bookFormat(zipFormat);
    throw const FormatException(unsupportedBookFormatMessage);
  }
  if (_isOleHeader(header)) return BookFormat.doc;
  if (_isMobiHeader(header)) return BookFormat.mobi;
  if (_looksLikePlainText(_sample(path, bytes, _textSampleBytes))) {
    return BookFormat.txt;
  }
  throw const FormatException(unsupportedBookFormatMessage);
}

/// Picks a display name whose suffix matches [format].
String labeledImportFileName(String path, String fileName, BookFormat format) {
  final raw = fileName.trim().isEmpty ? _baseName(path) : fileName.trim();
  final extension = _extensionFor(format);
  final current = fileExtension(raw);
  if (current == extension) return raw;
  if (current.isEmpty) return '$raw.$extension';
  final dot = raw.lastIndexOf('.');
  final stem = dot <= 0 ? raw : raw.substring(0, dot);
  return '$stem.$extension';
}

String fileExtension(String name) {
  final base = _baseName(name);
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

enum _DetectedImport { txt, epub, mobi, azw, azw3, docx, doc, pdf, apk }

BookFormat _bookFormat(_DetectedImport detected) {
  return switch (detected) {
    _DetectedImport.txt => BookFormat.txt,
    _DetectedImport.epub => BookFormat.epub,
    _DetectedImport.mobi => BookFormat.mobi,
    _DetectedImport.azw => BookFormat.azw,
    _DetectedImport.azw3 => BookFormat.azw3,
    _DetectedImport.docx => BookFormat.docx,
    _DetectedImport.doc => BookFormat.doc,
    _DetectedImport.pdf => BookFormat.pdf,
    _DetectedImport.apk =>
      throw const FormatException(androidPackageImportMessage),
  };
}

_DetectedImport? _formatFromNames(String path, String fileName) {
  final pathMatch = _namedFormat(fileExtension(path));
  if (pathMatch != null) return pathMatch;
  return _namedFormat(fileExtension(fileName));
}

_DetectedImport? _namedFormat(String extension) {
  switch (extension) {
    case 'txt':
      return _DetectedImport.txt;
    case 'epub':
      return _DetectedImport.epub;
    case 'pdf':
      return _DetectedImport.pdf;
    case 'docx':
      return _DetectedImport.docx;
    case 'doc':
      return _DetectedImport.doc;
    case 'azw3':
      return _DetectedImport.azw3;
    case 'azw':
      return _DetectedImport.azw;
    case 'mobi':
      return _DetectedImport.mobi;
    case 'apk':
      return _DetectedImport.apk;
    default:
      return null;
  }
}

String _extensionFor(BookFormat format) => switch (format) {
  BookFormat.txt => 'txt',
  BookFormat.epub => 'epub',
  BookFormat.mobi => 'mobi',
  BookFormat.azw => 'azw',
  BookFormat.azw3 => 'azw3',
  BookFormat.docx => 'docx',
  BookFormat.doc => 'doc',
  BookFormat.pdf => 'pdf',
};

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

List<int> _sample(String path, List<int>? bytes, int maxLength) {
  if (bytes != null) {
    if (bytes.length <= maxLength) return bytes;
    return bytes.sublist(0, maxLength);
  }
  final file = File(path);
  if (!file.existsSync()) return const <int>[];
  final raf = file.openSync();
  try {
    final length = raf.lengthSync();
    if (length <= 0) return const <int>[];
    final count = length < maxLength ? length : maxLength;
    final buffer = Uint8List(count);
    final read = raf.readIntoSync(buffer);
    return read == count ? buffer : buffer.sublist(0, read);
  } finally {
    raf.closeSync();
  }
}

bool _isPdfHeader(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x25 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x44 &&
    bytes[3] == 0x46;

bool _isZipHeader(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4b &&
    bytes[2] == 3 &&
    bytes[3] == 4;

bool _isOleHeader(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0xd0 &&
    bytes[1] == 0xcf &&
    bytes[2] == 0x11 &&
    bytes[3] == 0xe0;

bool _isMobiHeader(List<int> bytes) {
  if (bytes.length < 68) return false;
  return bytes[60] == 0x42 &&
      bytes[61] == 0x4f &&
      bytes[62] == 0x4f &&
      bytes[63] == 0x4b &&
      bytes[64] == 0x4d &&
      bytes[65] == 0x4f &&
      bytes[66] == 0x42 &&
      bytes[67] == 0x49;
}

_DetectedImport? _formatFromZip(String path, List<int>? bytes) {
  late final Archive archive;
  InputFileStream? stream;
  try {
    if (bytes != null) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else {
      stream = InputFileStream(path);
      archive = ZipDecoder().decodeStream(stream);
    }
  } on Object {
    return null;
  } finally {
    stream?.closeSync();
  }

  final names = <String>{
    for (final file in archive.files) _zipName(file.name),
  };
  final hasManifest = names.contains('androidmanifest.xml');
  final hasDex = names.any(
    (name) =>
        name == 'classes.dex' || RegExp(r'^classes\d+\.dex$').hasMatch(name),
  );
  if (hasManifest && hasDex) return _DetectedImport.apk;

  if (names.contains('meta-inf/container.xml') || _isEpubMime(archive)) {
    return _DetectedImport.epub;
  }
  final hasContentTypes = names.contains('[content_types].xml');
  final hasWord = names.any(
    (name) => name == 'word' || name.startsWith('word/'),
  );
  if (hasContentTypes && hasWord) {
    return _DetectedImport.docx;
  }
  return null;
}

bool _isEpubMime(Archive archive) {
  for (final file in archive.files) {
    if (_zipName(file.name) != 'mimetype' || file.isDirectory) continue;
    try {
      final content = utf8.decode(file.content).trim();
      return content == 'application/epub+zip';
    } on Object {
      return false;
    }
  }
  return false;
}

String _zipName(String name) {
  var value = name.replaceAll('\\', '/').toLowerCase();
  while (value.startsWith('./')) {
    value = value.substring(2);
  }
  if (value.startsWith('/')) value = value.substring(1);
  return value;
}

bool _looksLikePlainText(List<int> bytes) {
  if (bytes.isEmpty) return false;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    return true;
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    return true;
  }
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    return text.trim().isNotEmpty && !text.contains('\u0000');
  } on FormatException {
    return _looksLikeLegacyChinese(bytes);
  }
}

bool _looksLikeLegacyChinese(List<int> bytes) {
  var lead = 0;
  var pairs = 0;
  for (final value in bytes) {
    if (lead != 0) {
      if (value >= 0x40) pairs++;
      lead = 0;
      continue;
    }
    if (value >= 0x81 && value <= 0xfe) {
      lead = value;
      continue;
    }
    final isAsciiText =
        value == 9 || value == 10 || value == 13 || (value >= 32 && value < 127);
    if (isAsciiText) continue;
    if (value < 32) return false;
  }
  return pairs >= 8;
}
