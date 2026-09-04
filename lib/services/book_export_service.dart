import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';

abstract interface class BookExporter {
  Future<bool> exportBook(Book book);
}

abstract interface class BookExportDestination {
  Future<bool> save({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  });
}

class AndroidBookExportDestination implements BookExportDestination {
  static const channel = MethodChannel('com.readvibe.app/book_export');
  const AndroidBookExportDestination();
  @override
  Future<bool> save({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async =>
      await channel.invokeMethod<bool>('save', {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
      }) ??
      false;
}

class PreparedBookExport {
  const PreparedBookExport(
    this.directory,
    this.file,
    this.fileName,
    this.mimeType,
  );
  final Directory directory;
  final File file;
  final String fileName;
  final String mimeType;

  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class BookExportService implements BookExporter {
  BookExportService({
    this.destination = const AndroidBookExportDestination(),
    Future<Directory> Function()? temporaryDirectory,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;
  final BookExportDestination destination;
  final Future<Directory> Function() _temporaryDirectory;

  @override
  Future<bool> exportBook(Book book) async {
    final prepared = await prepareBookExport(book, await _temporaryDirectory());
    try {
      return await destination.save(
        sourcePath: prepared.file.path,
        fileName: prepared.fileName,
        mimeType: prepared.mimeType,
      );
    } finally {
      await prepared.dispose();
    }
  }
}

String _fileName(String title, String extension) {
  final cleaned = title
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  final stem = cleaned.isEmpty
      ? '未命名书籍'
      : String.fromCharCodes(cleaned.runes.take(60));
  return '$stem.$extension';
}

/// Writes a private temporary file before asking the user for a destination.
/// Text uses UTF-8 and visits chapters in order, including saved local edits.
Future<PreparedBookExport> prepareBookExport(Book book, Directory cache) async {
  final root = Directory(p.join(cache.path, 'readvibe_exports'));
  await root.create(recursive: true);
  final directory = await root.createTemp('book_');
  final pdf = book.isPdf;
  final file = File(p.join(directory.path, pdf ? 'book.pdf' : 'book.txt'));
  try {
    if (pdf) {
      final path = book.sourcePath;
      if (path == null ||
          !await File(path).exists() ||
          await File(path).length() == 0) {
        throw const FormatException('PDF 源文件丢失或为空，无法导出');
      }
      await File(path).copy(file.path);
    } else {
      if (book.chapters.isEmpty) throw const FormatException('书籍正文缺失，无法导出');
      final path = file.path;
      await Isolate.run(() => _writeText(book, path));
    }
    return PreparedBookExport(
      directory,
      file,
      _fileName(book.title, pdf ? 'pdf' : 'txt'),
      pdf ? 'application/pdf' : 'text/plain',
    );
  } on Object {
    if (await directory.exists()) await directory.delete(recursive: true);
    rethrow;
  }
}

Future<void> _writeText(Book book, String path) async {
  final output = await File(path).open(mode: FileMode.write);
  Future<void> write(String text) async {
    for (var start = 0; start < text.length;) {
      var end = start + 32768;
      if (end > text.length) end = text.length;
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xd800 &&
          text.codeUnitAt(end - 1) <= 0xdbff)
        end--;
      await output.writeString(text.substring(start, end), encoding: utf8);
      start = end;
    }
  }

  try {
    await write('${book.title}\n');
    if (book.author.trim().isNotEmpty) await write('作者：${book.author}\n');
    await write('\n');
    String? lastVolume;
    for (final chapter in book.chapters) {
      final volume = chapter.volumeTitle?.trim();
      if (volume != null && volume.isNotEmpty && volume != lastVolume) {
        await write('$volume\n\n');
      }
      lastVolume = volume;
      if (chapter.hasRichEpubContent) {
        final blocks = chapter.epubBlocks;
        final hasTitle = blocks.any(
          (b) => b.isHeading && b.text.trim() == chapter.title.trim(),
        );
        if (!hasTitle) await write('${chapter.title}\n\n');
        for (final block in blocks) {
          if (block.isText) {
            final text = block.text.isNotEmpty
                ? block.text
                : block.runs.map((r) => r.text).join();
            if (text.isNotEmpty) await write('$text\n\n');
          } else if (block.altText?.trim().isNotEmpty == true) {
            await write('[图片：${block.altText}]\n\n');
          }
        }
      } else {
        await write('${chapter.title}\n\n');
        await write(chapter.content);
        await write('\n\n');
      }
    }
    await output.flush();
  } finally {
    await output.close();
  }
}
