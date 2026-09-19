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
  }) async {
    Book? importedBook;
    var metadataSaved = false;
    try {
      final format = detectBookImportFormat(path: path, fileName: fileName);
      final labeledName = labeledImportFileName(path, fileName, format);
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

      final committed = await _storage.saveBook(importedBook);
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
