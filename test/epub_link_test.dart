import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/epub_parser.dart';
import 'package:readvibe/services/storage/chapter_payload_codec.dart';
import 'package:readvibe/services/storage_service.dart';

ArchiveFile _file(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

const _container =
    '<container><rootfiles>'
    '<rootfile full-path="OEBPS/content.opf"/>'
    '</rootfiles></container>';

const _opf =
    '<package><metadata/><manifest>'
    '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="c2" href="notes.xhtml" media-type="application/xhtml+xml"/>'
    '</manifest><spine>'
    '<itemref idref="c1"/><itemref idref="c2"/>'
    '</spine></package>';

const _chapterOne =
    '<html><body>'
    '<p>正文一段落，后面跟着一个注号'
    '<a href="notes.xhtml#fn1">[1]</a>。</p>'
    '<p>另一段落里有一个同文件内的引用'
    '<a href="#tail">见后文</a>。</p>'
    '<p>发行方还留了一个站外地址'
    '<a href="https://example.com/book">官网</a>。</p>'
    '<p id="tail">这是第一章末尾被引用的位置。</p>'
    '</body></html>';

const _notes =
    '<html><body>'
    '<p id="fn1">注一：这是一条很短的脚注正文。</p>'
    '<p id="fn2">注二：另一条脚注。</p>'
    '</body></html>';

EpubTextRun _runWithLink(Chapter chapter, int blockIndex) =>
    chapter.epubBlocks[blockIndex].runs.firstWhere((run) => run.link != null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Book> parseFixture() async {
    final archive = Archive()
      ..addFile(_file('META-INF/container.xml', _container))
      ..addFile(_file('OEBPS/content.opf', _opf))
      ..addFile(_file('OEBPS/c1.xhtml', _chapterOne))
      ..addFile(_file('OEBPS/notes.xhtml', _notes));
    final directory = Directory.systemTemp.createTempSync(
      'readvibe_epub_link_',
    );
    addTearDown(() {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Temp cleanup is best-effort on Windows.
      }
    });
    final input = File('${directory.path}/link.epub')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    return parseEpub(
      input.path,
      'link.epub',
      StorageService(documentsDirectory: directory),
    );
  }

  test('a footnote marker resolves to the note block in another file', () async {
    final book = await parseFixture();
    final target = _runWithLink(book.chapters.first, 0).link!;

    expect(target.chapterIndex, 1);
    expect(target.hasBlock, isTrue);
    expect(
      book.chapters[1].epubBlocks[target.blockIndex].text,
      contains('注一'),
    );
  });

  test('a same-file reference resolves inside its own chapter', () async {
    final book = await parseFixture();
    final target = _runWithLink(book.chapters.first, 1).link!;

    expect(target.chapterIndex, 0);
    expect(
      book.chapters.first.epubBlocks[target.blockIndex].text,
      contains('第一章末尾'),
    );
  });

  test('an external address stays plain text', () async {
    final book = await parseFixture();
    final block = book.chapters.first.epubBlocks[2];

    expect(block.text, contains('官网'));
    expect(block.hasLinks, isFalse);
  });

  test('the marker keeps its own run instead of merging into the sentence', () {
    final block = EpubContentBlock(
      kind: EpubContentBlockKind.text,
      text: '正文[1]。',
      runs: const [
        EpubTextRun(text: '正文', style: EpubContentStyle()),
        EpubTextRun(
          text: '[1]',
          style: EpubContentStyle(),
          link: EpubLinkTarget(chapterIndex: 1, blockIndex: 0),
        ),
        EpubTextRun(text: '。', style: EpubContentStyle()),
      ],
    );

    expect(block.hasLinks, isTrue);
    expect(block.runs[1].link!.chapterIndex, 1);
  });

  test('links and anchor ids survive a payload round trip', () async {
    final book = await parseFixture();
    final restored = decodeChapterPayload(
      encodeChapterPayload(book.chapters.first),
      0,
    );

    final target = _runWithLink(restored, 0).link!;
    expect(target.chapterIndex, 1);
    expect(target.blockIndex, greaterThanOrEqualTo(0));
    expect(restored.epubBlocks[3].anchorIds, contains('tail'));
  });

  test('a damaged link record decodes as no link at all', () {
    final restored = decodeChapterPayload({
      'title': '章',
      'content': '',
      'epubBlocks': [
        {
          'kind': 'text',
          'text': '正文',
          'runs': [
            {'text': '正文', 'link': 'not a map'},
          ],
          'anchorIds': ['ok', 42, ''],
        },
      ],
    }, 0);

    expect(restored.epubBlocks.single.hasLinks, isFalse);
    expect(restored.epubBlocks.single.anchorIds, ['ok']);
  });
}
