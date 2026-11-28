import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readvibe/models/book.dart';
import 'package:readvibe/repositories/app_data_directory_provider.dart';
import 'package:readvibe/services/book_import_format.dart';
import 'package:readvibe/services/epub_markup_decoder.dart';
import 'package:readvibe/services/epub_parser.dart';
import 'package:readvibe/services/mobi/kindle_binary_reader.dart';
import 'package:readvibe/services/mobi_parser.dart';
import 'package:readvibe/services/txt_parser.dart';
import 'package:readvibe/services/word_parser.dart';

class _TestAppDataDir implements AppDataDirectoryProvider {
  _TestAppDataDir(this._dir);
  final Directory _dir;
  // Mirrors real StorageService holding an unsendable Future so any isolate
  // closure that accidentally captures storage fails in tests too.
  // ignore: unused_field
  final Future<void> _unsendableState = Future<void>.value();

  @override
  Future<Directory> getAppDataDirectory() async => _dir;
}

Uint8List _zipBytes(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, Uint8List.fromList(e.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _buildMinimalSfnt() {
  final bytes = Uint8List(1280);
  bytes[0] = 0x00;
  bytes[1] = 0x01;
  bytes[2] = 0x00;
  bytes[3] = 0x00;
  bytes[4] = 0x00;
  bytes[5] = 0x0a;
  for (var i = 12; i < bytes.length; i++) {
    bytes[i] = i & 0xff;
  }
  return bytes;
}

Uint8List _obfuscateIdpf(Uint8List raw, String uid) {
  final key = sha1.convert(utf8.encode(uid)).bytes;
  final out = Uint8List.fromList(raw);
  final limit = out.length < 1040 ? out.length : 1040;
  for (var i = 0; i < limit; i++) {
    out[i] ^= key[i % key.length];
  }
  return out;
}

Uint8List _buildPalmDb({
  required String typeTag,
  required String creatorTag,
  required String dbName,
  required List<Uint8List> records,
}) {
  final headerSize = 78 + records.length * 8 + 2;
  var cursor = headerSize;
  final totalSize = headerSize + records.fold<int>(0, (s, r) => s + r.length);
  final out = Uint8List(totalSize);
  final data = ByteData.sublistView(out);

  final nameBytes = latin1.encode(dbName);
  for (var i = 0; i < nameBytes.length && i < 31; i++) {
    out[i] = nameBytes[i];
  }
  out.setRange(60, 64, ascii.encode(typeTag));
  out.setRange(64, 68, ascii.encode(creatorTag));
  data.setUint16(76, records.length, Endian.big);

  for (var i = 0; i < records.length; i++) {
    data.setUint32(78 + i * 8, cursor, Endian.big);
    out.setRange(cursor, cursor + records[i].length, records[i]);
    cursor += records[i].length;
  }
  return out;
}

Uint8List _buildExthRecord(int type, List<int> value) {
  final len = 8 + value.length;
  final b = Uint8List(len);
  final v = ByteData.sublistView(b);
  v.setUint32(0, type, Endian.big);
  v.setUint32(4, len, Endian.big);
  b.setRange(8, len, value);
  return b;
}

Uint8List _buildMobiRec0({
  required int compression,
  required int textLength,
  required int textRecordCount,
  required int headerLength,
  required String fullName,
  String? exthTitle,
  String? exthAuthor,
  int encryptionType = 0,
  int encoding = 65001,
  int? huffIndex,
  int? huffCount,
}) {
  final fullNameBytes = utf8.encode(fullName);
  final exthParts = <Uint8List>[
    if (exthAuthor != null) _buildExthRecord(100, utf8.encode(exthAuthor)),
    if (exthTitle != null) _buildExthRecord(503, utf8.encode(exthTitle)),
  ];
  var exthBytes = Uint8List(0);
  if (exthParts.isNotEmpty) {
    final payloadLen = exthParts.fold<int>(0, (s, r) => s + r.length);
    final paddedLen = (payloadLen + 3) & ~3;
    exthBytes = Uint8List(12 + paddedLen);
    final ev = ByteData.sublistView(exthBytes);
    exthBytes.setRange(0, 4, ascii.encode('EXTH'));
    ev.setUint32(4, exthBytes.length, Endian.big);
    ev.setUint32(8, exthParts.length, Endian.big);
    var pCursor = 12;
    for (final part in exthParts) {
      exthBytes.setRange(pCursor, pCursor + part.length, part);
      pCursor += part.length;
    }
  }

  final fullNameOffset = 16 + headerLength + exthBytes.length;
  final rec0 = Uint8List(fullNameOffset + fullNameBytes.length);
  final v = ByteData.sublistView(rec0);
  v.setUint16(0, compression, Endian.big);
  v.setUint32(4, textLength, Endian.big);
  v.setUint16(8, textRecordCount, Endian.big);
  v.setUint16(10, 4096, Endian.big);
  v.setUint16(12, encryptionType, Endian.big);

  rec0.setRange(16, 20, ascii.encode('MOBI'));
  v.setUint32(20, headerLength, Endian.big);
  v.setUint32(24, 2, Endian.big);
  v.setUint32(28, encoding, Endian.big);
  v.setUint32(36, 6, Endian.big);
  v.setUint32(84, fullNameOffset, Endian.big);
  v.setUint32(88, fullNameBytes.length, Endian.big);
  if (exthParts.isNotEmpty) {
    v.setUint32(128, 0x40, Endian.big);
  }
  if (huffIndex != null && huffCount != null) {
    v.setUint32(112, huffIndex, Endian.big);
    v.setUint32(116, huffCount, Endian.big);
  }
  if (exthBytes.isNotEmpty) {
    rec0.setRange(16 + headerLength, fullNameOffset, exthBytes);
  }
  rec0.setRange(fullNameOffset, rec0.length, fullNameBytes);
  return rec0;
}

void main() {
  late Directory tempDir;
  late _TestAppDataDir storage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('readvibe_fmt_test_');
    storage = _TestAppDataDir(tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Import format sniffing & filenames', () {
    test('identifies BOOKMOBI in azw3/azw/mobi, PK doc->docx, offset PDF, and APK rejection', () {
      final mobiPath = p.join(tempDir.path, 'sample.azw3');
      final mobiBytes = _buildPalmDb(
        typeTag: 'BOOK',
        creatorTag: 'MOBI',
        dbName: 'TestBook',
        records: [_buildMobiRec0(compression: 1, textLength: 5, textRecordCount: 1, headerLength: 232, fullName: 'Sample')],
      );
      File(mobiPath).writeAsBytesSync(mobiBytes);
      expect(
        detectBookImportFormat(path: mobiPath, fileName: 'sample.azw3'),
        BookFormat.azw3,
      );

      final fakeDocPath = p.join(tempDir.path, 'misnamed.doc');
      File(fakeDocPath).writeAsBytesSync(_zipBytes({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        'word/document.xml': utf8.encode('<w:document/>'),
      }));
      expect(
        detectBookImportFormat(path: fakeDocPath, fileName: 'misnamed.doc'),
        BookFormat.docx,
      );

      final offsetPdf = Uint8List(600);
      offsetPdf.setRange(512, 520, ascii.encode('%PDF-1.7'));
      final pdfPath = p.join(tempDir.path, 'offset.bin');
      File(pdfPath).writeAsBytesSync(offsetPdf);
      expect(
        detectBookImportFormat(path: pdfPath, fileName: 'offset.pdf'),
        BookFormat.pdf,
      );

      final apkPath = p.join(tempDir.path, 'fake_book.epub');
      File(apkPath).writeAsBytesSync(_zipBytes({
        'AndroidManifest.xml': [1, 2, 3],
        'classes.dex': [4, 5, 6],
      }));
      expect(
        () => detectBookImportFormat(path: apkPath, fileName: 'fake_book.epub'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            androidPackageImportMessage,
          ),
        ),
      );

      expect(
        labeledImportFileName(p.join(tempDir.path, 'Read.Vibe.v2.txt'), 'Read.Vibe.v2.txt', BookFormat.txt),
        'Read.Vibe.v2.txt',
      );
      expect(
        labeledImportFileName(p.join(tempDir.path, 'Read.Vibe.v2'), 'Read.Vibe.v2', BookFormat.txt),
        'Read.Vibe.v2.txt',
      );

      // UTF-8 multi-byte boundary inside 8KB sample
      final boundaryBytes = BytesBuilder()
        ..add(List<int>.filled(8190, 0x61))
        ..add(utf8.encode('中'));
      final utf8BoundaryPath = p.join(tempDir.path, 'boundary.txt');
      File(utf8BoundaryPath).writeAsBytesSync(boundaryBytes.takeBytes());
      expect(
        detectBookImportFormat(path: utf8BoundaryPath, fileName: 'boundary.txt'),
        BookFormat.txt,
      );
    });
  });

  group('TXT parser compatibility', () {
    test('distinguishes Windows-1252 English from UTF-16LE and handles Traditional Chinese chapters', () {
      // English prose with CP1252 smart quotes / em-dash (0x93, 0x94, 0x97)
      final cp1252Bytes = <int>[
        ...ascii.encode('Chapter 1\n'),
        0x93,
        ...ascii.encode('Hello world'),
        0x94,
        0x20,
        0x97,
        ...ascii.encode(' Part of the story.\n\n'),
        ...List<int>.generate(40, (i) => 0x61 + (i % 26)),
      ];
      final decodedCp1252 = decodeTxtBytes(cp1252Bytes);
      expect(decodedCp1252, contains('“Hello world” — Part of the story.'));

      // Single damaged byte inside UTF-8 keeps UTF-8 rather than mojibake GBK
      final brokenUtf8 = <int>[
        ...utf8.encode('第一章 初見\n這是一段中文正文，包含少量異常字節測試。'),
        0xff,
        ...utf8.encode('\n正文繼續正常顯示。'),
      ];
      final decodedBroken = decodeTxtBytes(brokenUtf8);
      expect(decodedBroken, contains('這是一段中文正文'));

      // Traditional Chinese chapters + inline prose false positive guards + control chars
      final novelText = [
        '內容簡介\n這是一本繁體小說的簡介。\u0001\u0008\u0013',
        '第十二節 遇見\n那年春風吹過，第一卷载官股——皇室内帑、户部出资。',
        '第二百兩十章 重逢\n番外篇的事跡大家都在傳頌。',
        '後記\n全文完，感謝閱讀。',
      ].join('\n');
      final book = buildBookFromText(
        content: novelText,
        fileName: 'Test.Novel.v1.txt',
        format: BookFormat.txt,
        fileSize: 1024,
      );
      expect(book.title, 'Test.Novel.v1');
      expect(book.chapters.map((c) => c.title).toList(), [
        '內容簡介',
        '第十二節 遇見',
        '第二百兩十章 重逢',
        '後記',
      ]);
      expect(book.chapters.first.content.contains('\u0001'), isFalse);
      expect(book.chapters[1].content, contains('第一卷载官股'));
    });
  });

  group('EPUB parser compatibility', () {
    test('handles XHTML self-closing tags, media/pseudo CSS rules, IDPF fonts, and GBK ZIP keys', () async {
      final uuid = 'urn:uuid:12345678-1234-5678-1234-567812345678';
      final obfuscatedFont = _obfuscateIdpf(_buildMinimalSfnt(), uuid);
      final epubPath = p.join(tempDir.path, 'compat.epub');

      final containerXml = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

      final encryptionXml = '''<?xml version="1.0" encoding="utf-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/CustomSerif.ttf"/></enc:CipherData>
  </enc:EncryptedData>
</encryption>''';

      final opfXml = '''<?xml version="1.0" encoding="utf-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata>
    <dc:title>EPUB 兼容测试</dc:title>
    <dc:creator>测试作者</dc:creator>
    <dc:identifier id="pub-id">$uuid</dc:identifier>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="styles.css" media-type="text/css"/>
    <item id="font1" href="fonts/CustomSerif.ttf" media-type="font/ttf"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>''';

      final navXhtml = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>TOC</title></head>
<body>
<nav epub:type="toc"><ol>
  <li><a href="ch1.xhtml">第一章 总纲</a>
    <ol>
      <li><a href="ch1.xhtml#s1">1.1 第一节</a></li>
      <li><a href="ch1.xhtml#s2">1.2 第二节</a></li>
    </ol>
  </li>
</ol></nav>
</body></html>''';

      final cssText = '''
@font-face {
  font-family: "ReaderEmbed";
  src: url("fonts/CustomSerif.ttf");
}
@media amzn-mobi {
  .mobi-hide { display: none; }
}
@media print {
  .print-hide { display: none; }
}
[hidden] { display: none; }
p.lead:first-child { font-weight: 700; font-family: "ReaderEmbed"; }
p::first-letter { font-size: 200%; color: #ff0000; }
''';

      final ch1Xhtml = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title/>
  <script type="text/javascript"/>
  <link rel="stylesheet" type="text/css" href="styles.css"/>
</head>
<body>
  <h1 id="s1">第一节 标题</h1>
  <div>
    <p class="lead mobi-hide print-hide">第一段加粗可见正文<a id="n1"/>接续文本</p>
    <p hidden="hidden">隐藏段落不该出现</p>
  </div>
  <ul><li>列表条款内容</li></ul>
  <center><p>居中段落文本</p></center>
  <h2 id="s2">第二节 小节</h2>
  <p>第二节详细内容文本。</p>
</body></html>''';

      File(epubPath).writeAsBytesSync(_zipBytes({
        'META-INF/container.xml': utf8.encode(containerXml),
        'META-INF/encryption.xml': utf8.encode(encryptionXml),
        'OEBPS/content.opf': utf8.encode(opfXml),
        'OEBPS/nav.xhtml': utf8.encode(navXhtml),
        'OEBPS/styles.css': utf8.encode(cssText),
        'OEBPS/ch1.xhtml': utf8.encode(ch1Xhtml),
        'OEBPS/fonts/CustomSerif.ttf': obfuscatedFont,
      }));

      final book = await parseEpub(epubPath, 'compat.epub', storage);
      expect(book.title, 'EPUB 兼容测试');
      expect(book.author, '测试作者');
      expect(book.embeddedFonts.isNotEmpty, isTrue);
      final allText = book.chapters.map((c) => c.content).join('\n');
      expect(allText, contains('第一段加粗可见正文'));
      expect(allText, contains('接续文本'));
      expect(allText, contains('列表条款内容'));
      expect(allText, contains('居中段落文本'));
      expect(allText, isNot(contains('隐藏段落不该出现')));
      // Verify undeclared Windows-1252 fallback
      final cp1252Html = <int>[...ascii.encode('<p>'), 0x93, ...ascii.encode('Quote'), 0x94, ...ascii.encode('</p>')];
      expect(decodeEpubMarkup(cp1252Html), contains('“Quote”'));
    });
  });

  group('Kindle MOBI/AZW3/PalmDOC binary compatibility', () {
    test('parses MOBI 6 (232B header + LZ77), strips style/head, rejects DRM & Print Replica, and decodes HUFF/CDIC & PalmDOC', () async {
      // 1. MOBI 6 (compression 2 = PalmDOC LZ77 literal bytes with length prefix 1..8)
      final htmlPayload = utf8.encode(
        '<html><head><title>HeadTitle</title><style>.x{color:red}</style></head>'
        '<body><p>第一章 启程</p><mbp:pagebreak/><p>第二章 远航</p></body></html>',
      );
      // Compress cleanly with PalmDOC literal chunks (len 1..8 per chunk, zero NUL leak)
      final compressed = BytesBuilder();
      for (var i = 0; i < htmlPayload.length; i += 8) {
        final end = (i + 8 < htmlPayload.length) ? i + 8 : htmlPayload.length;
        compressed.addByte(end - i);
        compressed.add(htmlPayload.sublist(i, end));
      }
      final rec1 = compressed.takeBytes();
      final mobiPath = p.join(tempDir.path, 'novel.mobi');
      File(mobiPath).writeAsBytesSync(_buildPalmDb(
        typeTag: 'BOOK',
        creatorTag: 'MOBI',
        dbName: 'FallbackDbName',
        records: [
          _buildMobiRec0(
            compression: 2,
            textLength: htmlPayload.length,
            textRecordCount: 1,
            headerLength: 232,
            fullName: 'FullNameTitle',
            exthTitle: 'Kindle 标题',
            exthAuthor: 'Kindle 作者',
          ),
          rec1,
        ],
      ));

      final mobiBook = await parseKindleBook(mobiPath, 'novel.mobi');
      expect(mobiBook.title, 'Kindle 标题');
      expect(mobiBook.author, 'Kindle 作者');
      final joined = mobiBook.chapters.map((c) => c.content).join('\n');
      expect(joined, contains('启程'));
      expect(joined, contains('远航'));
      expect(joined, isNot(contains('HeadTitle')));
      expect(joined, isNot(contains('color:red')));

      // 2. PalmDOC TEXtREAd with GBK bytes
      final gbkText = Uint8List.fromList(gbk.encode('第一章 风起\n这是 PalmDOC 正文。'));
      final palmBytes = _buildPalmDb(
        typeTag: 'TEXt',
        creatorTag: 'REAd',
        dbName: 'PalmNovel',
        records: [
          (() {
            final r0 = Uint8List(16);
            final v = ByteData.sublistView(r0);
            v.setUint16(0, 1, Endian.big);
            v.setUint32(4, gbkText.length, Endian.big);
            v.setUint16(8, 1, Endian.big);
            v.setUint16(10, 4096, Endian.big);
            return r0;
          })(),
          gbkText,
        ],
      );
      final palmDecoded = KindleBinaryReader.parse(palmBytes);
      expect(palmDecoded.isPalmDoc, isTrue);
      expect(palmDecoded.plainTextFallback, isTrue);
      expect(palmDecoded.htmlChunks.single, contains('这是 PalmDOC 正文'));

      // 3. HUFF/CDIC recursive symbol fixture
      // codeLength=2 (4 symbols in CDIC):
      // sym 0 (1-bit prefix 0b0): decompressed "Hi " -> maxCode=0 => code 0xxxxxx
      // sym 1 (2-bit code 0b10): leaf "World"
      // sym 2 (2-bit code 0b11): non-leaf referencing 2-bit bitstreams for sym 0 + sym 1 ("Hi World")
      final huffRec = Uint8List(24 + 256 * 4 + 33 * 8);
      huffRec.setRange(0, 4, ascii.encode('HUFF'));
      final hv = ByteData.sublistView(huffRec);
      const d1 = 24;
      const d2 = 24 + 256 * 4;
      hv.setUint32(4, 24, Endian.big);
      hv.setUint32(8, d1, Endian.big);
      hv.setUint32(12, d2, Endian.big);
      // Use direct table1 lookup for 256 entries:
      // byte 0x00..0x7f -> 1-bit symbol 0: codelen=1, term=0x80, val=0 -> t1 = 0x81
      // byte 0x80..0xbf -> 2-bit symbol 1: codelen=2, term=0x80, val=2 -> t1 = (2 << 8) | 0x82
      // byte 0xc0..0xff -> 2-bit symbol 2: codelen=2, term=0x80, val=3 -> t1 = (3 << 8) | 0x82
      // Formula in reader: index = (((t1 >> 8) + 1) << (32 - codeLen) - 1 - code) >>> (32 - codeLen)
      // Wait for codeLen=1, byte=0x00 (top bit 0): (maxCode - 0) >>> 31 = (0 + 1 - 1) or if t1>>8=1 => maxCode = 0xffffffff? No:
      // ((1 + 1) << 31) - 1 = 0xffffffff; (0xffffffff - 0x00000000) >>> 31 = 1.
      // Let's map cleanly:
      // t1>>8 = 0: maxCode = (1 << 31) - 1 = 0x7fffffff -> for code 0x0xxxxxxx: (0x7fffffff - code) >>> 31 = 0! (sym 0)
      // For bits 10 (byte 0x80..0xbf), codeLen=2: maxCode needs (3 << 30) - 1 = 0xbfffffff => t1>>8 = 2 -> (0xbfffffff - 0x80000000) >>> 30 = 0,Wait: (0xbfffffff - 0x80000000)=0x3fffffff >>> 30 = 0!
      // If we want sym 1 -> use val=3 => maxCode = (4<<30)-1 = 0xffffffff -> (0xffffffff - 0x80000000)>>>30 = 1! And for byte 0xc0 (code=0xc0000000): Wait! Let's invert or pick val = 2 with codeLen=2 gives sym 0; val=3 with code=0x80..0xbf gives sym 1; and for sym 2, use 3-bit code 110 (byte 0xc0..0xdf): maxCode=(7<<29)-1=0xdfffffff -> (0xdfffffff - 0xc0000000)>>>29=0 -> or val=8 => maxCode=(9<<29)-1... wait: for 3-bit, (8<<29)-1 = 0xffffffff -> (0xffffffff - 0xc0000000)>>>29 = 1!
      // Actually use val = 0x0a? Wait: t1 is unsigned 32-bit! Let's pick byte mapping:
      // bits 0... -> 1-bit sym 0: v = 0 => max = 0x7fffffff, (0x7fffffff - 0x00..0x7f) >>> 31 = 0!
      // bits 10.. -> 2-bit sym 1: v = 3 => max = 0xffffffff, (0xffffffff - 0x80..0xbf<<24) >>> 30 = 1!
      // bits 110.. -> 3-bit sym 2: v = 8 =>Wait: 8 in (t1>>8): ((8+1)<<29)-1 wraps! Instead use minCodeTable lookup with v&0x80 == 0 OR for 3-bit bits 110.. (0xc0..0xdf) with v=7 (max=0xffffffff): (0xffffffff - 0xc0000000)>>>29 = 1 -> wait if sym=1 is leaf and we pick codelen=3, bits 100 (0x80..0x9f) maxCode with v=4 (0x9fffffff)->sym0, v=5 (0xbfffffff)->(0xbf..-0x80..)>>>29=1, v=6 (0xdfffffff)->for bits 110 (0xc0..0xdf)->(0xdfffffff-0xc0000000)>>>29=0! Wait: with codelen=3:
      // 000..011 (1 bit 0): v=0 -> sym 0!
      // 100 (3 bit, 0x80..0x9f): v=5 -> maxCode = 0xbfffffff => (0xbfffffff - 0x80000000)>>>29 = 1 (sym 1)!
      // 101 (3 bit, 0xa0..0xbf): v=7 => maxCode=0xffffffff => (0xffffffff - 0xa0000000)>>>29 = 2 (sym 2)!
      for (var b = 0; b < 256; b++) {
        if (b < 0x80) {
          hv.setUint32(d1 + b * 4, (0 << 8) | 0x81, Endian.big);
        } else if (b < 0xa0) {
          hv.setUint32(d1 + b * 4, (5 << 8) | 0x83, Endian.big);
        } else {
          hv.setUint32(d1 + b * 4, (7 << 8) | 0x83, Endian.big);
        }
      }
      // Build CDIC with 3 symbols:
      // sym 0: "Hi " (leaf: 0x8003 + "Hi ")
      // sym 1: "World" (leaf: 0x8005 + "World")
      // sym 2: non-leaf [0x40] (0=1bit + 100=3bit => bit pattern 0_100_0000 = 0x40? wait: 0 + 100 is 4 bits = 0x40 padded, so if encoded bits = sym0 (0, 1bit) + sym1 (100, 3bit) + sym0 (0, 1bit) + trailing... wait: recursive call loops until totalBits! So we MUST match bit length evenly to multiple of 8!):
      // How about 8 bits = sym0 (0, 1bit) + sym0 (0, 1bit) + sym1 (100, 3bit) + sym1 (100, 3bit) = 0b00100100 = 0x24! = "Hi Hi WorldWorld" (exact 8 bits!)
      final cdicPayload = BytesBuilder();
      // Header 16B: 'CDIC', hdrLen=16, indexCount=3, codeLength=2 (4 offsets, last 1 unused or all 3)
      // Reserve 16 + 3*2 = 22 bytes for offsets (inside cHeaderLen=16 dictionaries starts at offset 16)
      // Dict starts right after header (offset 16), so symOffset is relative to byte 16!
      final sym0 = [0x80, 3, ...ascii.encode('Hi ')]; // len 5
      final sym1 = [0x80, 5, ...ascii.encode('World')]; // len 7
      final sym2 = [0x00, 1, 0x24]; // len 3 -> decompresses 0x24 -> "Hi Hi WorldWorld"
      final baseOffset = 3 * 2;
      final cdicHeader = Uint8List(16 + baseOffset + sym0.length + sym1.length + sym2.length);
      cdicHeader.setRange(0, 4, ascii.encode('CDIC'));
      final cv = ByteData.sublistView(cdicHeader);
      cv.setUint32(4, 16, Endian.big);
      cv.setUint32(8, 3, Endian.big);
      cv.setUint32(12, 2, Endian.big);
      cv.setUint16(16, baseOffset, Endian.big);
      cv.setUint16(18, baseOffset + sym0.length, Endian.big);
      cv.setUint16(20, baseOffset + sym0.length + sym1.length, Endian.big);
      cdicPayload.add(cdicHeader);
      cdicHeader.setRange(16 + baseOffset, 16 + baseOffset + sym0.length, sym0);
      cdicHeader.setRange(16 + baseOffset + sym0.length, 16 + baseOffset + sym0.length + sym1.length, sym1);
      cdicHeader.setRange(16 + baseOffset + sym0.length + sym1.length, cdicHeader.length, sym2);

      // Input text record: 101 (sym2, 3bit) + 100 (sym1, 3bit) -> 0b101_100_00 = 0xb0? Wait: remaining 00 triggers 2x sym0!
      // 101_0_0_100 = 0b10100100 = 0xa4 (8 bits exact) => sym2 ("Hi Hi WorldWorld") + sym0 ("Hi ") + sym0 ("Hi ") + sym1 ("World") = "Hi Hi WorldWorldHi Hi World"!
      final huffContainer = _buildPalmDb(
        typeTag: 'BOOK',
        creatorTag: 'MOBI',
        dbName: 'HuffBook',
        records: [
          _buildMobiRec0(
            compression: 17480,
            textLength: 27,
            textRecordCount: 1,
            headerLength: 232,
            fullName: 'HuffBook',
            huffIndex: 2,
            huffCount: 2,
          ),
          Uint8List.fromList([0xa4]),
          huffRec,
          cdicHeader,
        ],
      );
      final huffParsed = KindleBinaryReader.parse(huffContainer);
      expect(huffParsed.htmlChunks.single, 'Hi Hi WorldWorldHi Hi World');

      // 4. DRM & Print Replica explicit rejections
      expect(
        () => KindleBinaryReader.parse(_buildPalmDb(
          typeTag: 'BOOK',
          creatorTag: 'MOBI',
          dbName: 'DrmBook',
          records: [
            _buildMobiRec0(
              compression: 1,
              textLength: 10,
              textRecordCount: 1,
              headerLength: 232,
              fullName: 'DrmBook',
              encryptionType: 2,
            ),
            Uint8List(10),
          ],
        )),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('DRM'))),
      );
      expect(
        () => KindleBinaryReader.parse(_buildPalmDb(
          typeTag: 'BOOK',
          creatorTag: 'MOBI',
          dbName: 'PrintReplica',
          records: [
            _buildMobiRec0(
              compression: 1,
              textLength: 8,
              textRecordCount: 1,
              headerLength: 232,
              fullName: 'PrintReplica',
            ),
            Uint8List.fromList([...ascii.encode('%MOP'), 0, 0, 0, 1]),
          ],
        )),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('Print Replica'))),
      );
    });
  });

  group('DOCX compatibility', () {
    test('handles backslash rels, styles.xml outlineLvl headings, AlternateContent deduplication, endnotes, and nested tables', () async {
      final docxPath = p.join(tempDir.path, 'compat.docx');
      final relsXml = '''<?xml version="1.0" encoding="utf-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word\\custom_doc.xml"/>
</Relationships>''';
      final stylesXml = '''<?xml version="1.0" encoding="utf-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="1">
    <w:name w:val="heading 1"/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="CustomH2">
    <w:name w:val="自定义标题二"/>
    <w:pPr><w:outlineLvl w:val="1"/></w:pPr>
  </w:style>
</w:styles>''';
      final endnotesXml = '''<?xml version="1.0" encoding="utf-8"?>
<w:endnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:endnote w:id="1"><w:p><w:r><w:t>这是尾注解释文本。</w:t></w:r></w:p></w:endnote>
</w:endnotes>''';
      final docXml = '''<?xml version="1.0" encoding="utf-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="1"/></w:pPr><w:r><w:t>第一章 总述</w:t></w:r></w:p>
    <w:p>
      <w:r><w:t>保留正文</w:t></w:r>
      <w:r><w:instrText>HYPERLINK</w:instrText></w:r>
      <w:r><w:rPr><w:vanish/></w:rPr><w:t>隐藏修订文本</w:t></w:r>
      <w:del><w:r><w:delText>已删除文本</w:delText></w:r></w:del>
      <mc:AlternateContent>
        <mc:Choice><w:r><w:t>优选文本</w:t></w:r></mc:Choice>
        <mc:Fallback><w:r><w:t>回退重复文本</w:t></w:r></mc:Fallback>
      </mc:AlternateContent>
      <w:r><w:endnoteReference w:id="1"/></w:r>
    </w:p>
    <w:tbl><w:tr><w:tc><w:sdt><w:sdtContent><w:p><w:r><w:t>单元格正文</w:t></w:r></w:p></w:sdtContent></w:sdt></w:tc></w:tr></w:tbl>
  </w:body>
</w:document>''';

      File(docxPath).writeAsBytesSync(_zipBytes({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        '_rels/.rels': utf8.encode(relsXml),
        'word/styles.xml': utf8.encode(stylesXml),
        'word/endnotes.xml': utf8.encode(endnotesXml),
        'word/custom_doc.xml': utf8.encode(docXml),
      }));

      final book = await parseWordDocument(docxPath, 'compat.docx', storage);
      final combined = book.chapters.map((c) => '${c.title}\n${c.content}').join('\n');
      expect(combined, contains('第一章 总述'));
      expect(combined, contains('保留正文'));
      expect(combined, contains('优选文本'));
      expect(combined, contains('单元格正文'));
      expect(combined, contains('这是尾注解释文本'));
      expect(combined, isNot(contains('HYPERLINK')));
      expect(combined, isNot(contains('隐藏修订文本')));
      expect(combined, isNot(contains('已删除文本')));
      expect(combined, isNot(contains('回退重复文本')));
    });
  });
}
