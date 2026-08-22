import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/services/storage_service.dart';
import 'package:readvibe/services/word_parser.dart';

ArchiveFile _xml(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'DOCX keeps metadata, headings, styles, tables, notes and images',
    () async {
      final archive = Archive()
        ..addFile(
          _xml('docProps/core.xml', '''
<cp:coreProperties xmlns:cp="core" xmlns:dc="dc">
  <dc:title>结构化文档</dc:title><dc:creator>文档作者</dc:creator>
</cp:coreProperties>'''),
        )
        ..addFile(
          _xml('word/_rels/document.xml.rels', '''
<Relationships xmlns="rels">
  <Relationship Id="rIdImage" Target="media/image.png" Type="image"/>
</Relationships>'''),
        )
        ..addFile(
          _xml(
            'word/footnotes.xml',
            '''
<w:footnotes xmlns:w="word"><w:footnote w:id="1"><w:p><w:r><w:t>脚注内容</w:t></w:r></w:p></w:footnote></w:footnotes>''',
          ),
        )
        ..addFile(
          ArchiveFile('word/media/image.png', 8, <int>[
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
          _xml('word/document.xml', '''
<w:document xmlns:w="word" xmlns:r="rels" xmlns:a="drawing">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章 开始</w:t></w:r></w:p>
    <w:p><w:r><w:rPr><w:b/><w:color w:val="336699"/></w:rPr><w:t>加粗正文</w:t></w:r><w:r><w:footnoteReference w:id="1"/></w:r></w:p>
    <w:p><w:r><w:drawing><a:blip r:embed="rIdImage"/></w:drawing></w:r></w:p>
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>单元格甲</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>单元格乙</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
  </w:body>
</w:document>'''),
        );
      final directory = Directory.systemTemp.createTempSync(
        'readvibe_docx_test_',
      );
      addTearDown(() {
        try {
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows can briefly keep decoded image handles open.
        }
      });
      final file = File('${directory.path}/sample.docx')
        ..writeAsBytesSync(ZipEncoder().encode(archive));

      final book = await parseWordDocument(
        file.path,
        'sample.docx',
        StorageService(documentsDirectory: directory),
      );

      expect(book.title, '结构化文档');
      expect(book.author, '文档作者');
      expect(book.chapters.single.title, '第一章 开始');
      expect(book.chapters.single.content, contains('脚注内容'));
      expect(book.chapters.single.content, contains('单元格甲　│　单元格乙'));
      expect(
        book.chapters.single.epubBlocks.any((block) => block.isImage),
        isTrue,
      );
      expect(
        book.chapters.single.epubBlocks
            .where((block) => block.isText)
            .expand((block) => block.runs)
            .any((run) => run.style.fontWeight >= 700),
        isTrue,
      );
    },
  );
}
