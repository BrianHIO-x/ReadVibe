import 'package:flutter/foundation.dart';

import '../models/search_match.dart';

/// Serializes expensive searches and publishes results for the current query.
/// Submitting during active work replaces the pending submission.
class DocumentSearchController<T extends SearchMatch> extends ChangeNotifier {
  DocumentSearchController({required this.search, this.onError});

  final Future<List<T>> Function(String query) search;
  final void Function(Object, StackTrace)? onError;
  String _query = '';
  int _revision = 0;
  List<T> _results = const [];
  bool _searched = false;
  bool _failed = false;
  bool _running = false;
  bool _disposed = false;
  ({String query, int revision})? _pending;
  int? _activeRevision;
  Future<void>? _operation;

  List<T> get results => _results;
  bool get searching => _running;
  bool get searched => _searched;
  bool get failed => _failed;

  void setQuery(String value) {
    if (_disposed || value.trim() == _query) return;
    _query = value.trim();
    _revision++;
    _pending = null;
    _results = const [];
    _searched = false;
    _failed = false;
    notifyListeners();
  }

  Future<void> submit() {
    if (_disposed || _query.isEmpty) return Future<void>.value();
    if (_activeRevision == _revision) return _operation ?? Future<void>.value();
    _pending = (query: _query, revision: _revision);
    return _operation ??= _drain().whenComplete(() => _operation = null);
  }

  Future<void> _drain() async {
    _running = true;
    notifyListeners();
    while (!_disposed && _pending != null) {
      final request = _pending!;
      _pending = null;
      _activeRevision = request.revision;
      _failed = false;
      try {
        final matches = await search(request.query);
        if (!_disposed && request.revision == _revision) {
          _results = List<T>.unmodifiable(matches);
          _searched = true;
        }
      } on Object catch (error, stack) {
        if (!_disposed && request.revision == _revision) {
          _results = const [];
          _failed = true;
          _searched = true;
          onError?.call(error, stack);
        }
      }
      _activeRevision = null;
    }
    _running = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    super.dispose();
  }
}
