import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../repositories/reader_repositories.dart';
import 'pdf_renderer_service.dart';

abstract interface class BookResourceStore
    implements ImportedFontStore, ImportedPdfStore {
  Future<void> deleteFont(String path);
  Future<void> deleteSource(Object? path);
}

/// Owns imported binary resources and their platform cache lifetime.
class ManagedBookResources implements BookResourceStore {
  ManagedBookResources(
    this._directories, {
    Future<void> Function(String path)? clearPdfCache,
  }) : _clearPdfCache = clearPdfCache ?? PdfRendererService.clearFileCache;

  final AppDataDirectoryProvider _directories;
  final Future<void> Function(String path) _clearPdfCache;

  Future<Directory> getAppDataDirectory() => _directories.getAppDataDirectory();

  @override
  Future<void> deleteFont(String fontPath) async {
    final root = await getAppDataDirectory();
    final fontsDirectory = Directory(p.join(root.path, 'fonts')).absolute.path;
    final font = File(fontPath).absolute;
    if (!p.isWithin(fontsDirectory, font.path)) return;
    try {
      if (await font.exists()) await font.delete();
    } on FileSystemException {
      // Font cleanup is best-effort and must not invalidate saved settings.
    }
  }

  @override
  Future<File> saveImportedFont(String sourcePath, String fileName) async {
    final extension = p.extension(fileName).toLowerCase();
    if (extension != '.ttf' && extension != '.otf') {
      throw const FormatException('仅支持 .ttf 或 .otf 字体文件');
    }
    final source = File(sourcePath);
    final stat = await source.stat();
    const maxFontBytes = 64 * 1024 * 1024;
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw const FormatException('所选字体文件为空或无法读取');
    }
    if (stat.size > maxFontBytes) {
      throw const FormatException('字体文件过大，请选择小于 64 MB 的字体');
    }

    final root = await getAppDataDirectory();
    final directory = Directory(p.join(root.path, 'fonts'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final safeName = p
        .basenameWithoutExtension(fileName)
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-\u4e00-\u9fa5]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    final baseName = safeName.isEmpty ? 'font' : safeName;
    final target = File(
      p.join(
        directory.path,
        '${DateTime.now().microsecondsSinceEpoch}_$baseName$extension',
      ),
    );

    return source.copy(target.path);
  }

  @override
  Future<File> saveImportedPdf(String sourcePath, String bookId) async {
    final source = File(sourcePath);
    final stat = await source.stat();
    const maxPdfBytes = 1024 * 1024 * 1024;
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw const FormatException('PDF 文件为空或无法读取');
    }
    if (stat.size > maxPdfBytes) {
      throw const FormatException('PDF 文件过大，请选择不超过 1 GB 的文件');
    }
    final root = await getAppDataDirectory();
    final directory = Directory(p.join(root.path, 'pdf'));
    if (!await directory.exists()) await directory.create(recursive: true);
    final safeId = base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');
    final target = File(p.join(directory.path, '$safeId.pdf'));
    final temporary = File('${target.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    await source.copy(temporary.path);
    if (await target.exists()) await target.delete();
    return temporary.rename(target.path);
  }

  @override
  Future<void> deleteSource(Object? rawSourcePath) async {
    if (rawSourcePath is! String || rawSourcePath.trim().isEmpty) return;
    try {
      final root = await getAppDataDirectory();
      final pdfDirectory = Directory(p.join(root.path, 'pdf')).absolute.path;
      final epubDirectory = Directory(p.join(root.path, 'epub')).absolute.path;
      final wordDirectory = Directory(p.join(root.path, 'word')).absolute.path;
      final sourcePath = rawSourcePath.trim();
      final sourceType = await FileSystemEntity.type(sourcePath);
      if (sourceType == FileSystemEntityType.file) {
        final source = File(sourcePath).absolute;
        if (!p.isWithin(pdfDirectory, source.path) || !await source.exists()) {
          return;
        }
        try {
          await _clearPdfCache(source.path);
        } on Object {
          // Cache cleanup is best-effort; the managed source remains deletable.
        }
        await source.delete();
      } else if (sourceType == FileSystemEntityType.directory) {
        final source = Directory(sourcePath).absolute;
        if ((p.isWithin(epubDirectory, source.path) ||
                p.isWithin(wordDirectory, source.path)) &&
            await source.exists()) {
          await source.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Metadata remains authoritative if private resource cleanup is interrupted.
    }
  }
}
