import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Called while the repository holds the chapter writer queue. Every recovery
/// manifest protects its payloads; malformed manifests disable collection.
Future<int> collectObsoleteChapterPayloads(
  Directory directory,
  DateTime cutoff,
) async {
  final referenced = <String>{};
  var manifests = 0;
  try {
    for (final name in [
      'manifest.json',
      'manifest.json.edit.bak',
      'manifest.json.edit.tmp',
    ]) {
      final file = File(p.join(directory.path, name));
      if (!await file.exists()) continue;
      final decoded = jsonDecode(await file.readAsString(encoding: utf8));
      if (decoded is! Map ||
          decoded['version'] != 2 ||
          decoded['chapters'] is! List) {
        return 0;
      }
      final entries = decoded['chapters'] as List;
      if (entries.isEmpty || decoded['chapterCount'] != entries.length) {
        return 0;
      }
      for (final entry in entries) {
        if (entry is! Map ||
            entry['file'] is! String ||
            !_payloadName.hasMatch(entry['file'] as String)) {
          return 0;
        }
        referenced.add(entry['file'] as String);
      }
      manifests++;
    }
    if (manifests == 0) return 0;
    final payloads = Directory(p.join(directory.path, 'chapters'));
    if (!await payloads.exists()) return 0;
    var removed = 0;
    await for (final entity in payloads.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!_payloadName.hasMatch(name) || referenced.contains(name)) continue;
      if (!(await entity.stat()).modified.isBefore(cutoff)) continue;
      try {
        await entity.delete();
        removed++;
      } on FileSystemException {
        // An active reader may retain a Windows file handle; a later sweep retries.
      }
    }
    return removed;
  } on Object {
    return 0;
  }
}

final _payloadName = RegExp(r'^\d{6,}(?:-[A-Za-z0-9_-]+)?\.json$');
