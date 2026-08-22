import 'dart:async';

/// Serializes progress writes so an older asynchronous save cannot overtake a
/// newer reading position.
class ReaderProgressController {
  Future<void> _queue = Future<void>.value();

  Future<void> get pending => _queue;

  Future<void> enqueue(
    Future<void> Function() writer, {
    required void Function(Object error, StackTrace stackTrace) onError,
  }) {
    _queue = _queue.then((_) => writer()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      onError(error, stackTrace);
    });
    return _queue;
  }
}
