// Text folding shared by the shelf search and the in-book search.
//
// Chinese input methods emit full-width forms for ASCII punctuation, digits
// and Latin letters, and the same book can mix both widths across chapters.
// Searching should not depend on which width the keyboard happened to produce,
// so both the query and the text are folded onto the half-width forms first.

/// Start of the Unicode halfwidth-and-fullwidth forms that mirror ASCII.
const _fullWidthStart = 0xFF01;

/// Last mirrored form, the full-width tilde.
const _fullWidthEnd = 0xFF5E;

/// Distance between a full-width form and its ASCII counterpart.
const _fullWidthOffset = 0xFEE0;

/// Returns the half-width counterpart of [rune], or [rune] itself.
///
/// Only the mirrored ASCII block is folded. Characters such as `。` and `、`
/// keep their identity: they are Chinese punctuation in their own right rather
/// than a wide rendering of an ASCII character.
int foldFullWidthRune(int rune) =>
    rune >= _fullWidthStart && rune <= _fullWidthEnd
    ? rune - _fullWidthOffset
    : rune;

/// Folds every full-width ASCII form in [value].
///
/// The result always has the same number of runes as the input, so a caller
/// mapping a match back onto the original text can keep using rune positions.
String foldFullWidth(String value) {
  var needsFolding = false;
  for (final rune in value.runes) {
    if (rune >= _fullWidthStart && rune <= _fullWidthEnd) {
      needsFolding = true;
      break;
    }
  }
  if (!needsFolding) return value;
  return String.fromCharCodes([
    for (final rune in value.runes) foldFullWidthRune(rune),
  ]);
}
