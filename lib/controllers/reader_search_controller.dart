import '../models/book.dart';
import '../services/book_search_service.dart';

/// Owns the one background search session used by an open search panel.
class ReaderSearchController {
  BookSearchSession? _active;

  BookSearchSession begin(Book book) {
    _active?.dispose();
    return _active = BookSearchService.openSession(book);
  }

  void end(BookSearchSession session) {
    session.dispose();
    if (identical(_active, session)) _active = null;
  }

  void dispose() {
    _active?.dispose();
    _active = null;
  }
}
