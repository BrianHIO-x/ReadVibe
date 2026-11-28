part of '../epub_parser.dart';

typedef _CssDeclaration = ({String property, String value, bool important});

class _CssRule {
  final String selector;
  final List<_CssDeclaration> declarations;
  final int specificity;
  final int order;

  const _CssRule({
    required this.selector,
    required this.declarations,
    required this.specificity,
    required this.order,
  });
}

class _EpubStyleResolver {
  final List<_CssRule> _rules;
  final String? Function(String rawUrl) resolveImage;
  final String? Function(String rawFamily) resolveFontFamily;
  final Expando<
    ({Map<String, String> map, List<_CssDeclaration> ordered})
  >
  _declarationCache = Expando('epub-css-declarations');

  _EpubStyleResolver(
    String cssText, {
    required Map<String, List<_CssRule>> rulesCache,
    required this.resolveImage,
    required this.resolveFontFamily,
  }) : _rules = rulesCache.putIfAbsent(
         cssText,
         () => List<_CssRule>.unmodifiable(_parseCssRules(cssText)),
       );

  bool isHidden(Element element) {
    final display = propertyFor(element, 'display')?.toLowerCase();
    final visibility = propertyFor(element, 'visibility')?.toLowerCase();
    return display == 'none' || visibility == 'hidden';
  }

  String? propertyFor(Element element, String property) {
    return _declarationsFor(element).map[property.toLowerCase()];
  }

