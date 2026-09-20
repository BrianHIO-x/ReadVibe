import 'package:flutter/services.dart';

import '../models/chapter_editor_text.dart';

/// Converts committed keyboard and pasted spaces, leaving IME candidates alone.
class ChapterEditorInputFormatter extends TextInputFormatter {
  const ChapterEditorInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final text = normalizeChapterEditorSpaces(newValue.text);
    return text == newValue.text ? newValue : newValue.copyWith(text: text);
  }
}
