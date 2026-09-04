import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'data and domain modules do not import page or widget implementations',
    () {
      for (final directory in [
        'lib/models',
        'lib/repositories',
        'lib/services',
      ]) {
        for (final entity in Directory(directory).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final source = entity.readAsStringSync();
          final imports = RegExp(
            r"""(?:import|export)\s+['"]([^'"]+)['"]""",
          ).allMatches(source).map((match) => match.group(1)!);
          expect(
            imports.where(
              (path) =>
                  path.contains('/screens/') || path.contains('/widgets/'),
            ),
            isEmpty,
            reason: entity.path,
          );
        }
      }
    },
  );

  test(
    'search presentation and chapter codec have no platform or storage dependency',
    () {
      final sheet = File(
        'lib/widgets/book_search_sheet.dart',
      ).readAsStringSync();
      expect(sheet, isNot(contains('../services/')));
      final codec = File(
        'lib/services/storage/chapter_payload_codec.dart',
      ).readAsStringSync();
      expect(codec, isNot(contains('dart:io')));
      expect(codec, isNot(contains('package:flutter/')));
      final projection = File(
        'lib/models/reading_paragraph.dart',
      ).readAsStringSync();
      expect(projection, isNot(contains('dart:io')));
      expect(projection, isNot(contains('package:flutter/')));
    },
  );

  test('native PDF bridge dispatches through the background task boundary', () {
    final root = 'android/app/src/main/kotlin/com/readvibe/app';
    final handler = File('$root/PdfChannelHandler.kt').readAsStringSync();
    final activity = File('$root/MainActivity.kt').readAsStringSync();
    final engine = File('$root/PdfDocumentEngine.kt').readAsStringSync();
    expect(handler, contains('runner.submit('));
    expect(handler, isNot(contains('runOnUiThread')));
    expect(activity, isNot(contains('PDFTextStripper')));
    expect(engine, isNot(contains('MethodChannel')));
    expect(engine, isNot(contains('FlutterActivity')));
  });
}
