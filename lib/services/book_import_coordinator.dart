import '../models/book.dart';
import '../repositories/reader_repositories.dart';
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
      final lowerName = fileName.toLowerCase();
      if (lowerName.endsWith('.epub')) {
        importedBook = await parseEpub(path, fileName, _storage);
      } else if (lowerName.endsWith('.pdf')) {
        importedBook = await _importPdf(
          path: path,
          fileName: fileName,
          requestPassword: requestPdfPassword,
        );
        if (importedBook == null) return null;
      } else if (lowerName.endsWith('.txt')) {
        importedBook = await parseTxt(path, fileName);
      } else if (lowerName.endsWith('.mobi') ||
          lowerName.endsWith('.azw') ||
          lowerName.endsWith('.azw3')) {
        importedBook = await parseKindleBook(path, fileName);
      } else if (lowerName.endsWith('.docx') || lowerName.endsWith('.doc')) {
        importedBook = await parseWordDocument(path, fileName, _storage);
      } else {
        throw const FormatException(
          '不支持的文件格式，请选择 TXT、EPUB、MOBI、AZW、AZW3、PDF、DOCX 或 DOC',
        );
      }

      await _storage.saveBook(importedBook);
      metadataSaved = true;
      return importedBook;
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
