import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late StorageService storage;
  late Book source;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('readvibe_transaction_');
    storage = StorageService(documentsDirectory: directory);
    source = Book(
      id: directory.path,
      title: '版本测试',
      format: BookFormat.txt,
      chapters: const [Chapter(index: 0, title: '第一章', content: '旧文')],
      importDate: DateTime(2026),
      fileSize: 100,
    );
    await storage.saveBook(source);
    source = (await storage.getBook(source.id))!;
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  const replacement = Chapter(index: 0, title: '新标题', content: '新的章节正文');

  test('old count results cannot overwrite the edited content', () async {
    await storage.replaceChapter(source, replacement);
    final latest = (await storage.getBook(source.id))!;
    await storage.saveWordCounts(latest, [6]);
    await storage.saveWordCounts(source, [2]);
    expect((await storage.getBook(source.id))!.wordCount, 6);
  });

  test('a stale editor cannot overwrite a previously committed edit', () async {
    await storage.replaceChapter(source, replacement);
    await expectLater(
      storage.replaceChapter(
        source,
        const Chapter(index: 0, title: '过期', content: '覆盖正文'),
      ),
      throwsStateError,
    );
    expect(
      (await storage.getBook(source.id))!.chapters.single.content,
      replacement.content,
    );
  });

  test('an existing lazy snapshot stays readable after an edit', () async {
    await storage.replaceChapter(source, replacement);
    expect(source.chapters.single.content, '旧文');
  });

  test(
    'deletion and an edit leave neither metadata nor a revived payload',
    () async {
      final editing = storage.replaceChapter(source, replacement);
      final observed = editing.then<void>((_) {}, onError: (Object _) {});
      await storage.deleteBook(source.id);
      await observed;
      expect(await storage.getBook(source.id), isNull);
      expect(await storage.getBookSummaries(), isEmpty);
      final id = base64Url.encode(utf8.encode(source.id)).replaceAll('=', '');
      expect(
        await Directory(
          p.join(directory.path, 'ReadVibe', 'books', id),
        ).exists(),
        isFalse,
      );
    },
  );
}
