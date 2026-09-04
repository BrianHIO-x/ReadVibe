import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import '../services/word_count_service.dart';

class ChapterEditResult {
  final Book book;
  final List<int>? chapterWordCounts;
  final int? wordCount;

  const ChapterEditResult({
    required this.book,
    required this.chapterWordCounts,
    required this.wordCount,
  });
}

/// Owns the storage and derived-data transaction for editing one chapter.
/// ReaderScreen remains responsible only for view caches and anchor restore.
class ChapterEditingController {
  ChapterEditingController(this._repository);

  final ReaderRepository _repository;

  Future<ChapterEditResult> save({
    required Book sourceBook,
    required int chapterIndex,
    required String title,
    required String content,
    required List<int>? existingChapterWordCounts,
  }) async {
    if (chapterIndex < 0 || chapterIndex >= sourceBook.chapters.length) {
      throw RangeError.index(chapterIndex, sourceBook.chapters, 'chapterIndex');
    }

    final sourceChapter = sourceBook.chapters[chapterIndex];
    final normalizedContent = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final replacement = Chapter(
      index: sourceChapter.index,
      title: title.trim(),
      content: normalizedContent,
      volumeTitle: sourceChapter.volumeTitle,
    );

    WordCountService.invalidateBook(sourceBook.id);
    await _repository.replaceChapter(sourceBook, replacement);

    final chapters = List<Chapter>.of(sourceBook.chapters);
    chapters[chapterIndex] = replacement;
    List<int>? chapterWordCounts;
    try {
      final editedCount = await WordCountService.countContent(
        normalizedContent,
      );
      if (existingChapterWordCounts != null &&
          existingChapterWordCounts.length == chapters.length) {
        final nextCounts = List<int>.of(existingChapterWordCounts);
        nextCounts[chapterIndex] = editedCount;
        chapterWordCounts = List<int>.unmodifiable(nextCounts);
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to count edited chapter: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    final wordCount = chapterWordCounts == null
        ? null
        : WordCountService.totalFromChapterCounts(chapterWordCounts);
    final nextBook = sourceBook.copyWith(
      chapters: List<Chapter>.unmodifiable(chapters),
      wordCount: wordCount,
      chapterWordCounts: chapterWordCounts,
      clearWordCounts: chapterWordCounts == null,
    );
    if (chapterWordCounts != null) {
      try {
        await _repository.saveWordCounts(nextBook, chapterWordCounts);
      } on Object catch (error, stackTrace) {
        // The chapter commit is authoritative. Summary counts can be rebuilt.
        debugPrint('Failed to save edited word count: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    return ChapterEditResult(
      book: nextBook,
      chapterWordCounts: chapterWordCounts,
      wordCount: wordCount,
    );
  }
}
