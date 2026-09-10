import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _book(String id, String title) => Book(
  id: id,
  title: title,
  format: BookFormat.txt,
  chapters: [Chapter(index: 0, title: '第一章', content: '$title 的正文')],
  importDate: DateTime(2026),
  fileSize: 100,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.resetLibraryCache();
    root = await Directory.systemTemp.createTemp('readvibe_library_');
    storage = StorageService(documentsDirectory: root);
  });

  tearDown(() async {
    StorageService.resetLibraryCache();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> libraryFile() async =>
      File(p.join((await storage.getAppDataDirectory()).path, 'library.json'));

  test('the shelf lives in its own file, not in preferences', () async {
    await storage.saveBook(_book('one', '第一本'));

    expect(await (await libraryFile()).exists(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('readvibe_books'), isNull);
    expect(
      jsonDecode(await (await libraryFile()).readAsString()),
      isA<List<Object?>>().having((list) => list.length, 'entries', 1),
    );
  });

  test('an existing preference shelf migrates once and is then dropped', () async {
    final legacy = _book('legacy', '旧书架的书');
    // Write the record the way older builds stored it, without a payload file.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('readvibe_books', jsonEncode([legacy.toJson()]));
    StorageService.resetLibraryCache();

    final summaries = await storage.getBookSummaries();
    expect(summaries.single.title, '旧书架的书');
    expect(prefs.getString('readvibe_books'), isNull);
    expect(await (await libraryFile()).exists(), isTrue);

    // The migrated shelf survives a fresh service over the same directory.
    StorageService.resetLibraryCache();
    final reopened = StorageService(documentsDirectory: root);
    expect((await reopened.getBookSummaries()).single.id, 'legacy');
  });

  test('a shelf read hands out records the caller may edit freely', () async {
    await storage.saveBook(_book('one', '原名'));
    await storage.updateBookDetails('one', title: '改过的名字');

    expect((await storage.getBookSummaries()).single.title, '改过的名字');
    // A second read must not see leftovers from the first read's edits.
    expect((await storage.getBookSummaries()).single.title, '改过的名字');
  });

  test('an interrupted write leaves the previous shelf readable', () async {
    await storage.saveBook(_book('one', '第一本'));
    final file = await libraryFile();
    final good = await file.readAsString();

    // A crash between the rename steps can leave only the backup behind.
    await File('${file.path}.bak').writeAsString(good, flush: true);
    await file.delete();
    StorageService.resetLibraryCache();

    expect((await storage.getBookSummaries()).single.title, '第一本');
  });

  test('a damaged shelf file reports empty rather than inventing books', () async {
    await storage.saveBook(_book('one', '第一本'));
    await (await libraryFile()).writeAsString('{不是列表', flush: true);
    StorageService.resetLibraryCache();

    expect(await storage.getBookSummaries(), isEmpty);
  });
}
