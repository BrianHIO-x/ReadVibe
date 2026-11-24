part of '../epub_parser.dart';

class _CssRule {
  final String selector;
  final Map<String, String> declarations;
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
  final Expando<Map<String, String>> _declarationCache =
      Expando<Map<String, String>>('epub-css-declarations');

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
    final declarations = _declarationsFor(element);
    return declarations[property.toLowerCase()];
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

    final declarations = _declarationsFor(element);
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
    marginTopEm = _emLength(declarations['margin-top'], fallback: marginTopEm);
    marginBottomEm = _emLength(
      declarations['margin-bottom'],
      fallback: marginBottomEm,
    );
    final margin = declarations['margin'];
    if (margin != null) {
      final values = margin.trim().split(RegExp(r'\s+'));
      if (values.isNotEmpty) {
        marginTopEm = _emLength(values.first, fallback: marginTopEm);
        marginBottomEm = _emLength(
          values.length >= 3 ? values[2] : values.first,
          fallback: marginBottomEm,
        );
      }
    }
    colorArgb = _parseCssColor(declarations['color']) ?? colorArgb;
    backgroundColorArgb =
        _parseCssColor(declarations['background-color']) ?? backgroundColorArgb;
    final background =
        declarations['background-image'] ?? declarations['background'];
    final backgroundUrl = _cssUrl(background);
    if (backgroundUrl != null) {
      backgroundImagePath = resolveImage(backgroundUrl);
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

  Map<String, String> _declarationsFor(Element element) {
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
    final declarations = <String, String>{};
    for (final rule in matched) {
      declarations.addAll(rule.declarations);
    }
    final inline = element.attributes['style'];
    if (inline != null) declarations.addAll(_parseDeclarations(inline));
    _declarationCache[element] = declarations;
    return declarations;
  }
}

List<_CssRule> _parseCssRules(String cssText) {
  if (cssText.trim().isEmpty) return const <_CssRule>[];
  final clean = cssText
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(
        RegExp(r'@(?:import|charset)\b[^;]*;', caseSensitive: false),
        '',
      );
  final rules = <_CssRule>[];
  var order = 0;
  for (final match in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(clean)) {
    final body = match.group(2);
    if (body == null) continue;
    final declarations = _parseDeclarations(body);
    if (declarations.isEmpty) continue;
    for (final rawSelector in (match.group(1) ?? '').split(',')) {
      final selector = rawSelector.trim();
      if (selector.isEmpty || selector.startsWith('@')) continue;
      rules.add(
        _CssRule(
          selector: selector,
          declarations: declarations,
          specificity: _selectorSpecificity(selector),
          order: order++,
        ),
      );
    }
  }
  return rules;
}

Map<String, String> _parseDeclarations(String body) {
  final declarations = <String, String>{};
  for (final part in body.split(';')) {
    final colon = part.indexOf(':');
    if (colon <= 0) continue;
    final property = part.substring(0, colon).trim().toLowerCase();
    final value = part
        .substring(colon + 1)
        .trim()
        .replaceAll(RegExp(r'\s*!important\s*$', caseSensitive: false), '');
    if (property.isNotEmpty && value.isNotEmpty) declarations[property] = value;
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
  if (rawSelector.contains('+') || rawSelector.contains('~')) return false;
  // Keep :first-child: a table row's chapter/section styling uses it to indent
  // only the first cell. Every other pseudo-class is still ignored, exactly as
  // before, so the ordinary cascade is unchanged.
  final selector = rawSelector
      .replaceAll(RegExp(r'::[\w-]+(?:\([^)]*\))?'), '')
      .replaceAll(RegExp(r':(?!first-child\b)[\w-]+(?:\([^)]*\))?'), '')
      .replaceAll(RegExp(r'\[[^\]]+\]'), '')
      .trim();
  if (selector.isEmpty) return false;
  final tokens = selector
      .replaceAllMapped(RegExp(r'\s*>\s*'), (_) => ' > ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  final parts = <String>[];
  final childRelations = <bool>[];
  var nextIsChild = false;
  for (final token in tokens) {
    if (token == '>') {
      nextIsChild = true;
      continue;
    }
    if (parts.isNotEmpty) childRelations.add(nextIsChild);
    parts.add(token);
    nextIsChild = false;
  }
  if (parts.isEmpty || !_matchesCompoundSelector(element, parts.last)) {
    return false;
  }
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
  if (selector.contains(':first-child')) {
    final parent = element.parent;
    if (parent == null || parent.children.isEmpty) return false;
    if (!identical(parent.children.first, element)) return false;
  }
  final tag = RegExp(r'^[a-zA-Z][\w-]*').firstMatch(selector)?.group(0);
  if (tag != null &&
      (element.localName ?? '').toLowerCase() != tag.toLowerCase()) {
    return false;
  }
  final id = RegExp(r'#([\w-]+)').firstMatch(selector)?.group(1);
  if (id != null && element.id != id) return false;
  for (final match in RegExp(r'\.([\w-]+)').allMatches(selector)) {
    if (!element.classes.contains(match.group(1))) return false;
  }
  return true;
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