  EpubContentStyle styleFor(
    Element element, {
    required EpubContentStyle inherited,
  }) {
    final tag = element.localName;
    var fontScale = inherited.fontScale;
    var fontFamily = inherited.fontFamily;
    var fontWeight = inherited.fontWeight;
    var italic = inherited.italic;
    var underline = inherited.underline;
    var textAlign = inherited.textAlign;
    var lineHeightScale = inherited.lineHeightScale;
    var letterSpacingEm = inherited.letterSpacingEm;
    var colorArgb = inherited.colorArgb;
    var backgroundColorArgb = inherited.backgroundColorArgb;
    var textIndentEm = _blockElements.contains(tag)
        ? 2.0
        : inherited.textIndentEm;
    var marginTopEm = 0.0;
    var marginBottomEm = 0.0;
    String? backgroundImagePath;

    if (tag == 'h1') {
      fontScale = 1.55;
      fontWeight = 700;
      textIndentEm = 0;
      marginTopEm = 0.8;
      marginBottomEm = 0.55;
    } else if (tag == 'h2') {
      fontScale = 1.35;
      fontWeight = 700;
      textIndentEm = 0;
      marginTopEm = 0.7;
      marginBottomEm = 0.45;
    } else if (tag == 'h3' || tag == 'h4' || tag == 'h5' || tag == 'h6') {
      fontScale = 1.15;
      fontWeight = 600;
      textIndentEm = 0;
      marginTopEm = 0.6;
      marginBottomEm = 0.35;
    } else if (tag == 'blockquote') {
      textIndentEm = 0;
      marginTopEm = 0.4;
      marginBottomEm = 0.4;
    } else if (tag == 'li' || tag == 'figcaption' || tag == 'pre') {
      textIndentEm = 0;
    } else if (tag == 'strong' || tag == 'b') {
      fontWeight = math.max(700, fontWeight);
    } else if (tag == 'em' || tag == 'i' || tag == 'cite') {
      italic = true;
    } else if (tag == 'u') {
      underline = true;
    } else if (tag == 'small') {
      fontScale *= 0.85;
    } else if (tag == 'big') {
      fontScale *= 1.15;
    }

    final resolved = _declarationsFor(element);
    final declarations = resolved.map;
    final declaredFamily = declarations['font-family'];
    if (declaredFamily != null) {
      fontFamily = resolveFontFamily(declaredFamily) ?? fontFamily;
    }
    fontScale = _fontScale(declarations['font-size'], fontScale);
    fontWeight = _fontWeight(declarations['font-weight'], fontWeight);
    final fontStyle = declarations['font-style']?.toLowerCase();
    if (fontStyle != null) {
      italic = fontStyle.contains('italic') || fontStyle.contains('oblique');
    }
    final decoration = declarations['text-decoration']?.toLowerCase();
    if (decoration != null) underline = decoration.contains('underline');
    textAlign = _textAlign(declarations['text-align']) ?? textAlign;
    lineHeightScale = _lineHeightScale(
      declarations['line-height'],
      lineHeightScale,
      fontScale,
    );
    letterSpacingEm = _emLength(
      declarations['letter-spacing'],
      fallback: letterSpacingEm,
    );
    textIndentEm = _emLength(
      declarations['text-indent'],
      fallback: textIndentEm,
    );
    colorArgb = _parseCssColor(declarations['color']) ?? colorArgb;

    // Replay ordered shorthand/longhand declarations in cascade order so
    // `margin: 0` followed by `margin-top: 1em` vs reversed declaration order
    // matches standard CSS cascade semantics.
    for (final entry in resolved.ordered) {
      switch (entry.property) {
        case 'margin-top':
          marginTopEm = _emLength(entry.value, fallback: marginTopEm);
        case 'margin-bottom':
          marginBottomEm = _emLength(entry.value, fallback: marginBottomEm);
        case 'margin':
          final values = entry.value.trim().split(RegExp(r'\s+'));
          if (values.isNotEmpty) {
            marginTopEm = _emLength(values.first, fallback: marginTopEm);
            marginBottomEm = _emLength(
              values.length >= 3 ? values[2] : values.first,
              fallback: marginBottomEm,
            );
          }
        case 'background-color':
          final parsed = _parseCssColor(entry.value);
          if (parsed != null) {
            backgroundColorArgb = parsed;
          } else if (entry.value.trim().toLowerCase() == 'transparent') {
            backgroundColorArgb = null;
          }
        case 'background-image':
          if (entry.value.trim().toLowerCase() == 'none') {
            backgroundImagePath = null;
          } else {
            final backgroundUrl = _cssUrl(entry.value);
            if (backgroundUrl != null) {
              backgroundImagePath = resolveImage(backgroundUrl);
            }
          }
        case 'background':
          if (entry.value.trim().toLowerCase() == 'none') {
            backgroundColorArgb = null;
            backgroundImagePath = null;
          } else {
            final bgColor = _parseBackgroundColor(entry.value);
            if (bgColor != null) backgroundColorArgb = bgColor;
            final backgroundUrl = _cssUrl(entry.value);
            if (backgroundUrl != null) {
              backgroundImagePath = resolveImage(backgroundUrl);
            }
          }
      }
    }

    return EpubContentStyle(
      fontFamily: fontFamily,
      fontScale: fontScale.clamp(0.6, 2.5),
      fontWeight: fontWeight.clamp(100, 900),
      italic: italic,
      underline: underline,
      textAlign: textAlign,
      lineHeightScale: lineHeightScale.clamp(0.7, 1.8),
      letterSpacingEm: letterSpacingEm.clamp(-0.15, 0.5),
      textIndentEm: textIndentEm.clamp(0, 8),
      marginTopEm: marginTopEm.clamp(0, 6),
      marginBottomEm: marginBottomEm.clamp(0, 6),
      colorArgb: colorArgb,
      backgroundColorArgb: backgroundColorArgb,
      backgroundImagePath: backgroundImagePath,
    );
  }

  ({Map<String, String> map, List<_CssDeclaration> ordered}) _declarationsFor(
    Element element,
  ) {
    final cached = _declarationCache[element];
    if (cached != null) return cached;
    final matched =
        _rules
            .where((rule) => _matchesSelector(element, rule.selector))
            .toList()
          ..sort((a, b) {
            final specificity = a.specificity.compareTo(b.specificity);
            return specificity != 0 ? specificity : a.order.compareTo(b.order);
          });
    final normal = <_CssDeclaration>[];
    final important = <_CssDeclaration>[];
    for (final rule in matched) {
      for (final decl in rule.declarations) {
        (decl.important ? important : normal).add(decl);
      }
    }
    final inline = element.attributes['style'];
    if (inline != null && inline.isNotEmpty) {
      for (final decl in _parseDeclarationList(inline)) {
        (decl.important ? important : normal).add(decl);
      }
    }
    final ordered = <_CssDeclaration>[...normal, ...important];
    final map = <String, String>{};
    for (final decl in ordered) {
      map[decl.property] = decl.value;
    }
    final result = (map: map, ordered: ordered);
    _declarationCache[element] = result;
    return result;
  }
}

