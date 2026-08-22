import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/services/mobi_parser.dart';

void main() {
  test('Kindle import rejects oversized input before parsing', () async {
    final directory = Directory.systemTemp.createTempSync(
      'readvibe_mobi_size_',
    );
    addTearDown(() {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Temp cleanup is best-effort.
      }
    });
    final file = File('${directory.path}/large.mobi');
    final handle = file.openSync(mode: FileMode.write);
    handle.truncateSync(256 * 1024 * 1024 + 1);
    handle.closeSync();

    await expectLater(
      parseKindleBook(file.path, 'large.mobi'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('256 MB'),
        ),
      ),
    );
  });

  test('invalid Kindle container does not create an empty book', () async {
    final directory = Directory.systemTemp.createTempSync('readvibe_mobi_bad_');
    addTearDown(() {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Temp cleanup is best-effort.
      }
    });
    final file = File('${directory.path}/bad.azw3')
      ..writeAsStringSync('not a kindle container');

    await expectLater(
      parseKindleBook(file.path, 'bad.azw3'),
      throwsA(isA<FormatException>()),
    );
  });
}
