import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/book.dart';
import 'package:readvibe/services/book_import_coordinator.dart';
import 'package:readvibe/services/book_import_format.dart';

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

void main() {
  test('path suffix wins over a display name without one', () {
    expect(
      detectBookImportFormat(
        path: '/cache/file_picker/123/novel.epub',
        fileName: '下载文件',
        bytes: utf8.encode('%PDF-1.4\n'),
      ),
      BookFormat.epub,
    );
  });

  test('.azw3 is not treated as .azw', () {
    expect(
      detectBookImportFormat(path: '/books/title.azw3', fileName: 'title.azw3'),
      BookFormat.azw3,
    );
  });

  test('extensionless PDF / EPUB / DOCX / TXT bytes are recognized', () {
    expect(
      detectBookImportFormat(
        path: '/cache/msf_1',
        fileName: '文档',
        bytes: utf8.encode('%PDF-1.7\n1 0 obj\n'),
      ),
      BookFormat.pdf,
    );

    final epub = _zip({
      'mimetype': utf8.encode('application/epub+zip'),
      'META-INF/container.xml': utf8.encode('<container/>'),
    });
    expect(
      detectBookImportFormat(path: '/cache/msf_2', fileName: '电子书', bytes: epub),
      BookFormat.epub,
    );

    final docx = _zip({
      '[Content_Types].xml': utf8.encode('<Types/>'),
      'word/document.xml': utf8.encode('<w:document/>'),
    });
    expect(
      detectBookImportFormat(path: '/cache/msf_3', fileName: '文稿', bytes: docx),
      BookFormat.docx,
    );

    expect(
      detectBookImportFormat(
        path: '/cache/msf_4',
        fileName: '小说',
        bytes: utf8.encode('第一章 开始\n他走进了城门。'),
      ),
      BookFormat.txt,
    );
  });

  test('an APK is rejected with an install-package message', () {
    final apk = _zip({
      'AndroidManifest.xml': utf8.encode('<manifest/>'),
      'classes.dex': Uint8List.fromList(<int>[0x64, 0x65, 0x78, 0x0a]),
    });
    expect(
      () => detectBookImportFormat(
        path: '/cache/msf_apk',
        fileName: '安装包',
        bytes: apk,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          androidPackageImportMessage,
        ),
      ),
    );
    expect(
      () => detectBookImportFormat(
        path: '/download/ReadVibe.apk',
        fileName: 'ReadVibe.apk',
        bytes: apk,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          androidPackageImportMessage,
        ),
      ),
    );
    expect(androidPackageImportMessage.contains('损坏'), isFalse);
  });

  test('unsupported picker files stay rejected when MIME filtering is */*', () {
    expect(BookImportCoordinator.supportedExtensions.contains('mobi'), isTrue);
    expect(
      () => detectBookImportFormat(
        path: '/cache/photo.png',
        fileName: 'photo.png',
        bytes: <int>[0x89, 0x50, 0x4e, 0x47],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          unsupportedBookFormatMessage,
        ),
      ),
    );
  });

  test('file picker failures become short Chinese messages', () {
    expect(
      describeFilePickerFailure(
        PlatformException(
          code: 'invalid_format_type',
          message: "Can't handle the provided file type.",
        ),
      ),
      '无法打开系统文件选择器',
    );
    expect(
      describeFilePickerFailure(
        PlatformException(
          code: 'already_active',
          message: 'File picker is already active',
        ),
      ),
      '文件选择器已打开，请完成当前选择',
    );
  });
}
