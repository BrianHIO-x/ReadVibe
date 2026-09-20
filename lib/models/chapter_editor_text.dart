/// Horizontal spacing in the plain-text editor uses one Chinese character
/// cell per character. Keep line breaks and zero-width text controls intact.
final _editorHorizontalSpace = RegExp(
  r'[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F]',
);

/// Each replacement is exactly one UTF-16 code unit, so reader anchors,
/// selections, and composing offsets stay valid without remapping.
String normalizeChapterEditorSpaces(String text) =>
    text.replaceAll(_editorHorizontalSpace, '\u3000');