List<_CssRule> _parseCssRules(String cssText) {
  if (cssText.trim().isEmpty) return const <_CssRule>[];
  final withoutCdata = cssText
      .replaceAll('<![CDATA[', '')
      .replaceAll(']]>', '');
  final clean = _stripCssComments(withoutCdata);
  final rules = <_CssRule>[];
  var order = 0;
  _collectCssRules(clean, rules, () => order++);
  return rules;
}

String _stripCssComments(String input) {
  final out = StringBuffer();
  var quote = '';
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (quote.isNotEmpty) {
      out.write(ch);
      if (ch == r'\' && i + 1 < input.length) {
        i++;
        out.write(input[i]);
      } else if (ch == quote) {
        quote = '';
      }
      i++;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      out.write(ch);
      i++;
      continue;
    }
    if (ch == '/' && i + 1 < input.length && input[i + 1] == '*') {
      final close = input.indexOf('*/', i + 2);
      if (close < 0) break;
      out.write(' ');
      i = close + 2;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

void _collectCssRules(
  String css,
  List<_CssRule> rules,
  int Function() nextOrder, {
  int depth = 0,
}) {
  if (depth > 8) return;
  var i = 0;
  while (i < css.length) {
    while (i < css.length &&
        (_isCssWhitespace(css.codeUnitAt(i)) || css[i] == ';')) {
      i++;
    }
    if (i >= css.length) break;

    final start = i;
    var quote = '';
    var parenDepth = 0;
    var bracketDepth = 0;
    var hitBrace = false;
    var hitSemicolon = false;
    while (i < css.length) {
      final ch = css[i];
      if (quote.isNotEmpty) {
        if (ch == r'\' && i + 1 < css.length) {
          i += 2;
          continue;
        }
        if (ch == quote) quote = '';
        i++;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '(') {
        parenDepth++;
      } else if (ch == ')' && parenDepth > 0) {
        parenDepth--;
      } else if (ch == '[') {
        bracketDepth++;
      } else if (ch == ']' && bracketDepth > 0) {
        bracketDepth--;
      } else if (parenDepth == 0 && bracketDepth == 0) {
        if (ch == '{') {
          hitBrace = true;
          break;
        }
        if (ch == ';') {
          hitSemicolon = true;
          break;
        }
        if (ch == '}') {
          i++;
          break;
        }
      }
      i++;
    }
    if (hitSemicolon || !hitBrace) {
      i++;
      continue;
    }

    final prelude = css.substring(start, i).trim();
    final bodyStart = i + 1;
    var braceDepth = 1;
    quote = '';
    var j = bodyStart;
    while (j < css.length && braceDepth > 0) {
      final ch = css[j];
      if (quote.isNotEmpty) {
        if (ch == r'\' && j + 1 < css.length) {
          j += 2;
          continue;
        }
        if (ch == quote) quote = '';
        j++;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '{') {
        braceDepth++;
      } else if (ch == '}') {
        braceDepth--;
        if (braceDepth == 0) break;
      }
      j++;
    }
    final body = css.substring(bodyStart, j);
    i = j + 1;

    if (prelude.isEmpty) continue;
    if (prelude.startsWith('@')) {
      final keyword = RegExp(
        r'^@([a-zA-Z-]+)',
      ).firstMatch(prelude)?.group(1)?.toLowerCase();
      if (keyword == 'media') {
        if (_mediaQueryAppliesToScreen(prelude)) {
          _collectCssRules(body, rules, nextOrder, depth: depth + 1);
        }
      } else if (keyword == 'supports' ||
          keyword == 'layer' ||
          keyword == 'document' ||
          keyword == 'container') {
        _collectCssRules(body, rules, nextOrder, depth: depth + 1);
      }
      continue;
    }

    final declarations = _parseDeclarationList(body);
    if (declarations.isEmpty) continue;
    for (final rawSelector in _splitTopLevel(prelude, ',')) {
      final selector = rawSelector.trim();
      if (selector.isEmpty || selector.startsWith('@')) continue;
      rules.add(
        _CssRule(
          selector: selector,
          declarations: declarations,
          specificity: _selectorSpecificity(selector),
          order: nextOrder(),
        ),
      );
    }
  }
}

bool _isCssWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0d ||
    codeUnit == 0x0c;

bool _mediaQueryAppliesToScreen(String prelude) {
  final raw = prelude
      .replaceFirst(RegExp(r'^@media\b', caseSensitive: false), '')
      .trim()
      .toLowerCase();
  if (raw.isEmpty) return true;
  for (final query in raw.split(',')) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.contains('prefers-color-scheme') ||
        trimmed.contains('inverted-colors')) {
      continue;
    }
    if (trimmed.startsWith('(')) return true;
    final firstWord = RegExp(
      r'^(?:(?:only|not)\s+)?([a-z-]+)',
    ).firstMatch(trimmed);
    if (firstWord == null) continue;
    final mediaType = firstWord.group(1);
    final isNegated = trimmed.startsWith('not ');
    if (mediaType == 'all' || mediaType == 'screen') {
      if (!isNegated) return true;
    } else if (mediaType == 'amzn-mobi' ||
        mediaType == 'amzn-kf8' ||
        mediaType == 'print' ||
        mediaType == 'speech' ||
        mediaType == 'aural' ||
        mediaType == 'braille' ||
        mediaType == 'tty' ||
        mediaType == 'tv' ||
        mediaType == 'projection') {
      if (isNegated) return true;
    }
  }
  return false;
}

