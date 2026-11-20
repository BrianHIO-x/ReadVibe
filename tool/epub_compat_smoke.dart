// The fixtures read more clearly as concatenated XML fragments.
// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dart3_big5/big5.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/repositories/app_data_directory_provider.dart';
import 'package:readvibe/services/epub_parser.dart';
import 'package:readvibe/services/storage/chapter_payload_codec.dart';

class _TempStorage implements AppDataDirectoryProvider {
  _TempStorage(this.directory);

  final Directory directory;

  @override
  Future<Directory> getAppDataDirectory() async => directory;
}

final _tempDirs = <Directory>[];
var _passed = 0;
var _failed = 0;
final _failures = <String>[];

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _expectContains(String actual, String expected, String message) {
  if (!actual.contains(expected)) {
    throw StateError(
      message + ': expected "' + expected + '" in "' + actual + '"',
    );
  }
}

ArchiveFile _textFile(String path, String text, {Encoding encoding = utf8}) {
  final bytes = encoding.encode(text);
  return ArchiveFile(path, bytes.length, bytes);
}

ArchiveFile _bytesFile(String path, List<int> bytes) =>
    ArchiveFile(path, bytes.length, bytes);

List<int> _utf16Le(String text) {
  final bytes = <int>[];
  for (final unit in text.codeUnits) {
    bytes.add(unit & 0xff);
    bytes.add((unit >> 8) & 0xff);
  }
  return bytes;
}

String _item(
  String id,
  String href,
  String mediaType, {
  String properties = '',
  String fallback = '',
}) {
  var value =
      '<item id="' +
      id +
      '" href="' +
      href +
      '" media-type="' +
      mediaType +
      '"';
  if (properties.isNotEmpty) value += ' properties="' + properties + '"';
  if (fallback.isNotEmpty) value += ' fallback="' + fallback + '"';
  return value + '/>';
}

String _spineRef(String id, {bool linear = true}) => linear
    ? '<itemref idref="' + id + '"/>'
    : '<itemref idref="' + id + '" linear="no"/>';

String _opf({
  required String title,
  required List<String> manifest,
  required List<String> spine,
  String? toc,
  String version = '3.0',
}) {
  final tocAttribute = toc == null ? '' : ' toc="' + toc + '"';
  return '<?xml version="1.0" encoding="UTF-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="' +
      version +
      '">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>' +
      title +
      '</dc:title><dc:creator>测试作者</dc:creator>'
          '</metadata><manifest>' +
      manifest.join() +
      '</manifest>'
          '<spine' +
      tocAttribute +
      '>' +
      spine.join() +
      '</spine></package>';
}

String _container(List<String> rootfiles) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles>' +
    rootfiles
        .map(
          (path) =>
              '<rootfile full-path="' +
              path +
              '" media-type="application/oebps-package+xml"/>',
        )
        .join() +
    '</rootfiles></container>';

String _chapterHtml(String title, String body) =>
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>' +
    title +
    '</title></head><body>' +
    body +
    '</body></html>';

String _navHtml(String innerOl) =>
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
        '<body><nav epub:type="toc"><ol>' +
    innerOl +
    '</ol></nav></body></html>';

String _ncxXml(String title, String navPoints) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        '<head><meta name="dtb:uid" content="test"/></head>'
        '<docTitle><text>' +
    title +
    '</text></docTitle>'
        '<navMap>' +
    navPoints +
    '</navMap></ncx>';

String _navPoint(String title, String source) =>
    '<navPoint id="n' +
    title.hashCode.abs().toString() +
    '" playOrder="1"><navLabel><text>' +
    title +
    '</text></navLabel><content src="' +
    source +
    '"/></navPoint>';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Archive _baseArchive(
  String opf,
  Map<String, ArchiveFile> files, {
  List<String> rootfiles = const <String>['OEBPS/content.opf'],
}) {
  final archive = Archive()
    ..addFile(_textFile('META-INF/container.xml', _container(rootfiles)))
    ..addFile(_textFile('OEBPS/content.opf', opf));
  for (final entry in files.entries) {
    archive.addFile(entry.value);
  }
  return archive;
}

Future<Book> _parseArchive(
  Archive archive, {
  String fileName = 'book.epub',
}) async {
  final directory = Directory.systemTemp.createTempSync('readvibe_epub_smoke_');
  _tempDirs.add(directory);
  final input = File(directory.path + Platform.pathSeparator + fileName);
  input.writeAsBytesSync(ZipEncoder().encode(archive));
  return parseEpub(input.path, fileName, _TempStorage(directory));
}

EpubTextRun? _firstLink(Chapter chapter) {
  for (final block in chapter.epubBlocks) {
    for (final run in block.runs) {
      if (run.link != null) return run;
    }
  }
  return null;
}

Future<void> _case(String name, Future<void> Function() body) async {
  try {
    await body();
    _passed++;
    stdout.writeln('PASS ' + name);
  } on Object catch (error) {
    _failed++;
    _failures.add(name + ': ' + error.toString());
    stdout.writeln('FAIL ' + name + ': ' + error.toString());
  }
}

