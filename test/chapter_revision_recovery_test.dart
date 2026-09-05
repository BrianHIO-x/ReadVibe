import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:readvibe/services/word_count_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StorageService storage;
  late Book book;
  late Directory bookDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('readvibe_revisions_');
    storage = StorageService(documentsDirectory: root);
    book = Book(
      id: root.path,
      title: '书',
      format: BookFormat.txt,
      chapters: const [Chapter(index: 0, title: '第一章', content: '旧文')],
      importDate: DateTime(2026),
      fileSize: 100,
    );
    await storage.saveBook(book);
    final id = base64Url.encode(utf8.encode(book.id)).replaceAll('=', '');
    bookDirectory = Directory(p.join(root.path, 'ReadVibe', 'books', id));
    book = (await storage.getBook(book.id))!;
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  const next = Chapter(index: 0, title: '新标题', content: '新的章节正文');

  test(
    'manifest revision wins after interruption before metadata commit',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final before = prefs.getString('readvibe_books')!;
      final edited = await storage.replaceChapter(book, next);
      await prefs.setString('readvibe_books', before);
      final loaded = (await storage.getBook(book.id))!;
      expect(loaded.contentRevision, edited.contentRevision);
      expect(loaded.wordCount, isNull);
      await storage.saveWordCounts(book, [2]);
      expect((await storage.getBook(book.id))!.wordCount, isNull);
      await storage.saveWordCounts(loaded, [6]);
      expect((await storage.getBook(book.id))!.wordCount, 6);
      final second = await storage.replaceChapter(loaded, next);
      expect(second.contentRevision, edited.contentRevision + 1);
    },
  );

  test('edited book backup recovery preserves the content revision', () async {
    final edited = await storage.replaceChapter(book, next);
    await bookDirectory.rename('${bookDirectory.path}.bak');
    final recovered = (await storage.getBook(book.id))!;
    expect(recovered.contentRevision, edited.contentRevision);
    expect(recovered.chapters.single.content, next.content);
    await storage.saveWordCounts(book, [2]);
    expect((await storage.getBook(book.id))!.wordCount, isNull);
  });

  test(
    'word count cache follows committed revision without caller invalidation',
    () async {
      expect(await WordCountService().countChapters(book), [2]);
      final edited = await storage.replaceChapter(book, next);
      expect(await WordCountService().countChapters(edited), [6]);
      expect(await WordCountService().countChapters(book), [2]);
    },
  );

  test(
    'obsolete payloads respect grace time and recovery manifest references',
    () async {
      final live = File(p.join(bookDirectory.path, 'manifest.json'));
      final oldManifest = await live.readAsString();
      await storage.replaceChapter(book, next);
      final oldPayload = File(
        p.join(bookDirectory.path, 'chapters', '000000.json'),
      );
      await storage.collectOrphanedData();
      expect(await oldPayload.exists(), isTrue);
      await oldPayload.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      final backup = File('${live.path}.edit.bak');
      await backup.writeAsString(oldManifest);
      await storage.collectOrphanedData();
      expect(await oldPayload.exists(), isTrue);
      await backup.delete();
      await storage.collectOrphanedData();
      expect(await oldPayload.exists(), isFalse);
      expect(
        (await storage.getBook(book.id))!.chapters.single.content,
        next.content,
      );
    },
  );

  test('malformed recovery manifest disables payload collection', () async {
    await storage.replaceChapter(book, next);
    final oldPayload = File(
      p.join(bookDirectory.path, 'chapters', '000000.json'),
    );
    await oldPayload.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    await File(
      p.join(bookDirectory.path, 'manifest.json.edit.tmp'),
    ).writeAsString('{');
    await storage.collectOrphanedData();
    expect(await oldPayload.exists(), isTrue);
  });
  test(
    'legacy reparsing remaps progress before old lazy files are replaced',
    () async {
      final legacy = Book(
        id: '${root.path}_legacy',
        title: '旧解析书',
        format: BookFormat.txt,
        txtParserVersion: 2,
        chapters: List.generate(
          12,
          (index) => Chapter(
            index: index,
            title: '第${index * 2 + 1}章 标题',
            content: '${'旧正文。' * 100}\n第${index * 2 + 2}章 标题\n${'新正文。' * 100}',
          ),
        ),
        importDate: DateTime(2026),
        fileSize: 12000,
      );
      await storage.saveBook(legacy);
      await storage.saveProgress(
        ReadingProgress(
          bookId: legacy.id,
          chapterIndex: 11,
          scrollProgress: 0.5,
          chapterProgress: const {11: 0.5},
          lastReadDate: DateTime(2026, 2),
        ),
      );
      final upgraded = (await storage.getBook(legacy.id))!;
      expect(upgraded.txtParserVersion, currentTxtParserVersion);
      expect(upgraded.chapters.length, 24);
      expect(
        (await storage.getProgress(legacy.id))!.chapterIndex,
        greaterThan(11),
      );
      expect(
        (await storage.getBook(legacy.id))!.contentRevision,
        upgraded.contentRevision,
      );
    },
  );
  for (final suffix in ['.edit.bak', '.edit.tmp']) {
    test(
      'editing a recovered $suffix manifest commits and remains readable',
      () async {
        final first = await storage.replaceChapter(book, next);
        final live = File(p.join(bookDirectory.path, 'manifest.json'));
        await live.rename('${live.path}$suffix');
        final recovered = (await storage.getBook(book.id))!;
        expect(recovered.contentRevision, first.contentRevision);
        final latest = await storage.replaceChapter(
          recovered,
          const Chapter(index: 0, title: '恢复后编辑', content: '再次修改'),
        );
        expect(latest.contentRevision, first.contentRevision + 1);
        expect(
          (await storage.getBook(book.id))!.chapters.single.content,
          '再次修改',
        );
        expect(await live.exists(), isTrue);
      },
    );
  }
}
