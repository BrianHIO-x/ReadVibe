import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A serialized novel is the demanding case for chapter storage: importing one
/// pays every per-chapter step a thousand times over. These tests hold the
/// storage contract that lets that stay cheap — payloads are staged and
/// committed by rename, the manifest carries the evidence a reader needs, and
/// the shelf's own check never grows with the chapter count.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late StorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.resetLibraryCache();
    documents = Directory.systemTemp.createTempSync('readvibe_large_book_');
    storage = StorageService(documentsDirectory: documents);
  });

  tearDown(() {
    try {
      if (documents.existsSync()) documents.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows antivirus can briefly retain a handle after an isolate read.
    }
  });

  test('a thousand-chapter book round-trips through storage', () async {
    final book = _serializedNovel('long_novel', 1000);

    await storage.saveBook(book);
    final restored = await storage.getBook(book.id);

    expect(restored, isNotNull);
    expect(restored!.chapterCount, 1000);
    expect(restored.chapters.first.title, '第1章');
    expect(restored.chapters.first.content, _chapterBody(0));
    expect(restored.chapters[499].content, _chapterBody(499));
    expect(restored.chapters.last.title, '第1000章');
    expect(restored.chapters.last.content, _chapterBody(999));

    final directory = _chapterDirectory(documents, book.id);
    final stored = Directory(p.join(directory.path, 'chapters'))
        .listSync()
        .whereType<File>()
        .length;
    expect(stored, 1000);

    final manifest =
        jsonDecode(
              File(p.join(directory.path, 'manifest.json')).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(manifest['chapterCount'], 1000);
    final entries = manifest['chapters'] as List;
    expect(entries, hasLength(1000));
    // Length and digest are what let a reader tell a complete payload from one
    // that was cut short, so every entry must carry both.
    for (final entry in entries) {
      final record = entry as Map<String, dynamic>;
      expect(record['bytes'], isA<int>());
      expect(record['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
    }
  });

  test('the shelf check stays bounded but still sees a lost payload', () async {
    final book = _serializedNovel('shelf_check', 600);
    final committed = await storage.saveBook(book);

    expect(
      await storage.checkBookAvailability(committed),
      BookAvailability.available,
    );

    // An import that stopped partway leaves the newest payloads missing.
    final chapters = Directory(
      p.join(_chapterDirectory(documents, book.id).path, 'chapters'),
    );
    File(p.join(chapters.path, '000599.json')).deleteSync();

    expect(
      await storage.checkBookAvailability(committed),
      BookAvailability.payloadMissing,
    );
  });

  test('the deep sweep still inspects every chapter', () async {
    final book = _serializedNovel('deep_sweep', 600);
    final committed = await storage.saveBook(book);

    final chapters = Directory(
      p.join(_chapterDirectory(documents, book.id).path, 'chapters'),
    );
    // A single damaged payload in the middle is what the shallow sample may
    // step over; the verifying pass is the one that has to catch it.
    File(p.join(chapters.path, '000301.json')).writeAsStringSync('{"broken"');

    expect(
      await storage.checkBookAvailability(committed, deep: true),
      BookAvailability.payloadMissing,
    );
  });

  test('a rewritten book leaves no payload of the previous one', () async {
    final book = _serializedNovel('shrinking', 400);
    await storage.saveBook(book);

    await storage.saveBook(_serializedNovel('shrinking', 40));

    final chapters = Directory(
      p.join(_chapterDirectory(documents, book.id).path, 'chapters'),
    );
    expect(chapters.listSync().whereType<File>().length, 40);
    final restored = await storage.getBook(book.id);
    expect(restored?.chapterCount, 40);
    expect(restored?.chapters.last.content, _chapterBody(39));
  });
}

String _chapterBody(int index) =>
    '　　这是第${index + 1}章的正文，用来确认分章写入与读取完全一致。';

Book _serializedNovel(String id, int chapterCount) => Book(
  id: id,
  title: '连载长篇',
  format: BookFormat.txt,
  chapters: <Chapter>[
    for (var index = 0; index < chapterCount; index++)
      Chapter(
        index: index,
        title: '第${index + 1}章',
        content: _chapterBody(index),
      ),
  ],
  importDate: DateTime(2026, 1, 1),
  fileSize: chapterCount * 64,
);

Directory _chapterDirectory(Directory documents, String bookId) {
  final safeId = base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');
  return Directory(p.join(documents.path, 'ReadVibe', 'books', safeId));
}
