// Presence of an imported resource file, answered without touching the disk
// on every frame.
//
// Cover images, EPUB background images and embedded fonts are written once
// during import and removed together with their book. Their existence is
// therefore a property of the path, not something that changes while a widget
// tree is alive. Calling File.existsSync() from build ran a synchronous stat
// for every visible card, and for every styled block, on every frame of a
// scroll.

import 'dart:io';

/// Bounded so a very large shelf cannot grow the table without limit. Entries
/// are tiny and a book is only ever asked about while it is on screen.
const _maxTrackedPaths = 4096;

final Map<String, bool> _presence = <String, bool>{};

/// Whether the imported resource at [path] is present.
///
/// The first call for a path performs one stat; later calls answer from memory.
/// Callers that render a placeholder on a missing file get a stable answer for
/// the whole session rather than a result that can flip mid-scroll.
bool importedResourceExists(String? path) {
  if (path == null || path.isEmpty) return false;
  final known = _presence[path];
  if (known != null) return known;
  final exists = File(path).existsSync();
  if (_presence.length >= _maxTrackedPaths) _presence.clear();
  _presence[path] = exists;
  return exists;
}

/// Drops a remembered answer, for a path whose file was just created or
/// deleted by this app rather than by an import.
void forgetImportedResource(String? path) {
  if (path == null || path.isEmpty) return;
  _presence.remove(path);
}

/// Clears every remembered answer. Used by tests and after bulk maintenance
/// that may have removed resources behind the cache's back.
void resetImportedResourceCache() => _presence.clear();
