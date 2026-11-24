import 'package:flutter/services.dart';

import 'book_import_format.dart';

class PickedImportFile {
  const PickedImportFile({
    required this.path,
    required this.name,
    this.deleteAfterImport = false,
  });

  final String path;
  final String name;
  final bool deleteAfterImport;
}

class PickedBatchResult {
  const PickedBatchResult({
    this.files = const <PickedImportFile>[],
    this.errors = const <String>[],
  });

  final List<PickedImportFile> files;
  final List<String> errors;
}

/// Native Android SAF picker for books, fonts, and backup archives.
class AndroidBookPicker {
  AndroidBookPicker._();

  static const _channel = MethodChannel('com.readvibe.app/book_picker');

  static Future<PickedBatchResult?> pickBooks() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('pickBooks');
      if (raw == null) return null;
      final files = <PickedImportFile>[];
      final rawFiles = raw['files'];
      if (rawFiles is List) {
        for (final entry in rawFiles) {
          if (entry is! Map) continue;
          final path = entry['path'];
          final name = entry['name'];
          if (path is String &&
              path.isNotEmpty &&
              name is String &&
              name.isNotEmpty) {
            files.add(
              PickedImportFile(path: path, name: name, deleteAfterImport: true),
            );
          }
        }
      }
      final errors = <String>[];
      final rawErrors = raw['errors'];
      if (rawErrors is List) {
        for (final entry in rawErrors) {
          if (entry is! Map) continue;
          final name = (entry['name'] as String?)?.trim() ?? '';
          final message = (entry['message'] as String?)?.trim() ?? '无法读取所选文件';
          errors.add(name.isNotEmpty ? '「$name」$message' : message);
        }
      }
      if (files.isEmpty && errors.isEmpty) return null;
      return PickedBatchResult(files: files, errors: errors);
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return null;
      throw FormatException(describeFilePickerFailure(error));
    }
  }

  static Future<PickedImportFile?> pickFont() => _pickSingle('pickFont');

  static Future<PickedImportFile?> pickBackup() => _pickSingle('pickBackup');

  static Future<PickedImportFile?> _pickSingle(String method) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(method);
      if (raw == null) return null;
      final path = raw['path'];
      final name = raw['name'];
      if (path is! String || path.isEmpty || name is! String || name.isEmpty) {
        throw const FormatException('无法读取所选文件');
      }
      return PickedImportFile(path: path, name: name, deleteAfterImport: true);
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return null;
      throw FormatException(describeFilePickerFailure(error));
    }
  }
}
