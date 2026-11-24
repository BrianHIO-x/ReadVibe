import 'dart:io';

import 'package:flutter/services.dart';

import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';
import 'android_book_picker.dart';
import 'book_import_format.dart';

class FontService {
  FontService(this._storage);

  final ImportedFontStore _storage;

  static final Set<String> _loadedFamilies = <String>{};
  static final Map<String, Future<void>> _loadingFamilies =
      <String, Future<void>>{};

  Future<ReaderSettings> ensureImportedFontLoaded(
    ReaderSettings settings,
  ) async {
    if (settings.usesSystemFont || settings.usesBundledFont) {
      return settings;
    }
    if (!settings.hasImportedFont) {
      return settings.copyWith(
        fontFamily: ReaderSettings.systemFontFamily,
        clearImportedFont: true,
      );
    }

    try {
      await loadFont(
        family: settings.importedFontFamily!,
        path: settings.importedFontPath!,
      );
      return settings;
    } on Object {
      return settings.copyWith(
        fontFamily: ReaderSettings.systemFontFamily,
        clearImportedFont: true,
      );
    }
  }

  Future<ReaderSettings?> pickAndInstallFont(
    ReaderSettings currentSettings,
  ) async {
    final picked = await AndroidBookPicker.pickFont();
    if (picked == null) return null;
    try {
      final sourcePath = picked.path;
      final extension = fileExtension(sourcePath).isNotEmpty
          ? fileExtension(sourcePath)
          : fileExtension(picked.name);
      if (extension != 'ttf' && extension != 'otf') {
        throw const FormatException('仅支持 .ttf 或 .otf 字体文件');
      }
      final displayName = fileExtension(picked.name) == extension
          ? picked.name
          : '${picked.name}.$extension';

      final saved = await _storage.saveImportedFont(sourcePath, displayName);
      final family = 'ReadVibeImported_${DateTime.now().microsecondsSinceEpoch}';
      try {
        await loadFont(family: family, path: saved.path);
      } on Object {
        try {
          if (await saved.exists()) await saved.delete();
        } on FileSystemException {
          // Preserve the original font loading error for the caller.
        }
        rethrow;
      }

      return currentSettings.copyWith(
        fontFamily: family,
        importedFontFamily: family,
        importedFontName: displayName,
        importedFontPath: saved.path,
      );
    } finally {
      if (picked.deleteAfterImport) {
        try {
          final temporary = File(picked.path);
          if (await temporary.exists()) await temporary.delete();
        } on FileSystemException {
          // Picker cache cleanup is best-effort.
        }
      }
    }
  }

  Future<void> loadFont({required String family, required String path}) async {
    if (_loadedFamilies.contains(family)) return;
    final inFlight = _loadingFamilies[family];
    if (inFlight != null) return inFlight;

    final operation = _loadFont(family: family, path: path);
    _loadingFamilies[family] = operation;
    try {
      await operation;
      _loadedFamilies.add(family);
    } finally {
      if (identical(_loadingFamilies[family], operation)) {
        _loadingFamilies.remove(family);
      }
    }
  }

  Future<void> _loadFont({required String family, required String path}) async {
    final file = File(path);
    final stat = await file.stat();
    const maxFontBytes = 64 * 1024 * 1024;
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size > maxFontBytes) {
      throw const FormatException('字体文件为空、过大或无法读取');
    }

    final bytes = await file.readAsBytes();
    final byteData = ByteData.sublistView(bytes);
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(byteData));
    await loader.load();
  }
}
