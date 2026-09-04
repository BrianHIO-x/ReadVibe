import 'dart:async';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import '../services/storage/obsolete_search_cleanup.dart';

/// Owns scheduling, cancellation and stale-result protection for shelf maintenance.
class LibraryMaintenanceController {
  LibraryMaintenanceController({
    required this.repository,
    required this.books,
    required this.onAvailability,
    required this.onError,
    Future<void> Function()? cleanup,
    this.initialDelay = const Duration(seconds: 30),
    this.bookInterval = const Duration(milliseconds: 120),
  }) : _cleanup = cleanup ?? (() => removeObsoleteSearchData(repository));

  final LibraryMaintenanceRepository repository;
  final List<Book> Function() books;
  final void Function(Map<String, BookAvailability>) onAvailability;
  final void Function(Object, StackTrace) onError;
  final Future<void> Function() _cleanup;
  final Duration initialDelay;
  final Duration bookInterval;
  Timer? _timer;
  Future<void>? _running;
  bool _scheduled = false;
  bool _disposed = false;

  void schedule() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    _timer = Timer(initialDelay, () {
      _timer = null;
      unawaited(run());
    });
  }

  Future<void> run() {
    if (_disposed) return Future<void>.value();
    final existing = _running;
    if (existing != null) return existing;
    final operation = _run();
    _running = operation;
    return operation.whenComplete(() => _running = null);
  }

  Future<void> _run() async {
    try {
      await _cleanup();
      if (_disposed) return;
      await repository.collectOrphanedData();
      if (_disposed) return;
      final snapshot = List<Book>.of(books());
      final scannedBooks = {for (final book in snapshot) book.id: book};
      final results = <String, BookAvailability>{};
      for (final book in snapshot) {
        if (_disposed) return;
        final availability = await repository.checkBookAvailability(
          book,
          deep: true,
        );
        if (_disposed) return;
        // A reload/edit may replace a book with the same ID during this scan.
        results[book.id] = availability;
        if (bookInterval > Duration.zero) {
          await Future<void>.delayed(bookInterval);
        }
      }
      if (_disposed) return;
      final currentBooks = {for (final book in books()) book.id: book};
      results.removeWhere(
        (id, _) => !identical(scannedBooks[id], currentBooks[id]),
      );
      onAvailability(Map<String, BookAvailability>.unmodifiable(results));
    } on Object catch (error, stack) {
      if (!_disposed) onError(error, stack);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
