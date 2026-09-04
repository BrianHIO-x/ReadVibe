import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';

class FontService {
  FontService(this._storage);

  final ImportedFontStore _storage;

  static final Set<String> _loadedFamilies = <String>{};
  static final Map<String, Future<void>> _loadingFamilies =
      <String, Future<void>>{};

  Future<ReaderSettings> ensureImportedFontLoaded(
    ReaderSettings settings,
  ) async {
    if (settings.usesSystemFont || settings.usesBuiltinSerif) {
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf'],
    );
    if (result == null || result.files.isEmpty) return null;

    final picked = result.files.single;
    final sourcePath = picked.path;
    if (sourcePath == null) {
      throw const FormatException('无法读取所选字体文件');
    }

    final saved = await _storage.saveImportedFont(sourcePath, picked.name);
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
      importedFontName: picked.name,
      importedFontPath: saved.path,
    );
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
