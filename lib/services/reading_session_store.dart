import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';

enum ReadingSessionSurface {
  library,
  reader,
  privateShelf,
  privateReader,
}

/// Snapshot of the surface the reader was last on before leaving the app.
///
/// Persisted on every surface transition so an Android process kill does not
/// silently drop the user back onto the normal bookshelf homepage.
class ReadingSession {
  const ReadingSession({
    required this.surface,
    this.bookId,
    required this.updatedAt,
  });

  final ReadingSessionSurface surface;
  final String? bookId;
  final DateTime updatedAt;

  bool get isPrivate =>
      surface == ReadingSessionSurface.privateShelf ||
      surface == ReadingSessionSurface.privateReader;

  bool get isReading =>
      (surface == ReadingSessionSurface.reader ||
          surface == ReadingSessionSurface.privateReader) &&
      bookId != null &&
      bookId!.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'surface': surface.name,
    if (bookId != null && bookId!.isNotEmpty) 'bookId': bookId,
    'updatedAt': updatedAt.toIso8601String(),
  };

  static ReadingSession? fromJson(Object? source) {
    if (source is! Map) return null;
    final json = Map<String, dynamic>.from(source);
    final rawSurface = json['surface'];
    final surface = ReadingSessionSurface.values.asNameMap()[rawSurface];
    if (surface == null) return null;
    final rawBookId = json['bookId'];
    final bookId = rawBookId is String && rawBookId.trim().isNotEmpty
        ? rawBookId.trim()
        : null;
    final rawUpdated = json['updatedAt'];
    final updatedAt = rawUpdated is String
        ? DateTime.tryParse(rawUpdated) ?? DateTime.now()
        : DateTime.now();
    return ReadingSession(
      surface: surface,
      bookId: bookId,
      updatedAt: updatedAt,
    );
  }
}

/// Persists the active reading surface with latest-wins write serialization so
/// rapid route open/close transitions never race out of order.
class ReadingSessionStore {
  static const _sessionKey = 'readvibe_active_session';

  static int _nextVersion = 0;
  static int _latestVersion = 0;
  static Future<void> _writeQueue = Future<void>.value();

  Future<ReadingSession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ReadingSession.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<void> save(ReadingSession session) {
    final version = ++_nextVersion;
    _latestVersion = version;
    final payload = jsonEncode(session.toJson());
    return _enqueue(() async {
      if (_latestVersion != version) return;
      final prefs = await SharedPreferences.getInstance();
      if (_latestVersion != version) return;
      await prefs.setString(_sessionKey, payload);
    });
  }

  Future<void> markLibrary() => save(
    ReadingSession(
      surface: ReadingSessionSurface.library,
      updatedAt: DateTime.now(),
    ),
  );

  Future<void> markPrivateShelf() => save(
    ReadingSession(
      surface: ReadingSessionSurface.privateShelf,
      updatedAt: DateTime.now(),
    ),
  );

  Future<void> markReading(Book book) => save(
    ReadingSession(
      surface: book.isPrivate
          ? ReadingSessionSurface.privateReader
          : ReadingSessionSurface.reader,
      bookId: book.id,
      updatedAt: DateTime.now(),
    ),
  );

  Future<void> clearIfBook(
    Iterable<String> bookIds, {
    bool stayInPrivateShelf = false,
  }) async {
    final targets = bookIds.where((id) => id.isNotEmpty).toSet();
    if (targets.isEmpty) return;
    final current = await load();
    if (current == null ||
        current.bookId == null ||
        !targets.contains(current.bookId)) {
      return;
    }
    if (stayInPrivateShelf && current.surface == ReadingSessionSurface.privateReader) {
      await markPrivateShelf();
    } else {
      await markLibrary();
    }
  }

  Future<void> clearPrivateSession() async {
    final current = await load();
    if (current != null && current.isPrivate) {
      await markLibrary();
    }
  }

  static Future<void> _enqueue(Future<void> Function() action) {
    final operation = _writeQueue.then((_) => action());
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}
