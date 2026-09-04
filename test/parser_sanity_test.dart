import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dart3_big5/big5.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/epub_parser.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:readvibe/services/txt_parser.dart';

ArchiveFile _f(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

ArchiveFile _bytes(String name, List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('txt parser', () {
    test('chapter extraction with volumes and intro titles', () {
      final chapters = extractTxtChapters([
        '序言 命运的齿轮',
        '开篇的内容。',
        '第一卷 风起',
        '卷首语内容。',
        '第一章 初入京城',
        '他走进了城门。',
        '第二章 夜谈',
        '灯火通明。',
      ]);
      expect(chapters.length, 4);
      expect(chapters[0].title, '序言 命运的齿轮');
      expect(chapters[2].volumeTitle, '第一卷 风起');
      expect(chapters[3].volumeTitle, '第一卷 风起');
      expect(chapters[3].content.startsWith('　　灯火通明。'), isTrue);
    });

    test('prose that resembles a heading is not split', () {
      final chapters = extractTxtChapters([
        '第一章 起',
        '第一卷载官股——皇室内帑、户部出资。',
        '普通的一句话。',
      ]);
      expect(chapters.length, 1);
    });

    test('adjacent duplicate numbered headings collapse', () {
      final chapters = extractTxtChapters(['第一百一十五章 转折', '', '第115章 转折', '乙。']);
      expect(chapters.length, 1);
    });

    test('encodings detected', () {
      expect(decodeTxtBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('汉字')]), '汉字');
      final le = '汉字'.codeUnits.expand((c) => [c & 0xFF, c >> 8]).toList();
      expect(decodeTxtBytes([0xFF, 0xFE, ...le]), '汉字');
      const traditional = '第一章　繁體中文閱讀。';
      expect(decodeTxtBytes(Big5.encode(traditional)), traditional);
    });

    test('oversized txt rejected before reading', () async {
      final big = File('${Directory.systemTemp.path}/readvibe_big_test.txt');
      final raf = await big.open(mode: FileMode.writeOnly);
      await raf.setPosition(300 * 1024 * 1024 - 1);
      await raf.writeByte(0x20);
      await raf.close();
      await expectLater(
        parseTxt(big.path, 'big.txt'),
        throwsA(isA<FormatException>()),
      );
      await big.delete();
    });

    test('v2 books apply recoverable v3 volume metadata', () {
      final legacy = Book(
        id: 'txt_v2',
        title: '旧书',
        format: BookFormat.txt,
        chapters: const <Chapter>[
          Chapter(index: 0, title: '第一卷 风起', content: '卷首文字。'),
          Chapter(index: 1, title: '第一章 初见', content: '正文。'),
        ],
        importDate: DateTime(2026, 1, 1),
        fileSize: 32,
        txtParserVersion: 2,
      );

      final upgraded = upgradeLegacyTxtBook(legacy);

      expect(upgraded.txtParserVersion, currentTxtParserVersion);
      expect(upgraded.chapters.last.volumeTitle, '第一卷 风起');
    });
  });

  group('epub parser', () {
    test('compressed input is rejected before ZIP decoding', () async {
      final dir = Directory.systemTemp.createTempSync('readvibe_epub_limit_');
      addTearDown(() {
        try {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Temp cleanup is best-effort on Windows.
        }
      });
      final epubFile = File('${dir.path}/oversized.epub')
        ..writeAsBytesSync(List<int>.filled(9, 0));

      await expectLater(
        parseEpub(
          epubFile.path,
          'oversized.epub',
          StorageService(documentsDirectory: dir),
          limits: const EpubParseLimits(maxInputBytes: 8),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('文件过大'),
          ),
        ),
      );
    });

    test('encrypted spine content reports DRM explicitly', () async {
      final archive = Archive()
        ..addFile(
          _f('META-INF/container.xml', '''
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>'''),
        )
        ..addFile(
          _f('META-INF/encryption.xml', '''
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <EncryptedData><CipherData><CipherReference URI="OEBPS/c1.xhtml"/></CipherData></EncryptedData>
</encryption>'''),
        )
        ..addFile(
          _f('OEBPS/content.opf', '''
<package><metadata/><manifest>
  <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
</manifest><spine><itemref idref="c1"/></spine></package>'''),
        )
        ..addFile(_f('OEBPS/c1.xhtml', '<html><body>encrypted</body></html>'));
      final dir = Directory.systemTemp.createTempSync('readvibe_epub_drm_');
      addTearDown(() {
        try {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Temp cleanup is best-effort.
        }
      });
      final file = File('${dir.path}/drm.epub')
        ..writeAsBytesSync(ZipEncoder().encode(archive));

      await expectLater(
        parseEpub(
          file.path,
          'drm.epub',
          StorageService(documentsDirectory: dir),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('DRM'),
          ),
        ),
      );
    });

    test('oversized data URI image is ignored before decoding', () async {
      final imagePayload = base64Encode(<int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
      final archive = Archive()
        ..addFile(
          _f('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
        )
        ..addFile(
          _f('OEBPS/content.opf', '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>图片限额</dc:title></metadata>
  <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>'''),
        )
        ..addFile(
          _f(
            'OEBPS/c1.xhtml',
            '''
<html><body><p>保留正文。</p><img src="data:image/png;base64,$imagePayload"/></body></html>''',
          ),
        );
      final dir = Directory.systemTemp.createTempSync('readvibe_epub_data_');
      addTearDown(() {
        try {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Temp cleanup is best-effort on Windows.
        }
      });
      final epubFile = File('${dir.path}/data-image.epub')
        ..writeAsBytesSync(ZipEncoder().encode(archive));

      final book = await parseEpub(
        epubFile.path,
        'data-image.epub',
        StorageService(documentsDirectory: dir),
        limits: const EpubParseLimits(maxSingleImageBytes: 4),
      );

      expect(book.chapters.single.content, contains('保留正文'));
      expect(
        book.chapters.single.epubBlocks.where((block) => block.isImage),
        isEmpty,
      );
    });

    test('inline-wrapped and mixed content is recovered', () async {
      final archive = Archive()
        ..addFile(
          _f('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
        )
        ..addFile(
          _f('OEBPS/content.opf', '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试书</dc:title><dc:creator>作者</dc:creator>
  </metadata>
  <manifest>
    <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="c3.xhtml" media-type="application/xhtml+xml"/>
    <item id="c4" href="c4.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/><itemref idref="c4"/>
  </spine>
</package>'''),
        )
        ..addFile(
          _bytes('OEBPS/cover.png', <int>[
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
          ]),
        )
        ..addFile(
          _f('OEBPS/c1.xhtml', '''
<html><head><title>第一章 正常段落</title></head>
<body><h1>第一章 正常段落</h1><p>第一段正文。</p><p>第二段正文。</p></body></html>'''),
        )
        ..addFile(
          _f('OEBPS/c2.xhtml', '''
<html><head><title>第二章 内联包裹</title></head>
<body><span>这一段被 span 完整包裹。</span><p>块级段落。</p></body></html>'''),
        )
        ..addFile(
          _f('OEBPS/c3.xhtml', '''
<html><head><title>第三章 混合结构</title></head>
<body><div><span>内联开头。</span><p>块级后续。</p></div></body></html>'''),
        )
        ..addFile(
          _f('OEBPS/c4.xhtml', '''
<html><head><title>第四章 行内样式</title></head>
<body><p>前面<b>加粗</b>后面<i>斜体</i>结束。</p></body></html>'''),
        );

      final zipBytes = ZipEncoder().encode(archive);
      final dir = Directory('${Directory.systemTemp.path}/readvibe_epub_test')
        ..createSync(recursive: true);
      final epubFile = File('${dir.path}/test.epub')
        ..writeAsBytesSync(zipBytes);
      final storage = StorageService(documentsDirectory: dir);

      final book = await parseEpub(epubFile.path, 'test.epub', storage);
      expect(book.title, '测试书');
      expect(book.coverImagePath, isNotNull);
      expect(File(book.coverImagePath!).existsSync(), isTrue);
      expect(book.chapters.length, 4);
      expect(book.chapters[0].content, contains('第二段正文。'));
      expect(book.chapters[1].content, contains('这一段被 span 完整包裹。'));
      expect(book.chapters[1].content, contains('块级段落。'));
      expect(book.chapters[1].epubBlocks.where((b) => b.isText).length, 2);
      expect(book.chapters[2].content, contains('内联开头。'));
      expect(book.chapters[2].content, contains('块级后续。'));
      expect(book.chapters[3].content, contains('前面加粗后面斜体结束。'));
      expect(
        book.chapters[3].epubBlocks.first.runs.any(
          (r) => r.text == '加粗' && r.style.fontWeight >= 700,
        ),
        isTrue,
      );

      try {
        dir.deleteSync(recursive: true);
      } on Object {
        // Temp cleanup is best-effort; a locked file must not fail the test.
      }
    });

    test('book model round-trips through json', () {
      final book = Book(
        id: 'txt_1',
        title: '样书',
        format: BookFormat.txt,
        chapters: const [Chapter(index: 0, title: '全文', content: '内容')],
        importDate: DateTime(2026, 1, 1),
        fileSize: 10,
        wordCount: 2,
      );
      final restored = Book.fromJson(book.toJson(), book.chapters);
      expect(restored.title, '样书');
      expect(restored.chapterCount, 1);
      expect(restored.wordCount, 2);
    });
  });
}
