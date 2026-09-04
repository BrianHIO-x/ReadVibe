import 'dart:io';

import 'package:path/path.dart' as p;

import '../../repositories/reader_repositories.dart';

Future<void> removeObsoleteSearchData(AppDataDirectoryProvider storage) async {
  final root = (await storage.getAppDataDirectory()).absolute;
  final directory = Directory(p.join(root.path, 'search')).absolute;
  if (p.isWithin(root.path, directory.path) && await directory.exists()) {
    await directory.delete(recursive: true);
  }
}
