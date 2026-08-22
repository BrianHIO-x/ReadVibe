import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/services/font_service.dart';
import 'package:readvibe/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing imported font falls back without losing other settings',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'readvibe_font_test_',
      );
      addTearDown(() {
        try {
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        } on FileSystemException {
          // Temp cleanup is best-effort.
        }
      });
      final service = FontService(
        StorageService(documentsDirectory: directory),
      );
      final settings = ReaderSettings(
        fontSize: 24,
        fontFamily: 'ReadVibeImported_missing',
        importedFontFamily: 'ReadVibeImported_missing',
        importedFontName: 'missing.ttf',
        importedFontPath: '${directory.path}/missing.ttf',
      );

      final loaded = await service.ensureImportedFontLoaded(settings);

      expect(loaded.fontFamily, ReaderSettings.systemFontFamily);
      expect(loaded.importedFontPath, isNull);
      expect(loaded.fontSize, 24);
    },
  );
}
