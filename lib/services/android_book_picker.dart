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

/// Android book picker that rejects install packages before copying bytes.
class AndroidBookPicker {
  AndroidBookPicker._();

  static const _channel = MethodChannel('com.readvibe.app/book_picker');

  static Future<PickedImportFile?> pick() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('pick');
      if (raw == null) return null;
      final path = raw['path'];
      final name = raw['name'];
      if (path is! String || path.isEmpty || name is! String || name.isEmpty) {
        throw const FormatException('无法读取所选文件');
      }
      return PickedImportFile(path: path, name: name, deleteAfterImport: true);
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return null;
      final message = describeFilePickerFailure(error);
      throw FormatException(message);
    }
  }
}