Future<void> main() async {
  await _case('basic EPUB imports', () async {
    final archive = _baseArchive(
      _opf(
        title: '基础书',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('第一章', '<p>基础正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.title == '基础书', 'title');
    _expect(book.chapters.length == 1, 'chapter count');
    _expectContains(book.chapters.single.content, '基础正文。', 'chapter text');
  });

  await _case('OPF with an undeclared HTML entity still imports', () async {
    final archive = _baseArchive(
      _opf(
        title: 'Tom &amp; Jerry&nbsp;Book',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('章', '<p>正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(book.title, 'Tom & Jerry', 'entity title');
    _expectContains(book.title, 'Book', 'entity suffix');
  });

  await _case(
    'second container rootfile is used when the first is missing',
    () async {
      final archive = _baseArchive(
        _opf(
          title: '备选包',
          manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
          spine: <String>[_spineRef('c1')],
        ),
        <String, ArchiveFile>{
          'OEBPS/c1.xhtml': _textFile(
            'OEBPS/c1.xhtml',
            _chapterHtml('章', '<p>备选正文。</p>'),
          ),
        },
        rootfiles: <String>['missing.opf', 'OEBPS/content.opf'],
      );
      final book = await _parseArchive(archive);
      _expectContains(book.title, '备选包', 'fallback rootfile');
    },
  );

  await _case('unique case-insensitive ZIP path is found', () async {
    final archive = _baseArchive(
      _opf(
        title: '大小写',
        manifest: <String>[
          _item('c1', 'Text/Chapter1.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/text/chapter1.xhtml': _textFile(
          'OEBPS/text/chapter1.xhtml',
          _chapterHtml('章', '<p>大小写正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(
      book.chapters.single.content,
      '大小写正文。',
      'case-insensitive path',
    );
  });

  await _case('exact ZIP path wins over a folded duplicate', () async {
    final archive = _baseArchive(
      _opf(
        title: '精确优先',
        manifest: <String>[
          _item('c1', 'Text/chapter1.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/Text/chapter1.xhtml': _textFile(
          'OEBPS/Text/chapter1.xhtml',
          _chapterHtml('章', '<p>精确正文。</p>'),
        ),
        'OEBPS/text/chapter1.xhtml': _textFile(
          'OEBPS/text/chapter1.xhtml',
          _chapterHtml('章', '<p>折叠正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(book.chapters.single.content, '精确正文。', 'exact path');
  });

  await _case('ambiguous case-insensitive ZIP paths are not guessed', () async {
    final archive = _baseArchive(
      _opf(
        title: '歧义',
        manifest: <String>[
          _item('c1', 'TEXT/CHAPTER1.XHTML', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/Text/chapter1.xhtml': _textFile(
          'OEBPS/Text/chapter1.xhtml',
          _chapterHtml('章', '<p>甲。</p>'),
        ),
        'OEBPS/text/chapter1.xhtml': _textFile(
          'OEBPS/text/chapter1.xhtml',
          _chapterHtml('章', '<p>乙。</p>'),
        ),
      },
    );
    var failed = false;
    try {
      await _parseArchive(archive);
    } on FormatException {
      failed = true;
    }
    _expect(failed, 'ambiguous path must fail instead of picking a variant');
  });

  await _case('spine linear=no is used when it is all there is', () async {
    final archive = _baseArchive(
      _opf(
        title: '全非线性',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1', linear: false)],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('章', '<p>非线性正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 1, 'fallback chapter count');
    _expectContains(book.chapters.single.content, '非线性正文。', 'non-linear text');
  });

  await _case('linked non-linear notes become a reachable chapter', () async {
    final archive = _baseArchive(
      _opf(
        title: '脚注',
        manifest: <String>[
          _item('c1', 'c1.xhtml', 'application/xhtml+xml'),
          _item('notes', 'notes.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1'), _spineRef('notes', linear: false)],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('第一章', '<p>正文<a href="notes.xhtml#fn1">[1]</a>。</p>'),
        ),
        'OEBPS/notes.xhtml': _textFile(
          'OEBPS/notes.xhtml',
          _chapterHtml('注释', '<p id="fn1">注一正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 2, 'notes chapter count');
    final link = _firstLink(book.chapters.first);
    _expect(link?.link != null, 'footnote link exists');
    _expect(link?.link?.chapterIndex == 1, 'footnote chapter');
    _expect((link?.link?.blockIndex ?? -1) >= 0, 'footnote block');
    _expectContains(book.chapters[1].content, '注一正文。', 'note text');
  });

  await _case('manifest fallback rescues a missing spine item', () async {
    final archive = _baseArchive(
      _opf(
        title: '回退',
        manifest: <String>[
          _item(
            'broken',
            'missing.xhtml',
            'application/xhtml+xml',
            fallback: 'c1',
          ),
          _item('c1', 'c1.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('broken')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('章', '<p>回退正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(book.chapters.single.content, '回退正文。', 'fallback item');
  });

  await _case('nav splits one XHTML with multiple anchors', () async {
    final archive = _baseArchive(
      _opf(
        title: '多锚点',
        manifest: <String>[
          _item('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          _item('book', 'book.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('book')],
      ),
      <String, ArchiveFile>{
        'OEBPS/nav.xhtml': _textFile(
          'OEBPS/nav.xhtml',
          _navHtml(
            '<li><a href="book.xhtml#ch2">第二章</a></li>'
            '<li><a href="book.xhtml#ch1">第一章</a></li>',
          ),
        ),
        'OEBPS/book.xhtml': _textFile(
          'OEBPS/book.xhtml',
          _chapterHtml(
            '整本',
            '<h1 id="ch1">第一章</h1><p>第一章正文。</p>'
                '<h1 id="ch2">第二章</h1><p>第二章正文。</p>',
          ),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 2, 'split chapter count');
    _expect(book.chapters[0].title == '第一章', 'first split title');
    _expect(book.chapters[1].title == '第二章', 'second split title');
    _expectContains(book.chapters[0].content, '第一章正文。', 'first split text');
    _expect(!book.chapters[0].content.contains('第二章正文。'), 'first split stops');
    _expectContains(book.chapters[1].content, '第二章正文。', 'second split text');
  });

  await _case('nested nav gives child chapters a volume title', () async {
    final archive = _baseArchive(
      _opf(
        title: '多层级',
        manifest: <String>[
          _item('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          _item('book', 'book.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('book')],
      ),
      <String, ArchiveFile>{
        'OEBPS/nav.xhtml': _textFile(
          'OEBPS/nav.xhtml',
          _navHtml(
            '<li><span>第一部</span><ol>'
            '<li><a href="book.xhtml#ch1">第一章</a></li>'
            '<li><a href="book.xhtml#ch2">第二章</a></li>'
            '</ol></li>',
          ),
        ),
        'OEBPS/book.xhtml': _textFile(
          'OEBPS/book.xhtml',
          _chapterHtml(
            '整本',
            '<h1 id="ch1">第一章</h1><p>一章。</p>'
                '<h1 id="ch2">第二章</h1><p>二章。</p>',
          ),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 2, 'nested chapter count');
    _expect(book.chapters[0].volumeTitle == '第一部', 'nested volume title');
    _expect(book.chapters[1].volumeTitle == '第一部', 'nested volume title 2');
  });

  await _case('EPUB2 NCX splits and name anchors resolve', () async {
    final archive = _baseArchive(
      _opf(
        title: 'NCX',
        manifest: <String>[
          _item('ncx', 'toc.ncx', 'application/x-dtbncx+xml'),
          _item('c1', 'c1.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1')],
        toc: 'ncx',
        version: '2.0',
      ),
      <String, ArchiveFile>{
        'OEBPS/toc.ncx': _textFile(
          'OEBPS/toc.ncx',
          _ncxXml(
            'NCX',
            _navPoint('第一章', 'c1.xhtml#a') + _navPoint('第二章', 'c1.xhtml#b'),
          ),
        ),
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml(
            '整本',
            '<a name="a"></a><h1>第一章</h1><p>第一段<a href="#b">跳到第二章</a>。</p>'
                '<a name="b"></a><h1>第二章</h1><p>第二段。</p>',
          ),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 2, 'NCX split chapter count');
    final link = _firstLink(book.chapters.first);
    _expect(link?.link?.chapterIndex == 1, 'name anchor chapter');
    _expect((link?.link?.blockIndex ?? -1) == 0, 'name anchor block');
  });

  await _case('GBK-declared XHTML decodes', () async {
    final archive = _baseArchive(
      _opf(
        title: 'GBK',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          '<?xml version="1.0" encoding="gbk"?>'
              '<html><head><title>中文标题</title></head><body><p>中文正文，编码测试。</p></body></html>',
          encoding: gbk,
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(book.chapters.single.title, '中文标题', 'GBK title');
    _expectContains(book.chapters.single.content, '中文正文', 'GBK text');
  });

  await _case('Big5-declared XHTML decodes', () async {
    final archive = _baseArchive(
      _opf(
        title: 'Big5',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          '<?xml version="1.0" encoding="big5"?>'
              '<html><head><title>繁體標題</title></head><body><p>繁體正文，編碼測試。</p></body></html>',
          encoding: _Big5Encoding(),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(book.chapters.single.title, '繁體標題', 'Big5 title');
    _expectContains(book.chapters.single.content, '繁體正文', 'Big5 text');
  });

  await _case('mixed body text between blocks is kept in order', () async {
    final archive = _baseArchive(
      _opf(
        title: '混合文本',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('混合', '开场<p>中间</p>结尾'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    final text = book.chapters.single.content;
    final start = text.indexOf('开场');
    final middle = text.indexOf('中间');
    final end = text.indexOf('结尾');
    _expect(start >= 0, 'leading direct text kept');
    _expect(middle > start, 'middle paragraph kept');
    _expect(end > middle, 'trailing direct text kept');
  });

  await _case(
    'image id attaches to the image block, not the previous text',
    () async {
      final archive = _baseArchive(
        _opf(
          title: '图片锚点',
          manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
          spine: <String>[_spineRef('c1')],
        ),
        <String, ArchiveFile>{
          'OEBPS/c1.xhtml': _textFile(
            'OEBPS/c1.xhtml',
            _chapterHtml(
              '图片',
              '<p>前文<img id="pic" src="Images/pic.png"/>后文</p>'
                  '<p><a href="#pic">看图</a></p>',
            ),
          ),
          'OEBPS/Images/pic.png': _bytesFile('OEBPS/Images/pic.png', _png),
        },
      );
      final book = await _parseArchive(archive);
      final blocks = book.chapters.single.epubBlocks;
      final imageIndex = blocks.indexWhere((block) => block.isImage);
      _expect(imageIndex >= 0, 'image block exists');
      _expect(
        blocks[imageIndex].anchorIds.contains('pic'),
        'image carries its id',
      );
      final link = _firstLink(book.chapters.single);
      _expect(
        link?.link?.blockIndex == imageIndex,
        'link lands on image block',
      );
    },
  );

  await _case('promoting a leading title preserves its anchor id', () async {
    final archive = _baseArchive(
      _opf(
        title: '标题锚点',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          '<html><head><title>第一章</title></head><body>'
              '<div id="top">第一章</div>'
              '<p><a href="#top">回顶部</a></p>'
              '</body></html>',
        ),
      },
    );
    final book = await _parseArchive(archive);
    final blocks = book.chapters.single.epubBlocks;
    _expect(
      blocks.first.anchorIds.contains('top'),
      'promoted heading keeps anchor',
    );
    final link = _firstLink(book.chapters.single);
    _expect(link?.link?.blockIndex == 0, 'link lands on promoted heading');
  });

  await _case('SVG spine page exposes its wrapped raster image', () async {
    final archive = _baseArchive(
      _opf(
        title: 'SVG 页',
        manifest: <String>[_item('page', 'page.svg', 'image/svg+xml')],
        spine: <String>[_spineRef('page')],
      ),
      <String, ArchiveFile>{
        'OEBPS/page.svg': _textFile(
          'OEBPS/page.svg',
          '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">'
              '<title>封面</title>'
              '<image xlink:href="Images/pic.png" width="600" height="800"/>'
              '</svg>',
        ),
        'OEBPS/Images/pic.png': _bytesFile('OEBPS/Images/pic.png', _png),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 1, 'SVG chapter count');
    _expect(
      book.chapters.single.epubBlocks.any((block) => block.isImage),
      'SVG image block',
    );
  });

  await _case(
    'malformed OPF tags are repaired without losing the book',
    () async {
      final archive = _baseArchive(
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
        '<metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">坏包修复</dc:title>'
        '</metadata><manifest>'
        '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml">'
        '</manifest><spine><itemref idref="c1"/></spine>',
        <String, ArchiveFile>{
          'OEBPS/c1.xhtml': _textFile(
            'OEBPS/c1.xhtml',
            _chapterHtml('章', '<p>修复后的正文。</p>'),
          ),
        },
      );
      final book = await _parseArchive(archive);
      _expectContains(book.title, '坏包修复', 'repaired OPF title');
      _expectContains(
        book.chapters.single.content,
        '修复后的正文。',
        'repaired OPF chapter',
      );
    },
  );

  await _case('BOM-less UTF-16LE XHTML decodes', () async {
    final xml =
        '<?xml version="1.0" encoding="utf-16le"?>'
        '<html><head><title>UTF16 标题</title></head>'
        '<body><p>UTF16 正文。</p></body></html>';
    final archive = _baseArchive(
      _opf(
        title: 'UTF16',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _bytesFile('OEBPS/c1.xhtml', _utf16Le(xml)),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(book.chapters.single.title, 'UTF16 标题', 'UTF-16 title');
    _expectContains(book.chapters.single.content, 'UTF16 正文。', 'UTF-16 text');
  });

  await _case('declared Windows-1252 XHTML decodes punctuation', () async {
    const prefix =
        '<?xml version="1.0" encoding="windows-1252"?>'
        '<html><head><title>Legacy</title></head><body><p>It';
    const suffix = 's fine.</p></body></html>';
    final bytes = <int>[...utf8.encode(prefix), 0x92, ...utf8.encode(suffix)];
    final archive = _baseArchive(
      _opf(
        title: 'Windows-1252',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _bytesFile('OEBPS/c1.xhtml', bytes),
      },
    );
    final book = await _parseArchive(archive);
    _expectContains(
      book.chapters.single.content,
      'It’s fine.',
      'cp1252 punctuation',
    );
  });

  await _case('inline SVG image uses its namespaced xlink:href', () async {
    final archive = _baseArchive(
      _opf(
        title: '内联 SVG',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml(
            '图',
            '<p>前文</p><svg xmlns="http://www.w3.org/2000/svg" '
                'xmlns:xlink="http://www.w3.org/1999/xlink">'
                '<image xlink:href="Images/pic.png" width="120" height="80"/>'
                '</svg>',
          ),
        ),
        'OEBPS/Images/pic.png': _bytesFile('OEBPS/Images/pic.png', _png),
      },
    );
    final book = await _parseArchive(archive);
    final image = book.chapters.single.epubBlocks.where(
      (block) => block.isImage,
    );
    _expect(image.length == 1, 'inline SVG image block');
    _expect(image.single.imageWidth == 120, 'inline SVG width');
  });

  await _case('object data image is retained', () async {
    final archive = _baseArchive(
      _opf(
        title: 'Object',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml(
            '图',
            '<object data="Images/pic.png" type="image/png"></object>',
          ),
        ),
        'OEBPS/Images/pic.png': _bytesFile('OEBPS/Images/pic.png', _png),
      },
    );
    final book = await _parseArchive(archive);
    _expect(
      book.chapters.single.epubBlocks.any((block) => block.isImage),
      'object image block',
    );
  });

  await _case('direct raster spine page becomes an image chapter', () async {
    final archive = _baseArchive(
      _opf(
        title: '裸图',
        manifest: <String>[_item('page', 'Images/pic.png', 'image/png')],
        spine: <String>[_spineRef('page')],
      ),
      <String, ArchiveFile>{
        'OEBPS/Images/pic.png': _bytesFile('OEBPS/Images/pic.png', _png),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 1, 'raster chapter count');
    _expect(
      book.chapters.single.epubBlocks.single.isImage,
      'raster image block',
    );
  });

  await _case('nav wins over NCX without mixing entries', () async {
    final archive = _baseArchive(
      _opf(
        title: '导航优先',
        manifest: <String>[
          _item('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          _item('ncx', 'toc.ncx', 'application/x-dtbncx+xml'),
          _item('book', 'book.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('book')],
        toc: 'ncx',
      ),
      <String, ArchiveFile>{
        'OEBPS/nav.xhtml': _textFile(
          'OEBPS/nav.xhtml',
          _navHtml(
            '<li><a href="book.xhtml#ch1">导航一</a></li>'
            '<li><a href="book.xhtml#ch2">导航二</a></li>',
          ),
        ),
        'OEBPS/toc.ncx': _textFile(
          'OEBPS/toc.ncx',
          _ncxXml(
            'NCX',
            _navPoint('NCX一', 'book.xhtml#ch1') +
                _navPoint('NCX二', 'book.xhtml#ch2'),
          ),
        ),
        'OEBPS/book.xhtml': _textFile(
          'OEBPS/book.xhtml',
          _chapterHtml(
            '整本',
            '<h1 id="ch1">导航一</h1><p>一。</p>'
                '<h1 id="ch2">导航二</h1><p>二。</p>',
          ),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 2, 'nav/NCX chapter count');
    _expect(book.chapters[0].title == '导航一', 'nav title wins');
    _expect(book.chapters[1].title == '导航二', 'nav title wins 2');
  });

  await _case('transitive non-linear notes are followed', () async {
    final archive = _baseArchive(
      _opf(
        title: '传递注释',
        manifest: <String>[
          _item('c1', 'c1.xhtml', 'application/xhtml+xml'),
          _item('n1', 'n1.xhtml', 'application/xhtml+xml'),
          _item('n2', 'n2.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[
          _spineRef('c1'),
          _spineRef('n1', linear: false),
          _spineRef('n2', linear: false),
        ],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('章', '<p>正文<a href="n1.xhtml#a">[1]</a>。</p>'),
        ),
        'OEBPS/n1.xhtml': _textFile(
          'OEBPS/n1.xhtml',
          _chapterHtml('注一', '<p id="a">注一<a href="n2.xhtml#b">[2]</a>。</p>'),
        ),
        'OEBPS/n2.xhtml': _textFile(
          'OEBPS/n2.xhtml',
          _chapterHtml('注二', '<p id="b">注二正文。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 3, 'transitive notes count');
    _expectContains(book.chapters[2].content, '注二正文。', 'second note text');
  });

  await _case(
    'one ambiguous chapter does not block a readable sibling',
    () async {
      final archive = _baseArchive(
        _opf(
          title: '隔离',
          manifest: <String>[
            _item('bad', 'TEXT/BAD.XHTML', 'application/xhtml+xml'),
            _item('good', 'good.xhtml', 'application/xhtml+xml'),
          ],
          spine: <String>[_spineRef('bad'), _spineRef('good')],
        ),
        <String, ArchiveFile>{
          'OEBPS/Text/bad.xhtml': _textFile(
            'OEBPS/Text/bad.xhtml',
            _chapterHtml('坏', '<p>歧义甲。</p>'),
          ),
          'OEBPS/text/bad.xhtml': _textFile(
            'OEBPS/text/bad.xhtml',
            _chapterHtml('坏', '<p>歧义乙。</p>'),
          ),
          'OEBPS/good.xhtml': _textFile(
            'OEBPS/good.xhtml',
            _chapterHtml('好', '<p>可读正文。</p>'),
          ),
        },
      );
      final book = await _parseArchive(archive);
      _expect(book.chapters.length == 1, 'readable sibling only');
      _expectContains(book.chapters.single.content, '可读正文。', 'sibling text');
    },
  );

  await _case('nested nav labels group separate chapter files', () async {
    final archive = _baseArchive(
      _opf(
        title: '跨文件层级',
        manifest: <String>[
          _item('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          _item('c1', 'c1.xhtml', 'application/xhtml+xml'),
          _item('c2', 'c2.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1'), _spineRef('c2')],
      ),
      <String, ArchiveFile>{
        'OEBPS/nav.xhtml': _textFile(
          'OEBPS/nav.xhtml',
          _navHtml(
            '<li><span>第一部</span><ol>'
            '<li><a href="c1.xhtml">第一章</a></li>'
            '<li><a href="c2.xhtml">第二章</a></li>'
            '</ol></li>',
          ),
        ),
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('第一章', '<p>一章。</p>'),
        ),
        'OEBPS/c2.xhtml': _textFile(
          'OEBPS/c2.xhtml',
          _chapterHtml('第二章', '<p>二章。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 2, 'cross-file chapter count');
    _expect(book.chapters[0].volumeTitle == '第一部', 'cross-file volume 1');
    _expect(book.chapters[1].volumeTitle == '第一部', 'cross-file volume 2');
  });

  await _case('canonical DRM path blocks an encrypted linear chapter', () async {
    final archive = _baseArchive(
      _opf(
        title: 'DRM',
        manifest: <String>[
          _item('c1', 'text/chapter1.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'META-INF/encryption.xml': _textFile(
          'META-INF/encryption.xml',
          '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
              'xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
              '<enc:EncryptedData><enc:CipherData>'
              '<enc:CipherReference URI="OEBPS/text/chapter1.xhtml"/>'
              '</enc:CipherData></enc:EncryptedData></encryption>',
        ),
        'OEBPS/Text/chapter1.xhtml': _textFile(
          'OEBPS/Text/chapter1.xhtml',
          _chapterHtml('章', '<p>受保护正文。</p>'),
        ),
      },
    );
    var protected = false;
    try {
      await _parseArchive(archive);
    } on FormatException catch (error) {
      protected = error.message.contains('DRM') || error.message.contains('加密');
    }
    _expect(protected, 'canonical DRM path blocks import');
  });

  await _case('encrypted non-linear note is not read or appended', () async {
    final archive = _baseArchive(
      _opf(
        title: 'DRM 注释',
        manifest: <String>[
          _item('c1', 'c1.xhtml', 'application/xhtml+xml'),
          _item('notes', 'Text/notes.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1'), _spineRef('notes', linear: false)],
      ),
      <String, ArchiveFile>{
        'META-INF/encryption.xml': _textFile(
          'META-INF/encryption.xml',
          '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
              'xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
              '<enc:EncryptedData><enc:CipherData>'
              '<enc:CipherReference URI="OEBPS/text/notes.xhtml"/>'
              '</enc:CipherData></enc:EncryptedData></encryption>',
        ),
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('章', '<p>正文<a href="text/notes.xhtml#fn">[1]</a>。</p>'),
        ),
        'OEBPS/Text/notes.xhtml': _textFile(
          'OEBPS/Text/notes.xhtml',
          _chapterHtml('注释', '<p id="fn">不应读取的注释。</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 1, 'encrypted note skipped');
    _expect(
      !book.chapters.single.content.contains('不应读取的注释。'),
      'encrypted note text absent',
    );
  });

  await _case(
    'case and percent fallbacks use one canonical chapter identity',
    () async {
      final archive = _baseArchive(
        _opf(
          title: '规范路径',
          manifest: <String>[
            _item(
              'nav',
              'nav.xhtml',
              'application/xhtml+xml',
              properties: 'nav',
            ),
            _item('book', 'text/book.xhtml', 'application/xhtml+xml'),
          ],
          spine: <String>[_spineRef('book')],
        ),
        <String, ArchiveFile>{
          'OEBPS/nav.xhtml': _textFile(
            'OEBPS/nav.xhtml',
            _navHtml(
              '<li><a href="Text/Book.xhtml#ch1">第一章</a></li>'
              '<li><a href="Text/Book.xhtml#ch2">第二章</a></li>',
            ),
          ),
          'OEBPS/Text/Book.xhtml': _textFile(
            'OEBPS/Text/Book.xhtml',
            _chapterHtml(
              '整本',
              '<h1 id="ch1">第一章</h1><p>一<a href="book.xhtml#ch2">跳到二</a>。</p>'
                  '<h1 id="ch2">第二章</h1><p>二。</p>',
            ),
          ),
        },
      );
      final book = await _parseArchive(archive);
      _expect(book.chapters.length == 2, 'canonical split count');
      _expect(book.chapters[0].title == '第一章', 'canonical nav title');
      final link = _firstLink(book.chapters[0]);
      _expect(link?.link?.chapterIndex == 1, 'canonical link chapter');
      _expect(link?.link?.blockIndex == 0, 'canonical link block');
      final restored = decodeChapterPayload(
        encodeChapterPayload(book.chapters[0]),
        0,
      );
      final restoredLink = _firstLink(restored);
      _expect(
        restoredLink?.link?.chapterIndex == 1,
        'split link survives codec',
      );
      _expect(
        restoredLink?.link?.blockIndex == 0,
        'split block survives codec',
      );
      _expect(
        restored.volumeTitle == book.chapters[0].volumeTitle,
        'volume survives codec',
      );
    },
  );

  await _case('malformed NCX is repaired and still names chapters', () async {
    final archive = _baseArchive(
      _opf(
        title: '坏 NCX',
        manifest: <String>[
          _item('ncx', 'toc.ncx', 'application/x-dtbncx+xml'),
          _item('c1', 'c1.xhtml', 'application/xhtml+xml'),
        ],
        spine: <String>[_spineRef('c1')],
        toc: 'ncx',
        version: '2.0',
      ),
      <String, ArchiveFile>{
        'OEBPS/toc.ncx': _textFile(
          'OEBPS/toc.ncx',
          '<ncx><navMap>'
              '<navPoint><navLabel><text>第一章</text></navLabel>'
              '<content src="c1.xhtml#a"/></navPoint>'
              '<navPoint><navLabel><text>第二章</text></navLabel>'
              '<content src="c1.xhtml#b"/></navPoint>'
              '</navMap></ncxBroken>',
        ),
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml(
            '整本',
            '<a name="a"></a><h1>第一章</h1><p>一。</p>'
                '<a name="b"></a><h1>第二章</h1><p>二。</p>',
          ),
        ),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 2, 'repaired NCX split count');
    _expect(book.chapters[0].title == '第一章', 'repaired NCX first title');
    _expect(book.chapters[1].title == '第二章', 'repaired NCX second title');
  });

  await _case('author line break stays inside one paragraph', () async {
    final archive = _baseArchive(
      _opf(
        title: '换行',
        manifest: <String>[_item('c1', 'c1.xhtml', 'application/xhtml+xml')],
        spine: <String>[_spineRef('c1')],
      ),
      <String, ArchiveFile>{
        'OEBPS/c1.xhtml': _textFile(
          'OEBPS/c1.xhtml',
          _chapterHtml('换行', '<p>第一行<br/>第二行<br/><br/></p><p>后段</p>'),
        ),
      },
    );
    final book = await _parseArchive(archive);
    final blocks = book.chapters.single.epubBlocks;
    final broken = blocks.firstWhere((block) => block.text.contains('第一行'));
    _expect(broken.text == '第一行\n第二行', 'only internal breaks remain');
    _expect(
      broken.runs.isEmpty ||
          broken.runs.map((run) => run.text).join() == broken.text,
      'runs match the visible line break',
    );
    _expect(
      blocks.any((block) => block.text == '后段'),
      'paragraph after the breaks is unchanged',
    );
    final restored = decodeChapterPayload(
      encodeChapterPayload(book.chapters.single),
      0,
    );
    _expect(
      restored.epubBlocks
              .firstWhere((block) => block.text.contains('第一行'))
              .text ==
          '第一行\n第二行',
      'codec keeps the line break',
    );
  });

  await _case('directory table keeps rows, columns and links', () async {
    const chapterOneTitle =
        '第一章 星海彼岸的漫长归途与未寄出的信 The Long Way Home Across the Stars';
    const sectionTitle = '第二节 旧港口与潮汐表 The Old Harbour and the Tide Tables';
    final archive = _baseArchive(
      _opf(
        title: '目录结构',
        manifest: <String>[
          _item('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          _item('toc', 'toc.xhtml', 'application/xhtml+xml'),
          _item('ch1', 'text/ch1.xhtml', 'application/xhtml+xml'),
          _item('px', 'images/px.png', 'image/png'),
        ],
        spine: <String>[_spineRef('toc'), _spineRef('ch1')],
        version: '3.0',
      ),
      <String, ArchiveFile>{
        'OEBPS/nav.xhtml': _textFile(
          'OEBPS/nav.xhtml',
          _navHtml(
            '<li><a href="text/ch1.xhtml#ch1">第一章</a>'
            '<ol><li><a href="text/ch1.xhtml#sec1">第二节</a></li></ol></li>'
            '<li><a href="text/ch1.xhtml#ch2">第二章</a></li>',
          ),
        ),
        'OEBPS/toc.xhtml': _textFile(
          'OEBPS/toc.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>目录</title>'
                  '<style type="text/css">'
                  '.entry td { padding: 0; }'
                  '.entry.chapter td { font-weight: bold; padding-top: .85em; }'
                  '.entry.section td:first-child { padding-left: 1em; }'
                  '.entry td.range { text-align: right; width: 4.4em; font-size: .86em; }'
                  '</style></head><body><h1>目录</h1>'
                  '<table class="contents"><caption>目录</caption>'
                  '<thead><tr><th>章节</th><th class="range">页码</th></tr></thead>'
                  '<tbody>'
                  '<tr class="entry chapter"><td><a href="text/ch1.xhtml#ch1">' +
              chapterOneTitle +
              '</a></td><td class="range">1–12</td></tr>'
                  '<tr class="entry section"><td><a href="text/ch1.xhtml#sec1">' +
              sectionTitle +
              '</a></td><td class="range">13</td></tr>'
                  '<tr class="entry chapter"><td><a href="text/ch1.xhtml#ch2">'
                  '第二章 终章</a></td><td class="range">21</td></tr>'
                  '<tr class="entry section"><td></td><td class="range">14</td></tr>'
                  '</tbody>'
                  '<tfoot><tr><td>附录</td><td class="range">—</td></tr></tfoot>'
                  '</table></body></html>',
        ),
        'OEBPS/text/ch1.xhtml': _textFile(
          'OEBPS/text/ch1.xhtml',
          _chapterHtml(
            '正文',
            '<h1 id="ch1">第一章</h1><p>正文一。</p>'
                '<h2 id="sec1">第二节</h2><p>正文二。</p>'
                '<h2 id="br">第一节<br/>换行标题</h2><p>正文三。</p>'
                '<table class="plain"><tr><td>单元甲</td><td>单元乙</td></tr></table>'
                '<table><tr><td>图前</td><td><img src="../images/px.png" alt="小图"/>'
                '</td><td>图后</td></tr></table>'
                '<h1 id="ch2">第二章</h1>'
                '<p>正文四<a href="ch1.xhtml#note1">[1]</a>。</p>'
                '<aside id="note1"><p>注释一。</p></aside>',
          ),
        ),
        'OEBPS/images/px.png': _bytesFile('OEBPS/images/px.png', _png),
      },
    );
    final book = await _parseArchive(archive);
    _expect(book.chapters.length == 3, 'directory and two body chapters');
    final toc = book.chapters[0];
    final blocks = toc.epubBlocks;
    _expect(
      blocks.length == 8,
      'one block per caption, header, row and footer',
    );
    _expect(blocks[0].isHeading && blocks[0].text == '目录', 'heading kept');
    _expect(blocks[1].text == '目录' && !blocks[1].isHeading, 'caption kept');
    _expect(blocks[2].text == '章节 页码', 'header row kept');
    final chapterRow = blocks[3];
    _expect(
      chapterRow.text == chapterOneTitle + ' 1–12',
      'chapter row keeps both cells and its line',
    );
    _expect(!chapterRow.isHeading, 'bold directory row is not a heading');
    _expect(chapterRow.style.fontWeight >= 700, 'chapter row keeps bold');
    _expect(chapterRow.style.textIndentEm == 0, 'chapter row is not indented');
    _expect(chapterRow.hasTrailingCell, 'page cell metadata');
    _expect(
      chapterRow.trailingCellStart == chapterRow.text.lastIndexOf('1–12'),
      'page cell offset',
    );
    _expect(
      (chapterRow.trailingCellWidthEm! - 3.784).abs() < 0.001,
      'page cell width in em',
    );
    final sectionRow = blocks[4];
    _expect(sectionRow.text == sectionTitle + ' 13', 'section row line');
    _expect(sectionRow.style.textIndentEm == 1, 'only first cell indents');
    _expect(sectionRow.style.fontWeight < 600, 'section row is not bold');
    _expect(sectionRow.hasTrailingCell, 'section page cell metadata');
    _expect(blocks[5].text == '第二章 终章 21', 'second chapter row');
    _expect(blocks[6].text == '14', 'page cell beside an empty cell survives');
    _expect(!blocks[6].hasTrailingCell, 'empty left cell has no column split');
    _expect(blocks[7].text == '附录 —', 'footer row kept');
    _expect(
      !blocks[7].hasTrailingCell,
      'non-numeric footer is not a page cell',
    );

    String joined(EpubContentBlock block) => block.runs.isEmpty
        ? block.text
        : block.runs.map((run) => run.text).join();
    for (final block in blocks) {
      _expect(joined(block) == block.text, 'runs partition the row text');
    }

    final chapterLink = chapterRow.runs
        .map((run) => run.link)
        .whereType<EpubLinkTarget>()
        .single;
    _expect(chapterLink.chapterIndex == 1, 'chapter link target chapter');
    _expect(chapterLink.blockIndex == 0, 'chapter link target block');
    _expect(chapterLink.needDirectJump, 'directory link jumps directly');
    final sectionLink = sectionRow.runs
        .map((run) => run.link)
        .whereType<EpubLinkTarget>()
        .single;
    _expect(sectionLink.chapterIndex == 1, 'section link target chapter');
    _expect(sectionLink.blockIndex == 2, 'section link target block');
    _expect(
      sectionLink.needDirectJump,
      'section directory link jumps directly',
    );

    final body = book.chapters[1];
    final brBlock = body.epubBlocks.firstWhere(
      (block) => block.text.contains('换行标题'),
    );
    _expect(brBlock.text == '第一节\n换行标题', 'author line break preserved');
    _expect(brBlock.isHeading, 'line break does not clear heading semantics');
    final plainRow = body.epubBlocks.firstWhere(
      (block) => block.text.contains('单元甲'),
    );
    _expect(plainRow.text == '单元甲 单元乙', 'ordinary table row joins cells');
    _expect(!plainRow.hasTrailingCell, 'ordinary row has no page column');
    final imageBlocks = body.epubBlocks
        .where((block) => block.isImage)
        .toList();
    _expect(imageBlocks.length == 1, 'image inside a table is kept');
    _expect(imageBlocks.single.imagePath != null, 'table image extracted');
    _expect(
      body.epubBlocks.every(
        (block) => !(block.text.contains('图前') && block.text.contains('图后')),
      ),
      'complex row falls back per cell instead of one leaf',
    );
    _expect(
      body.epubBlocks.any((block) => block.text == '图前') &&
          body.epubBlocks.any((block) => block.text == '图后'),
      'text beside the image is preserved',
    );

    final noteLink = book.chapters[2].epubBlocks
        .expand((block) => block.runs)
        .map((run) => run.link)
        .whereType<EpubLinkTarget>()
        .single;
    _expect(noteLink.chapterIndex == 2, 'footnote target chapter');
    _expect(noteLink.blockIndex == 2, 'footnote target block');
    _expect(!noteLink.needDirectJump, 'ordinary footnote keeps its preview');

    final encoded = encodeChapterPayload(toc);
    final encodedBlocks = encoded['epubBlocks'] as List<dynamic>;
    final encodedRow = encodedBlocks[3] as Map<String, dynamic>;
    _expect(
      encodedRow['trailingCellStart'] == chapterRow.trailingCellStart,
      'codec writes the page cell offset',
    );
    final encodedRuns = encodedRow['runs'] as List<dynamic>;
    final encodedLink =
        (encodedRuns.cast<Map<String, dynamic>>().firstWhere(
              (run) => run['link'] != null,
            )['link'])
            as Map<String, dynamic>;
    _expect(encodedLink['directJump'] == true, 'codec writes direct jump');

    final restored = decodeChapterPayload(encoded, 0);
    _expect(restored.epubBlocks.length == blocks.length, 'codec block count');
    final restoredRow = restored.epubBlocks[3];
    _expect(restoredRow.hasTrailingCell, 'codec keeps page cell metadata');
    _expect(
      restoredRow.trailingCellStart == chapterRow.trailingCellStart,
      'codec keeps page cell offset',
    );
    _expect(
      (restoredRow.trailingCellWidthEm! - chapterRow.trailingCellWidthEm!)
              .abs() <
          0.000001,
      'codec keeps page cell width',
    );
    final restoredLink = restoredRow.runs
        .map((run) => run.link)
        .whereType<EpubLinkTarget>()
        .single;
    _expect(restoredLink.needDirectJump, 'codec keeps direct jump');
    _expect(
      restoredRow.runs.map((run) => run.text).join() == restoredRow.text,
      'codec keeps the run partition',
    );

    final legacy = decodeChapterPayload(<String, dynamic>{
      'title': '旧章',
      'content': '旧正文 12',
      'epubBlocks': <dynamic>[
        <String, dynamic>{
          'kind': 'text',
          'text': '旧正文 12',
          'trailingCellStart': 99,
          'trailingCellWidthEm': 99,
          'runs': <dynamic>[
            <String, dynamic>{
              'text': '旧正文 12',
              'style': <String, dynamic>{},
              'link': <String, dynamic>{'chapter': 0, 'block': 0},
            },
          ],
        },
      ],
    }, 0);
    _expect(
      !legacy.epubBlocks.single.hasTrailingCell,
      'invalid saved offset is dropped',
    );
    _expect(
      !legacy.epubBlocks.single.runs.single.link!.needDirectJump,
      'legacy link defaults to preview',
    );
  });

  try {
    for (final directory in _tempDirs) {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Best-effort temp cleanup.
      }
    }
    stdout.writeln('');
    stdout.writeln(
      'passed=' + _passed.toString() + ' failed=' + _failed.toString(),
    );
    if (_failures.isNotEmpty) {
      stdout.writeln('failures:');
      for (final failure in _failures) {
        stdout.writeln(' - ' + failure);
      }
      exitCode = 1;
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

class _Big5Encoding extends Encoding {
  const _Big5Encoding();

  @override
  String get name => 'big5';

  @override
  Converter<String, List<int>> get encoder => _Big5Encoder();

  @override
  Converter<List<int>, String> get decoder =>
      throw UnsupportedError('not needed');
}

class _Big5Encoder extends Converter<String, List<int>> {
  const _Big5Encoder();

  @override
  List<int> convert(String input) => Big5.encode(input);
}
