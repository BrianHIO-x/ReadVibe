import 'dart:io';

import '../models/book.dart';
import '../models/reader_bookmark.dart';
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

/// Private-storage footprint, split the way a reader thinks about it.
///
/// Imported books are data the user would lose on deletion. Caches are
/// regenerated on demand, so they are the only part safe to reclaim without
/// asking about individual books.
class StorageUsageReport {
  final int bookPayloadBytes;
  final int epubResourceBytes;
  final int wordResourceBytes;
  final int pdfCopyBytes;
  final int fontBytes;
  final int cacheBytes;
  final int bookCount;

  const StorageUsageReport({
    this.bookPayloadBytes = 0,
    this.epubResourceBytes = 0,
    this.wordResourceBytes = 0,
    this.pdfCopyBytes = 0,
    this.fontBytes = 0,
    this.cacheBytes = 0,
    this.bookCount = 0,
  });

  int get libraryBytes =>
      bookPayloadBytes +
      epubResourceBytes +
      wordResourceBytes +
      pdfCopyBytes +
      fontBytes;

  int get totalBytes => libraryBytes + cacheBytes;
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

/// Reports how much of a book's payload has reached disk.
///
/// A serialized novel takes long enough to save that the shelf has to be able
/// to tell the difference between slow and stuck, so the store announces its
/// own progress rather than leaving the caller to guess.
typedef ChapterWriteProgress =
    void Function(int chaptersWritten, int chapterCount);

/// Persistence required by the format-independent import coordinator.
abstract interface class BookImportStore
    implements AppDataDirectoryProvider, ImportedPdfStore {
  /// Persists a newly imported book and returns the committed snapshot, whose
  /// title may be numbered when the shelf already holds a book by that name.
  ///
  /// [onChapterProgress] is called as chapter payloads are written, before the
  /// shelf metadata is committed.
  Future<Book> saveBook(Book book, {ChapterWriteProgress? onChapterProgress});

  Future<void> discardImportedBook(Book book);
}

/// Storage operations needed by low-priority maintenance, without reader state.
abstract interface class LibraryMaintenanceRepository
    implements AppDataDirectoryProvider {
  Future<BookAvailability> checkBookAvailability(
    Book book, {
    bool deep = false,
  });

  Future<StorageCleanupResult> collectOrphanedData({
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? referenceTime,
  });

  /// Measures what ReadVibe occupies on this device.
  Future<StorageUsageReport> measureStorageUsage();

  /// Deletes regenerable caches and returns how many bytes were reclaimed.
  /// Imported books, reading state and edits are never touched.
  Future<int> clearTemporaryCaches();
}

/// Operations used by the shelf. Reader- and PDF-only state is intentionally
/// excluded so shelf changes do not depend on either reader implementation.
abstract interface class LibraryRepository
    implements
        BookImportStore,
        ImportedFontStore,
        LibraryMaintenanceRepository {
  Future<List<Book>> getBookSummaries();

  Future<Book?> getBook(String bookId);

  Future<void> updateBookDetails(
    String bookId, {
    required String title,
    String? author,
  });

  Future<void> saveBookOrder(List<String> bookIds);

  Future<void> deleteBook(String bookId);

  Future<ReadingProgress?> getShelfProgress(Book book);

  Future<ReaderSettings> getSettings();

  Future<void> saveSettings(ReaderSettings settings);
}

abstract interface class BookWordCountRepository {
  Future<void> saveWordCounts(Book sourceBook, List<int> chapterWordCounts);
}

abstract interface class ChapterEditingRepository
    implements BookWordCountRepository {
  /// Commits against sourceBook's content revision and returns the new snapshot.
  Future<Book> replaceChapter(Book sourceBook, Chapter replacement);
}

/// Operations used by the reflowable novel reader.
abstract interface class ReaderRepository
    implements ImportedFontStore, ChapterEditingRepository {
  Future<ReadingProgress?> getProgress(String bookId);

  Future<void> saveProgress(ReadingProgress progress);

  Future<ReaderSettings> getSettings();

  Future<void> saveSettings(ReaderSettings settings);

  Future<Set<String>> getCollapsedTocGroups(String bookId);

  Future<void> saveCollapsedTocGroups(String bookId, Set<String> groupIds);

  Future<List<ReaderBookmark>> getBookmarks(String bookId);

  Future<void> saveBookmarks(String bookId, List<ReaderBookmark> bookmarks);

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
