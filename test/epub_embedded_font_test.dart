import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/services/epub_parser.dart';
import 'package:readvibe/services/storage_service.dart';

ArchiveFile _file(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('EPUB extracts local TTF font-face and preserves its family', () async {
    final archive = Archive()
      ..addFile(
        _file(
          'META-INF/container.xml',
          '''
<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>''',
        ),
      )
      ..addFile(
        _file(
          'OEBPS/content.opf',
          '''
<package><metadata/><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>''',
        ),
      )
      ..addFile(
        _file(
          'OEBPS/c1.xhtml',
          '''
<html><head><style>@font-face { font-family: "Publisher Serif"; src: url(fonts/publisher.ttf); } p { font-family: "Publisher Serif"; }</style></head><body><p>内嵌字体正文</p></body></html>''',
        ),
      )
      ..addFile(
        ArchiveFile('OEBPS/fonts/publisher.ttf', 8, <int>[
          0,
          1,
          0,
          0,
          0,
          1,
          0,
          0,
        ]),
      );
    final directory = Directory.systemTemp.createTempSync(
      'readvibe_epub_font_',
    );
    addTearDown(() {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Temp cleanup is best-effort on Windows.
      }
    });
    final input = File('${directory.path}/font.epub')
      ..writeAsBytesSync(ZipEncoder().encode(archive));

    final book = await parseEpub(
      input.path,
      'font.epub',
      StorageService(documentsDirectory: directory),
    );

    expect(book.embeddedFonts, hasLength(1));
    expect(File(book.embeddedFonts.values.single).existsSync(), isTrue);
    expect(
      book.chapters.single.epubBlocks.single.style.fontFamily,
      book.embeddedFonts.keys.single,
    );
  });
}
