// Identity for newly imported books.
//
// A book id is not only a map key: it names the book's private chapter
// directory, its saved PDF copy, its embedded font families and every reader
// state record. Importing the same file twice is allowed and creates two
// independent books, so two imports must never end up sharing an id — one
// would otherwise overwrite the other's payload on disk.

import 'dart:math' as math;

const _idAlphabet = '0123456789abcdefghijklmnopqrstuvwxyz';

final _random = math.Random();
int _lastMicroseconds = 0;
int _sequence = 0;

/// Returns a fresh id for a book imported as [prefix].
///
/// The wall clock alone is not enough: a device can report the same microsecond
/// twice for two back-to-back imports, and a time correction can move it
/// backwards. A process-local sequence keeps ids apart within one run, and a
/// short random suffix keeps them apart across a restart that lands on an
/// already-used microsecond.
String nextBookId(String prefix, {DateTime? now}) {
  final microseconds = (now ?? DateTime.now()).microsecondsSinceEpoch;
  if (microseconds > _lastMicroseconds) {
    _lastMicroseconds = microseconds;
    _sequence = 0;
  } else {
    _sequence++;
  }
  final suffix = String.fromCharCodes([
    for (var index = 0; index < 4; index++)
      _idAlphabet.codeUnitAt(_random.nextInt(_idAlphabet.length)),
  ]);
  return '${prefix}_${_lastMicroseconds}_${_sequence}_$suffix';
}

/// Returns a shelf title that no other book is already using.
///
/// Re-importing a file is deliberate, so the second copy keeps its own entry
/// and is numbered instead of being rejected or silently merged.
String uniqueLibraryTitle(
  String title,
  Set<String> takenTitles, {
  int maxLength = 120,
}) {
  final base = title.trim();
  if (base.isEmpty || !takenTitles.contains(base)) return base;
  for (var copy = 2; copy <= 999; copy++) {
    final marker = ' ($copy)';
    final room = maxLength - marker.length;
    final trimmed = base.length <= room ? base : _clampTitle(base, room);
    final candidate = '$trimmed$marker';
    if (!takenTitles.contains(candidate)) return candidate;
  }
  return base;
}

/// Trims to [maxLength] without splitting a surrogate pair.
String _clampTitle(String value, int maxLength) {
  if (maxLength <= 0) return '';
  var end = math.min(maxLength, value.length);
  final unit = value.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  return value.substring(0, end).trimRight();
}