List<String> _splitTopLevel(String input, String separator) {
  final result = <String>[];
  var quote = '';
  var parenDepth = 0;
  var bracketDepth = 0;
  var start = 0;
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (quote.isNotEmpty) {
      if (ch == r'\' && i + 1 < input.length) {
        i++;
        continue;
      }
      if (ch == quote) quote = '';
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == '(') {
      parenDepth++;
    } else if (ch == ')' && parenDepth > 0) {
      parenDepth--;
    } else if (ch == '[') {
      bracketDepth++;
    } else if (ch == ']' && bracketDepth > 0) {
      bracketDepth--;
    } else if (ch == separator && parenDepth == 0 && bracketDepth == 0) {
      result.add(input.substring(start, i));
      start = i + 1;
    }
  }
  result.add(input.substring(start));
  return result;
}

int _indexOfTopLevelColon(String part) {
  var quote = '';
  var parenDepth = 0;
  for (var i = 0; i < part.length; i++) {
    final ch = part[i];
    if (quote.isNotEmpty) {
      if (ch == r'\' && i + 1 < part.length) {
        i++;
        continue;
      }
      if (ch == quote) quote = '';
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == '(') {
      parenDepth++;
    } else if (ch == ')' && parenDepth > 0) {
      parenDepth--;
    } else if (ch == ':' && parenDepth == 0) {
      return i;
    }
  }
  return -1;
}

List<_CssDeclaration> _parseDeclarationList(String body) {
  final declarations = <_CssDeclaration>[];
  for (final part in _splitTopLevel(body, ';')) {
    final colon = _indexOfTopLevelColon(part);
    if (colon <= 0) continue;
    final property = part.substring(0, colon).trim().toLowerCase();
    var value = part.substring(colon + 1).trim();
    final importantPattern = RegExp(
      r'\s*!\s*important\s*$',
      caseSensitive: false,
    );
    final important = importantPattern.hasMatch(value);
    if (important) {
      value = value.replaceFirst(importantPattern, '').trim();
    }
    if (property.isNotEmpty && value.isNotEmpty) {
      declarations.add((
        property: property,
        value: value,
        important: important,
      ));
    }
  }
  return declarations;
}

