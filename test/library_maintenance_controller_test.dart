import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/controllers/library_maintenance_controller.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/repositories/reader_repositories.dart';

class _MaintenanceRepository implements LibraryMaintenanceRepository {
  int collections = 0;
  int checks = 0;
  Completer<BookAvailability>? pending;
  @override
  Future<Directory> getAppDataDirectory() async => Directory.systemTemp;
  @override
  Future<StorageCleanupResult> collectOrphanedData({
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? referenceTime,
  }) async {
    collections++;
    return const StorageCleanupResult(removedFiles: 0, removedDirectories: 0);
  }

  @override
  Future<BookAvailability> checkBookAvailability(
    Book book, {
    bool deep = false,
  }) async {
    expect(deep, isTrue);
    checks++;
    return pending?.future ?? Future.value(BookAvailability.available);
  }
}

Book _book() => Book(
  id: 'same-id',
  title: '书',
  format: BookFormat.txt,
  chapters: const [],
  importDate: DateTime(2026),
);

void main() {
  test('coalesces a scan and rejects results for a replaced book', () async {
    final repository = _MaintenanceRepository()..pending = Completer();
    var books = [_book()];
    final received = <Map<String, BookAvailability>>[];
    final controller = LibraryMaintenanceController(
      repository: repository,
      books: () => books,
      onAvailability: received.add,
      onError: (e, s) => fail('$e'),
      cleanup: () async {},
      bookInterval: Duration.zero,
    );
    final first = controller.run();
    final second = controller.run();
    await Future<void>.delayed(Duration.zero);
    expect(repository.checks, 1);
    books = [_book()];
    repository.pending!.complete(BookAvailability.payloadMissing);
    await Future.wait([first, second]);
    expect(received.single, isEmpty);
    expect(repository.collections, 1);
    controller.dispose();
  });

  test(
    'disposing an in-flight scan suppresses results and later checks',
    () async {
      final repository = _MaintenanceRepository()..pending = Completer();
      var notified = false;
      final books = [_book(), _book()];
      final controller = LibraryMaintenanceController(
        repository: repository,
        books: () => books,
        onAvailability: (_) => notified = true,
        onError: (e, s) => fail('$e'),
        cleanup: () async {},
        bookInterval: Duration.zero,
      );
      final pending = controller.run();
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      repository.pending!.complete(BookAvailability.available);
      await pending;
      expect(notified, isFalse);
      expect(repository.checks, 1);
      await controller.run();
      expect(repository.collections, 1);
    },
  );

  testWidgets('scheduled maintenance is cancelled with its owner', (
    tester,
  ) async {
    final repository = _MaintenanceRepository();
    final controller = LibraryMaintenanceController(
      repository: repository,
      books: () => [],
      onAvailability: (_) {},
      onError: (e, s) => fail('$e'),
      cleanup: () async {},
    );
    controller.schedule();
    controller.dispose();
    await tester.pump(const Duration(seconds: 31));
    expect(repository.collections, 0);
  });
}
