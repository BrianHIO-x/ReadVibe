import 'package:flutter/foundation.dart';

/// Central selection state consumed by the reader, scroll positions and
/// selection-area widgets.
class ReaderSelectionController {
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);
  final ValueNotifier<bool> dragging = ValueNotifier<bool>(false);
  final ValueNotifier<bool> blocked = ValueNotifier<bool>(false);

  void setBlocked(bool value) {
    if (blocked.value != value) blocked.value = value;
  }

  void dispose() {
    dragging.value = false;
    active.value = false;
    active.dispose();
    dragging.dispose();
    blocked.dispose();
  }
}
