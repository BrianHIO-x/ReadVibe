import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/book_export_service.dart';
import 'package:readvibe/services/storage_service.dart';

class _Destination implements BookExportDestination {
  bool result = true;
  bool fail = false;
  String? name, mime, text;
  List<int>? bytes;
  @override
  Future<bool> save({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    name = fileName;
    mime = mimeType;
    bytes = await File(sourcePath).readAsBytes();
    if (mimeType == 'text/plain') text = await File(sourcePath).readAsString();
    if (fail) throw PlatformException(code: 'WRITE_FAILED');
    return result;
  }
}

Book _book({
  String title = '测试书',
  List<Chapter>? chapters,
  BookFormat format = BookFormat.txt,
  String? source,
}) => Book(
  id: 'export-book',
  title: title,
  author: '作者甲',
  format: format,
  importDate: DateTime(2026),
  fileSize: 100,
  sourcePath: source,
  chapters: chapters ?? const [Chapter(index: 0, title: '第一章', content: '正文')],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('readvibe_export_');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  Future<void> expectClean() async {
    final cache = Directory(p.join(temp.path, 'readvibe_exports'));
    expect(await cache.list().toList(), isEmpty);
  }

  test(
    'exports latest saved lazy chapters with UTF-8 and safe filenames',
    () async {
      final storage = StorageService(
        documentsDirectory: Directory(p.join(temp.path, 'data')),
      );
      final source = _book(
        title: '../书:名?🌙',
        chapters: const [
          Chapter(index: 0, title: '第一章', content: '旧正文', volumeTitle: '第一卷'),
          Chapter(index: 1, title: '第二章', content: '下一章', volumeTitle: '第一卷'),
        ],
      );
      await storage.saveBook(source);
      final edited = '${'字' * 32767}🌙新内容';
      await storage.replaceChapter(
        source,
        Chapter(index: 0, title: '新标题', content: edited, volumeTitle: '第一卷'),
      );
      final latest = (await storage.getBook(source.id))!;
      final destination = _Destination();
      final exporter = BookExportService(
        destination: destination,
        temporaryDirectory: () async => temp,
      );
      expect(await exporter.exportBook(latest), isTrue);
      expect(destination.text, contains('作者：作者甲'));
      expect(destination.text, contains(edited));
      expect(destination.text, isNot(contains('旧正文')));
      expect(
        destination.text!.indexOf('新标题'),
        lessThan(destination.text!.indexOf('第二章')),
      );
      expect('第一卷'.allMatches(destination.text!).length, 1);
      expect(destination.name, endsWith('.txt'));
      expect(destination.name, isNot(matches(RegExp(r'[/\\:?]'))));
      expect(destination.mime, 'text/plain');
      expect(
        (await storage.getBook(source.id))!.chapters.first.content,
        edited,
      );
      await expectClean();
    },
  );

  test(
    'EPUB text preserves heading blocks without duplicating chapter heading',
    () async {
      final destination = _Destination();
      final book = _book(
        format: BookFormat.epub,
        chapters: const [
          Chapter(
            index: 0,
            title: '第一章',
            content: '旧的纯文本',
            epubBlocks: [
              EpubContentBlock(
                kind: EpubContentBlockKind.text,
                text: '第一章',
                isHeading: true,
              ),
              EpubContentBlock(
                kind: EpubContentBlockKind.text,
                text: '小节标题',
                isHeading: true,
              ),
              EpubContentBlock(
                kind: EpubContentBlockKind.text,
                runs: [EpubTextRun(text: '完整正文', style: EpubContentStyle())],
              ),
            ],
          ),
        ],
      );
      await BookExportService(
        destination: destination,
        temporaryDirectory: () async => temp,
      ).exportBook(book);
      expect('第一章'.allMatches(destination.text!).length, 1);
      expect(destination.text, contains('小节标题'));
      expect(destination.text, contains('完整正文'));
      await expectClean();
    },
  );

  test(
    'PDF exports the current bytes and cancellation preserves the source',
    () async {
      final pdf = File(p.join(temp.path, 'original.pdf'));
      final bytes = <int>[
        37,
        80,
        68,
        70,
        45,
        ...List.generate(150000, (i) => i % 256),
      ];
      await pdf.writeAsBytes(bytes);
      final destination = _Destination()..result = false;
      final book = _book(
        format: BookFormat.pdf,
        source: pdf.path,
        chapters: [],
      );
      expect(
        await BookExportService(
          destination: destination,
          temporaryDirectory: () async => temp,
        ).exportBook(book),
        isFalse,
      );
      expect(destination.bytes, bytes);
      expect(destination.mime, 'application/pdf');
      expect(destination.name, endsWith('.pdf'));
      expect(await pdf.readAsBytes(), bytes);
      await expectClean();
    },
  );

  test(
    'write failures and invalid sources clean their private staging directory',
    () async {
      final destination = _Destination()..fail = true;
      final exporter = BookExportService(
        destination: destination,
        temporaryDirectory: () async => temp,
      );
      await expectLater(
        exporter.exportBook(_book()),
        throwsA(isA<PlatformException>()),
      );
      await expectClean();
      await expectLater(
        prepareBookExport(
          _book(format: BookFormat.pdf, source: '/missing.pdf'),
          temp,
        ),
        throwsFormatException,
      );
      await expectClean();
      await expectLater(
        prepareBookExport(_book(chapters: []), temp),
        throwsFormatException,
      );
      await expectClean();
    },
  );

  test(
    'Android gateway forwards only a prepared path, filename and MIME',
    () async {
      MethodCall? request;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AndroidBookExportDestination.channel, (
        call,
      ) async {
        request = call;
        return false;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          AndroidBookExportDestination.channel,
          null,
        ),
      );
      expect(
        await const AndroidBookExportDestination().save(
          sourcePath: '/cache/book.txt',
          fileName: '书.txt',
          mimeType: 'text/plain',
        ),
        isFalse,
      );
      expect(request!.method, 'save');
      expect(request!.arguments, {
        'sourcePath': '/cache/book.txt',
        'fileName': '书.txt',
        'mimeType': 'text/plain',
      });
    },
  );
}