Map<String, String> _parseDeclarations(String body) {
  final declarations = <String, String>{};
  for (final entry in _parseDeclarationList(body)) {
    declarations[entry.property] = entry.value;
  }
  return declarations;
}

int _selectorSpecificity(String selector) {
  final ids = RegExp(r'#[\w-]+').allMatches(selector).length;
  final classes = RegExp(
    r'\.[\w-]+|\[[^\]]+\]|:[\w-]+',
  ).allMatches(selector).length;
  final tags = selector
      .split(RegExp(r'\s+|>'))
      .where((part) => RegExp(r'^[a-zA-Z][\w-]*').hasMatch(part))
      .length;
  return ids * 100 + classes * 10 + tags;
}

bool _matchesSelector(Element element, String rawSelector) {
  final selector = rawSelector.trim();
  if (selector.isEmpty) return false;
  final parts = <String>[];
  final childRelations = <bool>[];
  final buffer = StringBuffer();
  var quote = '';
  var bracketDepth = 0;
  var parenDepth = 0;
  var pendingChild = false;

  void flushPart() {
    final token = buffer.toString().trim();
    buffer.clear();
    if (token.isEmpty) return;
    if (parts.isNotEmpty) childRelations.add(pendingChild);
    parts.add(token);
    pendingChild = false;
  }

  for (var i = 0; i < selector.length; i++) {
    final ch = selector[i];
    if (quote.isNotEmpty) {
      buffer.write(ch);
      if (ch == r'\' && i + 1 < selector.length) {
        i++;
        buffer.write(selector[i]);
      } else if (ch == quote) {
        quote = '';
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      buffer.write(ch);
      continue;
    }
    if (ch == '[') {
      bracketDepth++;
      buffer.write(ch);
      continue;
    }
    if (ch == ']' && bracketDepth > 0) {
      bracketDepth--;
      buffer.write(ch);
      continue;
    }
    if (ch == '(') {
      parenDepth++;
      buffer.write(ch);
      continue;
    }
    if (ch == ')' && parenDepth > 0) {
      parenDepth--;
      buffer.write(ch);
      continue;
    }
    if (bracketDepth == 0 && parenDepth == 0) {
      if (ch == '+' || ch == '~') return false;
      if (ch == '>') {
        flushPart();
        pendingChild = true;
        continue;
      }
      if (_isCssWhitespace(ch.codeUnitAt(0))) {
        flushPart();
        continue;
      }
    }
    buffer.write(ch);
  }
  flushPart();
  if (pendingChild || parts.isEmpty) return false;
  if (!_matchesCompoundSelector(element, parts.last)) return false;

  var matchedElement = element;
  for (var index = parts.length - 2; index >= 0; index--) {
    Element? candidate = matchedElement.parent;
    if (childRelations[index]) {
      if (candidate == null ||
          !_matchesCompoundSelector(candidate, parts[index])) {
        return false;
      }
    } else {
      while (candidate != null &&
          !_matchesCompoundSelector(candidate, parts[index])) {
        candidate = candidate.parent;
      }
      if (candidate == null) return false;
    }
    matchedElement = candidate;
  }
  return true;
}

bool _matchesCompoundSelector(Element element, String selector) {
  if (selector == '*') return true;
  var index = 0;

  bool readTagOrUniversal() {
    final start = index;
    if (selector[index] == '*') {
      index++;
      if (index < selector.length && selector[index] == '|') {
        index++;
        return readTagOrUniversal();
      }
      return true;
    }
    while (index < selector.length) {
      final ch = selector[index];
      if (ch == '#' ||
          ch == '.' ||
          ch == '[' ||
          ch == ':' ||
          ch == '*') {
        break;
      }
      index++;
    }
    var tagName = selector.substring(start, index);
    if (index < selector.length && selector[index] == '|') {
      index++;
      return readTagOrUniversal();
    }
    final pipe = tagName.indexOf('|');
    if (pipe >= 0) tagName = tagName.substring(pipe + 1);
    return tagName == '*' ||
        (element.localName ?? '').toLowerCase() == tagName.toLowerCase();
  }

  String readIdent() {
    final start = index;
    while (index < selector.length) {
      final ch = selector[index];
      if (ch == '#' ||
          ch == '.' ||
          ch == '[' ||
          ch == ':' ||
          ch == '(' ||
          ch == ')' ||
          _isCssWhitespace(ch.codeUnitAt(0))) {
        break;
      }
      index++;
    }
    return selector.substring(start, index);
  }

  final first = selector[0];
  if (first != '#' && first != '.' && first != '[' && first != ':') {
    if (!readTagOrUniversal()) return false;
  }

  while (index < selector.length) {
    final marker = selector[index];
    if (marker == '#') {
      index++;
      final id = readIdent();
      if (id.isEmpty || element.id != id) return false;
    } else if (marker == '.') {
      index++;
      final cls = readIdent();
      if (cls.isEmpty || !element.classes.contains(cls)) return false;
    } else if (marker == '[') {
      final close = _findClosingDelimiter(selector, index + 1, '[', ']');
      if (close < 0) return false;
      final expr = selector.substring(index + 1, close);
      index = close + 1;
      if (!_matchesAttributeSelector(element, expr)) return false;
    } else if (marker == ':') {
      index++;
      if (index < selector.length && selector[index] == ':') {
        // Pseudo-elements (::first-letter, ::before, etc.) cannot be modeled
        // on the enclosing block without corrupting the entire paragraph style.
        return false;
      }
      final pseudo = readIdent().toLowerCase();
      String? argument;
      if (index < selector.length && selector[index] == '(') {
        final close = _findClosingDelimiter(selector, index + 1, '(', ')');
        if (close < 0) return false;
        argument = selector.substring(index + 1, close).trim();
        index = close + 1;
      }
      if (pseudo.isEmpty) return false;
      if (!_matchesPseudoClass(element, pseudo, argument)) return false;
    } else {
      return false;
    }
  }
  return true;
}

int _findClosingDelimiter(
  String input,
  int start,
  String open,
  String close,
) {
  var depth = 1;
  var quote = '';
  for (var i = start; i < input.length; i++) {
    final ch = input[i];
    if (quote.isNotEmpty) {
      if (ch == r'\' && i + 1 < input.length) {
        i++;
        continue;
      }
      if (ch == quote) quote = '';
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == open) {
      depth++;
    } else if (ch == close) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

bool _matchesPseudoClass(Element element, String rawName, String? argument) {
  switch (rawName) {
    case 'first-child':
      final parent = element.parent;
      return parent != null &&
          parent.children.isNotEmpty &&
          identical(parent.children.first, element);
    case 'last-child':
      final parent = element.parent;
      return parent != null &&
          parent.children.isNotEmpty &&
          identical(parent.children.last, element);
    case 'only-child':
      final parent = element.parent;
      return parent != null &&
          parent.children.length == 1 &&
          identical(parent.children.single, element);
    case 'root':
      return element.parent == null;
    case 'link':
    case 'any-link':
      return element.localName == 'a' && element.attributes.containsKey('href');
    case 'not':
      if (argument == null || argument.isEmpty) return false;
      for (final sub in _splitTopLevel(argument, ',')) {
        final trimmed = sub.trim();
        if (trimmed.isNotEmpty && _matchesSelector(element, trimmed)) {
          return false;
        }
      }
      return true;
    default:
      return false;
  }
}

bool _matchesAttributeSelector(Element element, String expr) {
  final match = RegExp(
    r'^\s*([^\s=~|^$*\]]+)\s*(?:([~|^$*]?=)\s*(.+?)\s*)?$',
  ).firstMatch(expr);
  if (match == null) return false;
  var attrName = match.group(1)!;
  final pipe = attrName.indexOf('|');
  if (pipe >= 0) attrName = attrName.substring(pipe + 1);
  final op = match.group(2);
  var rawExpected = match.group(3);
  final actual = _htmlAttributeCaseInsensitive(element, attrName);
  if (op == null) return actual != null;
  if (actual == null || rawExpected == null) return false;
  var caseInsensitive = false;
  if (rawExpected.length > 2 &&
      (rawExpected.endsWith(' i') || rawExpected.endsWith(' I'))) {
    final beforeFlag = rawExpected.substring(0, rawExpected.length - 1).trim();
    if ((beforeFlag.startsWith('"') && beforeFlag.endsWith('"')) ||
        (beforeFlag.startsWith("'") && beforeFlag.endsWith("'"))) {
      rawExpected = beforeFlag;
      caseInsensitive = true;
    }
  }
  if (rawExpected.length >= 2 &&
      ((rawExpected.startsWith('"') && rawExpected.endsWith('"')) ||
          (rawExpected.startsWith("'") && rawExpected.endsWith("'")))) {
    rawExpected = rawExpected.substring(1, rawExpected.length - 1);
  }
  final lhs = caseInsensitive ? actual.toLowerCase() : actual;
  final rhs = caseInsensitive ? rawExpected.toLowerCase() : rawExpected;
  switch (op) {
    case '=':
      return lhs == rhs;
    case '~=':
      return rhs.isNotEmpty &&
          !rhs.contains(RegExp(r'\s')) &&
          lhs.split(RegExp(r'\s+')).contains(rhs);
    case '|=':
      return lhs == rhs || lhs.startsWith('$rhs-');
    case '^=':
      return rhs.isNotEmpty && lhs.startsWith(rhs);
    case r'$=':
      return rhs.isNotEmpty && lhs.endsWith(rhs);
    case '*=':
      return rhs.isNotEmpty && lhs.contains(rhs);
    default:
      return false;
  }
}

String? _htmlAttributeCaseInsensitive(Element element, String name) {
  final direct = element.attributes[name];
  if (direct != null) return direct;
  final lower = name.toLowerCase();
  for (final entry in element.attributes.entries) {
    final key = entry.key.toString().toLowerCase();
    if (key == lower || key.endsWith(':$lower')) return entry.value;
  }
  return null;
}

double _fontScale(String? value, double inherited) {
  if (value == null) return inherited;
  final normalized = value.trim().toLowerCase();
  const keywords = <String, double>{
    'xx-small': 0.6,
    'x-small': 0.75,
    'small': 0.875,
    'medium': 1,
    'large': 1.125,
    'x-large': 1.35,
    'xx-large': 1.6,
    'smaller': 0.85,
    'larger': 1.2,
  };
  final keyword = keywords[normalized];
  if (keyword != null) {
    return normalized == 'smaller' || normalized == 'larger'
        ? inherited * keyword
        : keyword;
  }
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite) return inherited;
  if (normalized.endsWith('%')) return inherited * number / 100;
  if (normalized.endsWith('rem')) return number;
  if (normalized.endsWith('em')) return inherited * number;
  if (normalized.endsWith('pt')) return number / 12;
  if (normalized.endsWith('px')) return number / 16;
  return number;
}

int _fontWeight(String? value, int inherited) {
  if (value == null) return inherited;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'bold' || normalized == 'bolder') {
    return math.max(700, inherited);
  }
  if (normalized == 'normal') return 400;
  if (normalized == 'lighter') return math.max(100, inherited - 200);
  return double.tryParse(normalized)?.round().clamp(100, 900) ?? inherited;
}

String? _textAlign(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'left' || 'start' => 'start',
    'right' || 'end' => 'end',
    'center' => 'center',
    'justify' => 'justify',
    _ => null,
  };
}

