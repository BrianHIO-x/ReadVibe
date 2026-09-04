import 'dart:io';

import '../models/book.dart';
import '../models/reader_settings.dart';

/// Result of a low-priority private-storage consistency sweep.
class StorageCleanupResult {
  final int removedFiles;
  final int removedDirectories;

  const StorageCleanupResult({
    required this.removedFiles,
    required this.removedDirectories,
  });

  int get removedEntries => removedFiles + removedDirectories;
}

/// Narrow resource boundary used by EPUB, DOCX and legacy search cleanup.
abstract interface class AppDataDirectoryProvider {
  Future<Directory> getAppDataDirectory();
}

abstract interface class ImportedFontStore {
  Future<File> saveImportedFont(String sourcePath, String fileName);
}

abstract interface class ImportedPdfStore {
  Future<File> saveImportedPdf(String sourcePath, String bookId);
}

/// Persistence required by the format-independent import coordinator.
abstract interface class BookImportStore
    implements AppDataDirectoryProvider, ImportedPdfStore {
  Future<void> saveBook(Book book);

  Future<void> discardImportedBook(Book book);
}

/// Operations used by the shelf. Reader- and PDF-only state is intentionally
/// excluded so shelf changes do not depend on either reader implementation.
abstract interface class LibraryRepository
    implements BookImportStore, ImportedFontStore {
  Future<List<Book>> getBookSummaries();

  Future<Book?> getBook(String bookId);

  Future<BookAvailability> checkBookAvailability(
    Book book, {
    bool deep = false,
  });

  Future<void> updateBookDetails(
    String bookId, {
    required String title,
    String? author,
  });

  Future<void> saveBookOrder(List<String> bookIds);

  Future<void> deleteBook(String bookId);

  Future<StorageCleanupResult> collectOrphanedData({
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? referenceTime,
  });

  Future<ReadingProgress?> getShelfProgress(Book book);

  Future<ReaderSettings> getSettings();

  Future<void> saveSettings(ReaderSettings settings);
}

/// Operations used by the reflowable novel reader.
abstract interface class ReaderRepository implements ImportedFontStore {
  Future<ReadingProgress?> getProgress(String bookId);

  Future<void> saveProgress(ReadingProgress progress);

  Future<ReaderSettings> getSettings();

  Future<void> saveSettings(ReaderSettings settings);

  Future<Set<String>> getCollapsedTocGroups(String bookId);

  Future<void> saveCollapsedTocGroups(String bookId, Set<String> groupIds);

  Future<void> replaceChapter(Book sourceBook, Chapter replacement);

  Future<void> saveWordCounts(Book sourceBook, List<int> chapterWordCounts);

  Future<void> deleteBook(String bookId);
}

/// Operations used by the fixed-layout PDF reader.
abstract interface class PdfReaderRepository {
  Future<PdfReadingProgress?> getPdfProgress(
    String bookId, {
    required int pageCount,
    bool migrateLegacy = true,
  });

  Future<void> savePdfProgress(PdfReadingProgress progress);

  Future<Set<int>> getPdfBookmarks(String bookId, int pageCount);

  Future<void> savePdfBookmarks(String bookId, Set<int> pages, int pageCount);

  Future<Map<int, String>> getPdfNotes(String bookId, int pageCount);

  Future<void> savePdfNotes(
    String bookId,
    Map<int, String> notes,
    int pageCount,
  );

  Future<PdfDisplayTheme> getPdfDisplayTheme(String bookId);

  Future<void> savePdfDisplayTheme(String bookId, PdfDisplayTheme theme);

  Future<void> deleteBook(String bookId);
}
