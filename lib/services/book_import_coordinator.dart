import 'dart:isolate';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import 'book_import_format.dart';
import 'epub_parser.dart';
import 'mobi_parser.dart';
import 'pdf_import_service.dart';
import 'pdf_renderer_service.dart';
import 'txt_parser.dart';
import 'word_parser.dart';

typedef PdfPasswordProvider = Future<String?> Function();

typedef BookImportProgressReporter = void Function(BookImportProgress progress);

/// Where an import currently is.
///
/// A serialized novel takes long enough that a single opaque label cannot tell
/// the reader whether the app is working or wedged. Naming the step, and
/// counting chapters while they are written, is what makes the difference
/// visible.
enum BookImportStage { inspecting, parsing, saving }

class BookImportProgress {
  const BookImportProgress(this.stage, {this.completed = 0, this.total = 0});

  final BookImportStage stage;

  /// Chapters already written, meaningful while [stage] is
  /// [BookImportStage.saving].
  final int completed;

  /// Chapters the book holds, or zero before the count is known.
  final int total;

  /// How far the current step has come, or null when it cannot be measured.
  double? get fraction {
    if (total <= 0 || completed <= 0) return null;
    return (completed / total).clamp(0.0, 1.0);
  }

  /// Short Chinese label for the shelf.
  String get label => switch (stage) {
    BookImportStage.inspecting => '识别文件',
    BookImportStage.parsing => '解析正文',
    BookImportStage.saving => '保存章节',
  };
}

/// Format-independent import transaction used by both the file picker and
/// Android ACTION_VIEW entry points.
///
/// The shelf owns presentation and password dialogs; this coordinator owns
/// format dispatch, persistence and rollback of private import resources.
class BookImportCoordinator {
  BookImportCoordinator(this._storage);

  static const supportedExtensions = <String>[
    'txt',
    'epub',
    'mobi',
    'azw',
    'azw3',
    'docx',
    'doc',
    'pdf',
  ];

  final BookImportStore _storage;

  Future<Book?> importFile({
    required String path,
    required String fileName,
    required PdfPasswordProvider requestPdfPassword,
    BookImportProgressReporter? onProgress,
    bool Function()? isCancelled,
  }) async {
    void checkActive() {
      if (isCancelled?.call() == true) {
        throw const FormatException('本次导入已停止');
      }
    }

    Book? importedBook;
    var metadataSaved = false;
    try {
      onProgress?.call(const BookImportProgress(BookImportStage.inspecting));
      final format = await _detectInBackground(path, fileName);
      checkActive();
      final labeledName = labeledImportFileName(path, fileName, format);
      onProgress?.call(const BookImportProgress(BookImportStage.parsing));
      if (format == BookFormat.epub) {
        importedBook = await parseEpub(path, labeledName, _storage);
      } else if (format == BookFormat.pdf) {
        importedBook = await _importPdf(
          path: path,
          fileName: labeledName,
          requestPassword: requestPdfPassword,
        );
        if (importedBook == null) return null;
      } else if (format == BookFormat.txt) {
        importedBook = await parseTxt(path, labeledName);
      } else if (format == BookFormat.mobi ||
          format == BookFormat.azw ||
          format == BookFormat.azw3) {
        importedBook = await parseKindleBook(path, labeledName);
      } else if (format == BookFormat.docx || format == BookFormat.doc) {
        importedBook = await parseWordDocument(path, labeledName, _storage);
      } else {
        throw const FormatException(unsupportedBookFormatMessage);
      }

      checkActive();
      onProgress?.call(
        BookImportProgress(
          BookImportStage.saving,
          total: importedBook.chapterCount,
        ),
      );
      final committed = await _storage.saveBook(
        importedBook,
        onChapterProgress: (written, count) {
          checkActive();
          onProgress?.call(
            BookImportProgress(
              BookImportStage.saving,
              completed: written,
              total: count,
            ),
          );
        },
      );
      metadataSaved = true;
      return committed;
    } on Object {
      if (!metadataSaved && importedBook != null) {
        try {
          await _storage.discardImportedBook(importedBook);
        } on Object {
          // Preserve the original parsing or persistence error. Storage
          // maintenance can reclaim an interrupted private resource later.
        }
      }
      rethrow;
    }
  }

  Future<Book?> _importPdf({
    required String path,
    required String fileName,
    required PdfPasswordProvider requestPassword,
  }) async {
    try {
      return await importPdf(path, fileName, _storage);
    } on PdfPasswordRequiredException {
      final password = await requestPassword();
      if (password == null) return null;
      try {
        return await importPdf(path, fileName, _storage, password: password);
      } on PdfPasswordRequiredException {
        throw const FormatException('PDF 密码不正确');
      }
    }
  }
}

/// Detects the format of [path] in a worker isolate.
///
/// The body runs at the top level on purpose. A closure written inside
/// [BookImportCoordinator.importFile] would share that method's capture
/// context, and anything else held there travels with it: the password
/// callback and the progress reporter both belong to the shelf, and a live
/// timer or widget state cannot cross an isolate boundary. Taking the two
/// strings as parameters means nothing else can be reached from here.
Future<BookFormat> _detectInBackground(String path, String fileName) =>
    Isolate.run(() => detectBookImportFormat(path: path, fileName: fileName));
