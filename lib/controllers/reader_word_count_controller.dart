import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import '../services/word_count_service.dart';

/// Owns reader-visible word counts and rejects stale background results.
class ReaderWordCountController {
  ReaderWordCountController(this._repository, Book book) {
    final storedCounts = book.chapterWordCounts?.length == book.chapters.length
        ? book.chapterWordCounts
        : null;
    final storedTotal = storedCounts == null
        ? null
        : WordCountService.totalFromChapterCounts(storedCounts);
    wordCount = ValueNotifier<int?>(storedTotal ?? book.wordCount);
    chapterWordCounts = ValueNotifier<List<int>?>(storedCounts);
  }

  final ReaderRepository _repository;
  late final ValueNotifier<int?> wordCount;
  late final ValueNotifier<List<int>?> chapterWordCounts;

  int _generation = 0;
  bool _disposed = false;

  bool needsRefresh(Book book) {
    final counts = chapterWordCounts.value;
    return counts == null ||
        counts.length != book.chapters.length ||
        book.wordCount != WordCountService.totalFromChapterCounts(counts);
  }

  void invalidate() {
    _generation++;
  }

  Future<void> ensure(Book sourceBook) async {
    final generation = ++_generation;
    try {
      final counts = await WordCountService().countChapters(sourceBook);
      final total = WordCountService.totalFromChapterCounts(counts);
      if (_disposed || generation != _generation) return;
      await _repository.saveWordCounts(sourceBook, counts);
      if (_disposed || generation != _generation) return;
      chapterWordCounts.value = counts;
      wordCount.value = total;
    } on Object catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;
      debugPrint('Failed to count reader text: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void apply({required List<int>? chapterCounts, required int? total}) {
    if (_disposed) return;
    chapterWordCounts.value = chapterCounts;
    wordCount.value = total;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    chapterWordCounts.dispose();
    wordCount.dispose();
  }
}
