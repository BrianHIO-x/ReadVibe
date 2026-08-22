import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';

import '../models/book.dart';
import 'pdf_renderer_service.dart';
import 'storage_service.dart';

Future<Book> importPdf(
  String sourcePath,
  String fileName,
  StorageService storage, {
  String? password,
}) async {
  final source = File(sourcePath);
  final stat = await source.stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
    throw const FormatException('PDF 文件为空或无法读取');
  }
  final now = DateTime.now();
  final id = 'pdf_${now.microsecondsSinceEpoch}';
  final managedFile = await storage.saveImportedPdf(sourcePath, id);
  try {
    late final int pageCount;
    if (password != null) {
      pageCount = await PdfRendererService.unlockPdf(
        filePath: managedFile.path,
        password: password,
      );
    } else {
      try {
        pageCount = await PdfRendererService.getPageCount(managedFile.path);
      } on PdfPasswordRequiredException {
        // Permission-only encryption often has an empty user password. Remove
        // that protection locally without bothering the user for a password.
        pageCount = await PdfRendererService.unlockPdf(
          filePath: managedFile.path,
          password: '',
        );
      }
    }
    final title = p.basenameWithoutExtension(fileName).trim();
    return Book(
      id: id,
      title: title.isEmpty ? '未命名 PDF' : title,
      format: BookFormat.pdf,
      chapters: const <Chapter>[],
      chapterCount: 0,
      importDate: now,
      fileSize: stat.size,
      sourcePath: managedFile.path,
      pageCount: pageCount,
    );
  } on Object catch (error) {
    try {
      if (await managedFile.exists()) await managedFile.delete();
    } on FileSystemException {
      // The failed import remains absent from metadata even if cleanup fails.
    }
    if (error is PlatformException) {
      final message = error.message?.trim();
      throw FormatException(
        message == null || message.isEmpty
            ? 'PDF 已损坏、加密或不受支持'
            : 'PDF 无法解析：$message',
      );
    }
    rethrow;
  }
}
