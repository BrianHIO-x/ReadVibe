import 'package:flutter/foundation.dart';

/// Holds temporary multi-select state on the library shelf.
class LibrarySelectionController extends ChangeNotifier {
  bool _isSelecting = false;
  final Set<String> _selectedIds = <String>{};

  bool get isSelecting => _isSelecting;
  Set<String> get selectedIds => Set<String>.unmodifiable(_selectedIds);
  int get count => _selectedIds.length;
  bool isSelected(String bookId) => _selectedIds.contains(bookId);

  bool isAllSelected(Iterable<String> visibleBookIds) {
    final ids = visibleBookIds.where((id) => id.isNotEmpty).toList();
    return ids.isNotEmpty && ids.every(_selectedIds.contains);
  }

  void enter([String? initialBookId]) {
    var changed = !_isSelecting;
    _isSelecting = true;
    if (initialBookId != null &&
        initialBookId.isNotEmpty &&
        _selectedIds.add(initialBookId)) {
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void exit() {
    if (!_isSelecting && _selectedIds.isEmpty) return;
    _isSelecting = false;
    _selectedIds.clear();
    notifyListeners();
  }

  void toggle(String bookId) {
    if (bookId.isEmpty) return;
    _isSelecting = true;
    if (!_selectedIds.remove(bookId)) {
      _selectedIds.add(bookId);
    }
    notifyListeners();
  }

  void selectAll(Iterable<String> bookIds) {
    final valid = bookIds.where((id) => id.isNotEmpty).toSet();
    final allSelected = valid.isNotEmpty && valid.every(_selectedIds.contains);
    var changed = !_isSelecting;
    _isSelecting = true;
    if (allSelected) {
      if (_selectedIds.isNotEmpty) {
        _selectedIds.clear();
        changed = true;
      }
    } else {
      for (final id in valid) {
        changed |= _selectedIds.add(id);
      }
    }
    if (changed) notifyListeners();
  }

  void retainValid(Set<String> validBookIds) {
    final before = _selectedIds.length;
    _selectedIds.removeWhere((id) => !validBookIds.contains(id));
    if (_selectedIds.length != before) notifyListeners();
  }
}