double _lineHeightScale(String? value, double inherited, double fontScale) {
  if (value == null || value.trim().toLowerCase() == 'normal') return inherited;
  final normalized = value.trim().toLowerCase();
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite || number <= 0) return inherited;
  final ratio = normalized.endsWith('%')
      ? number / 100
      : normalized.endsWith('px')
      ? number / math.max(1, 16 * fontScale)
      : normalized.endsWith('pt')
      ? number / math.max(1, 12 * fontScale)
      : number;
  return ratio / 1.5;
}

double _emLength(String? value, {required double fallback}) {
  if (value == null) return fallback;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'normal' || normalized == 'auto') return fallback;
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite) return fallback;
  if (normalized.endsWith('px')) return number / 16;
  if (normalized.endsWith('pt')) return number / 12;
  if (normalized.endsWith('%')) return number / 100;
  return number;
}

double? _cssOrAttributePixels(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toLowerCase();
  if (normalized.endsWith('%') || normalized == 'auto') return null;
  final number = double.tryParse(
    normalized.replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
  if (number == null || !number.isFinite || number <= 0) return null;
  if (normalized.endsWith('em') || normalized.endsWith('rem')) {
    return number * 16;
  }
  if (normalized.endsWith('pt')) return number * 4 / 3;
  return number;
}

int? _parseCssColor(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'transparent' || normalized == 'currentcolor') return null;
  const names = <String, int>{
    'black': 0xff000000,
    'white': 0xffffffff,
    'red': 0xffff0000,
    'green': 0xff008000,
    'blue': 0xff0000ff,
    'gray': 0xff808080,
    'grey': 0xff808080,
    'yellow': 0xffffff00,
    'orange': 0xffffa500,
    'purple': 0xff800080,
    'brown': 0xffa52a2a,
  };
  if (names.containsKey(normalized)) return names[normalized];
  if (normalized.startsWith('#')) {
    final hex = normalized.substring(1);
    if (hex.length == 3) {
      final expanded = hex.split('').map((part) => '$part$part').join();
      final parsed = int.tryParse(expanded, radix: 16);
      return parsed == null ? null : 0xff000000 | parsed;
    }
    if (hex.length == 6) {
      final parsed = int.tryParse(hex, radix: 16);
      return parsed == null ? null : 0xff000000 | parsed;
    }
    if (hex.length == 8) {
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed != null) {
        final rgb = parsed >> 8;
        final alpha = parsed & 0xff;
        return (alpha << 24) | rgb;
      }
    }
  }
  final rgb = RegExp(r'rgba?\(([^)]+)\)').firstMatch(normalized)?.group(1);
  if (rgb != null) {
    final parts = rgb.split(',').map((part) => part.trim()).toList();
    if (parts.length >= 3) {
      int channel(String part) {
        if (part.endsWith('%')) {
          return ((double.tryParse(part.substring(0, part.length - 1)) ?? 0) *
                  2.55)
              .round()
              .clamp(0, 255);
        }
        return (double.tryParse(part) ?? 0).round().clamp(0, 255);
      }

      final alpha = parts.length >= 4
          ? (parts[3].endsWith('%')
                ? ((double.tryParse(
                                parts[3].substring(0, parts[3].length - 1),
                              ) ??
                              100) *
                          2.55)
                      .round()
                      .clamp(0, 255)
                : ((double.tryParse(parts[3]) ?? 1) * 255).round().clamp(
                    0,
                    255,
                  ))
          : 255;
      return (alpha << 24) |
          (channel(parts[0]) << 16) |
          (channel(parts[1]) << 8) |
          channel(parts[2]);
    }
  }
  return null;
}

String? _cssUrl(String? value) {
  if (value == null) return null;
  return RegExp(
    r'''url\(\s*["']?([^"')]+)["']?\s*\)''',
    caseSensitive: false,
  ).firstMatch(value)?.group(1)?.trim();
}

int? _parseBackgroundColor(String value) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  var parenDepth = 0;
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (quote.isNotEmpty) {
      buffer.write(ch);
      if (ch == r'\' && i + 1 < value.length) {
        i++;
        buffer.write(value[i]);
      } else if (ch == quote) {
        quote = '';
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      buffer.write(ch);
    } else if (ch == '(') {
      parenDepth++;
      buffer.write(ch);
    } else if (ch == ')' && parenDepth > 0) {
      parenDepth--;
      buffer.write(ch);
    } else if (_isCssWhitespace(ch.codeUnitAt(0)) && parenDepth == 0) {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
    } else {
      buffer.write(ch);
    }
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  for (final token in tokens) {
    if (token.toLowerCase().startsWith('url(')) continue;
    final parsed = _parseCssColor(token);
    if (parsed != null) return parsed;
  }
  return null;
}
