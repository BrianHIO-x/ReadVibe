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
    this.canRun,
    Future<void> Function()? cleanup,
    this.initialDelay = const Duration(seconds: 30),
    this.bookInterval = const Duration(milliseconds: 120),
  }) : _cleanup = cleanup ?? (() => removeObsoleteSearchData(repository));

  final LibraryMaintenanceRepository repository;
  final List<Book> Function() books;
  final void Function(Map<String, BookAvailability>) onAvailability;
  final void Function(Object, StackTrace) onError;
  final bool Function()? canRun;
  final Future<void> Function() _cleanup;
  final Duration initialDelay;
  final Duration bookInterval;
  Timer? _timer;
  Future<void>? _running;
  bool _scheduled = false;
  bool _disposed = false;
  bool _cleaned = false;
  final Map<String, Book> _checkedBooks = {};

  void schedule() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    _timer = Timer(initialDelay, () {
      _timer = null;
      _scheduled = false;
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
      if (!_mayContinue()) return;
      if (!_cleaned) {
        await _cleanup();
        if (!_mayContinue()) return;
        await repository.collectOrphanedData();
        _cleaned = true;
      }
      if (!_mayContinue()) return;
      final snapshot = List<Book>.of(books());
      final ids = snapshot.map((book) => book.id).toSet();
      _checkedBooks.removeWhere((id, _) => !ids.contains(id));
      for (final book in snapshot) {
        if (!_mayContinue()) return;
        if (identical(_checkedBooks[book.id], book)) continue;
        final availability = await repository.checkBookAvailability(
          book,
          deep: true,
        );
        if (_disposed) return;
        // Publish one book at a time, with identity checked at the commit.
        // Busy readers pause between books; checked entries survive the pause.
        if (books().any((current) => identical(current, book))) {
          _checkedBooks[book.id] = book;
          onAvailability({book.id: availability});
        }
        if (bookInterval > Duration.zero) {
          await Future<void>.delayed(bookInterval);
        }
      }
    } on Object catch (error, stack) {
      if (!_disposed) onError(error, stack);
    }
  }

  bool _mayContinue() {
    if (_disposed) return false;
    if (canRun?.call() != false) return true;
    schedule();
    return false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
