import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/repositories/reader_repositories.dart';
import 'package:readvibe/services/managed_book_resources.dart';

class _Directories implements AppDataDirectoryProvider {
  _Directories(this.root);
  final Directory root;
  @override
  Future<Directory> getAppDataDirectory() async => root;
}

void main() {
  late Directory root;
  setUp(
    () => root = Directory.systemTemp.createTempSync('readvibe_resources_'),
  );
  tearDown(() => root.deleteSync(recursive: true));

  test('PDF cache closes before its managed source is removed', () async {
    final source = File('${root.path}/pdf/book.pdf');
    await source.parent.create();
    await source.writeAsBytes([1, 2, 3]);
    var cleared = false;
    final resources = ManagedBookResources(
      _Directories(root),
      clearPdfCache: (path) async {
        expect(path, source.absolute.path);
        expect(await source.exists(), isTrue);
        cleared = true;
      },
    );
    await resources.deleteSource(source.path);
    expect(cleared, isTrue);
    expect(await source.exists(), isFalse);
  });

  test('resource deletion never reaches an unmanaged sibling', () async {
    final source = File('${root.path}/pdf-other/book.pdf');
    await source.parent.create();
    await source.writeAsBytes([1]);
    final resources = ManagedBookResources(
      _Directories(root),
      clearPdfCache: (_) async =>
          fail('unmanaged PDF must not reach native cache'),
    );
    await resources.deleteSource(source.path);
    await resources.deleteFont(source.path);
    expect(await source.exists(), isTrue);
  });

  test(
    'failed platform cleanup does not resurrect a deleted resource',
    () async {
      final source = File('${root.path}/pdf/book.pdf');
      await source.parent.create();
      await source.writeAsBytes([1]);
      final resources = ManagedBookResources(
        _Directories(root),
        clearPdfCache: (_) async => throw StateError('platform unavailable'),
      );
      await resources.deleteSource(source.path);
      expect(await source.exists(), isFalse);
    },
  );
}
