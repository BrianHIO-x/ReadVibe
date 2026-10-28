import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Reading text aligned to both margins.
///
/// Every line that wraps on its own reaches the right margin, and the last
/// line of each paragraph keeps its natural length. Chinese text has almost
/// no spaces for [TextAlign.justify] to widen, and that alignment also drops a
/// line's leading whitespace, which is how paragraphs are indented here. So
/// the text is laid out as given to find where it wraps, then each wrapped
/// line gets its own letter spacing that spreads the spare width between its
/// characters. Line breaks stay exactly where they were, and with them the
/// pagination and every position measured on the plain text.
///
/// A full-width closing mark at the end of a line, a comma or a closing quote
/// among them, keeps only the left half of its square there. Its ink sits in
/// that half, and the empty half would read as a ragged right edge.
class ReaderJustifiedText extends StatefulWidget {
  const ReaderJustifiedText(
    this.text, {
    super.key,
    this.style,
    this.strutStyle,
    this.textScaler,
    this.settledStyle,
    this.nearby = true,
  });

  final InlineSpan text;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextScaler? textScaler;

  /// The inherited text style this text rests at. While an animated default
  /// text style is still on its way there, the lines stay unjustified, so no
  /// frame of that animation pays for the extra layouts.
  final TextStyle? settledStyle;

  /// Whether this text is in view or close to it. Scroll mode lays out every
  /// chapter to know how long the book is, and a chapter far from view keeps
  /// only a justification already worked out for it.
  final bool nearby;

  @override
  State<ReaderJustifiedText> createState() => _ReaderJustifiedTextState();
}

class _ReaderJustifiedTextState extends State<ReaderJustifiedText> {
  /// The list this text waits on to come to rest.
  ScrollPosition? _scrolling;

  @override
  void dispose() {
    _scrolling?.isScrollingNotifier.removeListener(_rested);
    super.dispose();
  }

  void _waitForRest(ScrollPosition position) {
    if (identical(_scrolling, position)) return;
    _scrolling?.isScrollingNotifier.removeListener(_rested);
    _scrolling = position..isScrollingNotifier.addListener(_rested);
  }

  void _rested() {
    final position = _scrolling;
    if (position == null || position.isScrollingNotifier.value) return;
    position.isScrollingNotifier.removeListener(_rested);
    _scrolling = null;
    // A scroll can settle in the middle of a layout, where no rebuild may
    // start.
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final inherited = DefaultTextStyle.of(context);
        final settled = widget.settledStyle;
        InlineSpan text = widget.text;
        if (width.isFinite &&
            width > 0 &&
            (settled == null || _sameLayout(inherited.style, settled))) {
          var style = inherited.style.merge(widget.style);
          if (MediaQuery.boldTextOf(context)) {
            style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
          }
          final position = Scrollable.maybeOf(context)?.position;
          final wait =
              widget.nearby &&
              position != null &&
              position.isScrollingNotifier.value &&
              widget.text.toPlainText(includeSemanticsLabels: false).length >
                  _deferredLength;
          text =
              justifyReaderText(
                widget.text,
                width: width,
                style: style,
                strutStyle: widget.strutStyle,
                textScaler:
                    widget.textScaler ?? MediaQuery.textScalerOf(context),
                textWidthBasis: inherited.textWidthBasis,
                textHeightBehavior:
                    inherited.textHeightBehavior ??
                    DefaultTextHeightBehavior.maybeOf(context),
                locale: Localizations.maybeLocaleOf(context),
                cachedOnly: wait || !widget.nearby,
              ) ??
              widget.text;
          if (wait) _waitForRest(position);
        }
        return Text.rich(
          text,
          style: widget.style,
          strutStyle: widget.strutStyle,
          textScaler: widget.textScaler,
        );
      },
    );
  }
}

/// Whether two styles lay text out alike, which is all a settled animation
/// has to match; an interpolated style differs from its target in fields
/// that never move a glyph.
bool _sameLayout(TextStyle a, TextStyle b) =>
    a.fontSize == b.fontSize &&
    a.height == b.height &&
    a.letterSpacing == b.letterSpacing &&
    a.wordSpacing == b.wordSpacing &&
    a.fontFamily == b.fontFamily &&
    a.fontWeight == b.fontWeight &&
    a.fontStyle == b.fontStyle;

/// Recently justified texts. Pages are rebuilt far more often than their text
/// or width changes, and a page turn builds the same paragraphs again.
final _justified = <Object, InlineSpan?>{};
const _justifiedCapacity = 256;

/// Text this long is drawn as it is while its list scrolls, and justified
/// once the list comes to rest. Scroll mode sets a whole chapter as one
/// text, whose justification would otherwise land in the frame that scrolls
/// it into reach.
const _deferredLength = 2000;

/// Half-width savings already measured, by mark and style.
final _savings = <(String, TextStyle, TextScaler, Locale?), double>{};

/// Full-width marks drawn in the left half of their square, which may close a
/// line at half width.
const _closingMarks = '，。、；：）】」』》〉〕”’．';

/// Full-width marks drawn in the right half of their square, which may open a
/// line at half width.
const _openingMarks = '（【「『《〈〔“‘';

const _halfWidth = FontFeature.enable('halt');

/// Room left at the right margin, so rounding can never push a character
/// over it and onto the next line.
const _edgeSlack = 0.25;

/// The most a gap may widen, as a share of the font size. A line cut short
/// ahead of an unbreakable run stays as it is.
const _maxSpread = 0.6;

/// [text] with letter spacing that carries each wrapped line to [width], or
/// null when it should be drawn as it is. With [cachedOnly], only a result
/// already worked out is returned.
InlineSpan? justifyReaderText(
  InlineSpan text, {
  required double width,
  required TextStyle style,
  StrutStyle? strutStyle,
  TextScaler textScaler = TextScaler.noScaling,
  TextWidthBasis textWidthBasis = TextWidthBasis.parent,
  TextHeightBehavior? textHeightBehavior,
  Locale? locale,
  bool cachedOnly = false,
}) {
  final key = (
    text,
    width,
    style,
    strutStyle,
    textScaler,
    textWidthBasis,
    textHeightBehavior,
    locale,
  );
  if (_justified.containsKey(key)) {
    final cached = _justified.remove(key);
    _justified[key] = cached;
    return cached;
  }
  if (cachedOnly) return null;
  final layout = _Layout(
    style: style,
    strutStyle: strutStyle,
    textScaler: textScaler,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    locale: locale,
    width: width,
  );
  final result = layout.justify(text);
  _justified[key] = result;
  if (_justified.length > _justifiedCapacity) {
    _justified.remove(_justified.keys.first);
  }
  return result;
}

/// One run of text below the root, with the styles of every span above it.
typedef _Leaf = ({
  int start,
  TextSpan span,
  TextStyle? style,
  TextStyle resolved,
});

/// How one cluster or stretch of a line is restyled: its letter spacing
/// raised by [extra] or set to [spacing], and its mark drawn in the font's
/// half-width form.
typedef _Change = ({
  int start,
  int end,
  double? extra,
  double? spacing,
  bool halfWidth,
});

/// One line as laid out: where its text starts and where its visible text
/// ends, and the right edge of that text.
typedef _Line = ({int start, int end, double right, bool hardBreak});

class _Layout {
  _Layout({
    required this.style,
    required this.strutStyle,
    required this.textScaler,
    required this.textWidthBasis,
    required this.textHeightBehavior,
    required this.locale,
    required this.width,
  });

  final TextStyle style;
  final StrutStyle? strutStyle;
  final TextScaler textScaler;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Locale? locale;
  final double width;

  TextPainter _layOut(InlineSpan span) => TextPainter(
    text: TextSpan(style: style, children: [span]),
    textDirection: TextDirection.ltr,
    strutStyle: strutStyle,
    textScaler: textScaler,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    locale: locale,
  )..layout(maxWidth: width);

  InlineSpan? justify(InlineSpan text) {
    final leaves = _leaves(text);
    if (leaves == null || leaves.isEmpty) return null;
    final plain = text.toPlainText(includeSemanticsLabels: false);
    final painter = _layOut(text);
    try {
      final lines = _lines(painter, plain);
      // How much wider each line's gaps are set than first worked out. A
      // line without a scale is left as it was.
      final scales = <int, double?>{};
      for (var pass = 0; pass < 3; pass++) {
        final (changes, spread) = _changes(
          painter,
          plain,
          lines,
          leaves,
          scales,
        );
        if (changes.isEmpty) return null;
        final justified = TextSpan(children: _restyled(leaves, changes));
        final check = _layOut(justified);
        final metrics = check.computeLineMetrics();
        check.dispose();
        // A line whose breaks moved would repaginate the text, so then it
        // stays as given.
        if (metrics.length != lines.length) return null;
        var settled = true;
        for (var i = 0; i < lines.length; i++) {
          final right = metrics[i].left + metrics[i].width;
          if (metrics[i].hardBreak != lines[i].hardBreak || right > width) {
            return null;
          }
          final gaps = spread[i];
          final target = gaps == null ? lines[i].right : width - _edgeSlack;
          final miss = target - right;
          if (miss.abs() <= 0.5) continue;
          if (gaps == null) return null;
          // A ligature takes its spacing from its first character, so a gap
          // given to a later one, after a doubled dash in some fonts, stays
          // closed. The line's other gaps share its part on the next pass,
          // and a line that still misses is left as it was.
          scales[i] = pass == 0 && gaps > miss
              ? (scales[i] ?? 1) * gaps / (gaps - miss)
              : null;
          settled = false;
        }
        if (settled) return justified;
      }
      return null;
    } finally {
      painter.dispose();
    }
  }

  /// Every text run of [text] in order, or null when it holds anything but
  /// text, whose width spacing cannot change.
  List<_Leaf>? _leaves(InlineSpan text) {
    final leaves = <_Leaf>[];
    var offset = 0;
    bool collect(InlineSpan span, TextStyle? above, TextStyle resolved) {
      if (span is! TextSpan) return false;
      final own = span.style;
      final chain = own == null ? above : (above?.merge(own) ?? own);
      final effective = own == null ? resolved : resolved.merge(own);
      final content = span.text;
      if (content != null && content.isNotEmpty) {
        leaves.add((
          start: offset,
          span: span,
          style: chain,
          resolved: effective,
        ));
        offset += content.length;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (!collect(child, chain, effective)) return false;
      }
      return true;
    }

    return collect(text, null, style) ? leaves : null;
  }

  /// The lines of [painter]. A line's right edge is where its last visible
  /// character's advance ends; trailing whitespace hangs past it.
  List<_Line> _lines(TextPainter painter, String plain) {
    final metrics = painter.computeLineMetrics();
    final starts = [
      for (final line in metrics)
        painter
            .getPositionForOffset(Offset(0, line.baseline - line.ascent / 2))
            .offset,
    ];
    return [
      for (var i = 0; i < metrics.length; i++)
        (
          start: starts[i],
          end: _visibleEnd(
            plain,
            starts[i],
            i + 1 < starts.length ? starts[i + 1] : plain.length,
          ),
          right: metrics[i].left + metrics[i].width,
          hardBreak: metrics[i].hardBreak,
        ),
    ];
  }

  /// The spacing changes that carry each wrapped line to the margin, and
  /// the width each spread line's gaps add.
  (List<_Change>, Map<int, double>) _changes(
    TextPainter painter,
    String plain,
    List<_Line> lines,
    List<_Leaf> leaves,
    Map<int, double?> scales,
  ) {
    final changes = <_Change>[];
    final spread = <int, double>{};
    void add(int start, int end, double? extra, double? spacing, bool half) {
      if (extra == null && spacing == null && !half) return;
      final previous = changes.isEmpty ? null : changes.last;
      if (previous != null &&
          previous.end == start &&
          previous.extra == extra &&
          previous.spacing == spacing &&
          previous.halfWidth == half) {
        changes.last = (
          start: previous.start,
          end: end,
          extra: extra,
          spacing: spacing,
          halfWidth: half,
        );
      } else {
        changes.add((
          start: start,
          end: end,
          extra: extra,
          spacing: spacing,
          halfWidth: half,
        ));
      }
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final scale = scales.containsKey(i) ? scales[i] : 1.0;
      if (line.hardBreak || scale == null) continue;
      // An indent leading the line keeps its width, so every paragraph
      // starts its text at the same place.
      var start = line.start;
      while (start < line.end && _isSpace(plain.codeUnitAt(start))) {
        start++;
      }
      final indented = start > line.start;
      final clusters = <String>[];
      final offsets = <int>[];
      var cursor = start;
      for (final cluster in plain.substring(start, line.end).characters) {
        clusters.add(cluster);
        offsets.add(cursor);
        cursor += cluster.length;
      }
      if (clusters.length < 2) continue;
      final n = clusters.length;
      final last = offsets.last;
      final lastSpacing = _leafAt(leaves, last).resolved.letterSpacing ?? 0;
      final em = textScaler.scale(
        _leafAt(leaves, start).resolved.fontSize ?? 14,
      );

      // A character's letter spacing follows it, and the line starts half
      // the first character's spacing in. So the line's first character
      // keeps its spacing to hold the left edge, unless an indent comes
      // first, and the last keeps its own to stay clear of the right edge.
      // The spare width goes after the characters between, except inside a
      // Latin word or a number, whose letters stay together.
      final slots = <bool>[
        for (var k = 0; k < n - 1; k++)
          (k > 0 || indented) && _separable(clusters[k], clusters[k + 1]),
      ];
      final slotCount = slots.where((slot) => slot).length;
      if (slotCount == 0) continue;

      final openSaving = !indented && _openingMarks.contains(clusters.first)
          ? _halfWidthSaving(clusters.first, _leafAt(leaves, start).resolved)
          : 0.0;

      // A closing mark sets half its square, keeping the half its ink is in.
      // Its own letter spacing goes negative for that, which leaves the mark
      // where it was drawn and pulls in the end of its advance.
      double? closeSpacing;
      var closeSaving = 0.0;
      if (_closingMarks.contains(clusters.last)) {
        final advance = line.right - _caretX(painter, last);
        final glyph = advance - lastSpacing;
        if (glyph > em * 0.8) {
          closeSpacing = -glyph / 2;
          closeSaving = lastSpacing + glyph / 2;
        }
      }

      final extra =
          (width - _edgeSlack - line.right + openSaving + closeSaving) /
          slotCount *
          scale;
      if (extra < -_edgeSlack || extra > em * _maxSpread) continue;
      spread[i] = extra * slotCount;
      for (var k = 0; k < n; k++) {
        final end = k + 1 < n ? offsets[k + 1] : line.end;
        add(
          offsets[k],
          end,
          k < n - 1 && slots[k] ? extra : null,
          k == n - 1 ? closeSpacing : null,
          k == 0 && openSaving > 0,
        );
      }
    }
    return (changes, spread);
  }

  double _caretX(TextPainter painter, int offset) =>
      painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dx;

  /// How much narrower [mark] sets as the font's half-width form. Zero when
  /// the font has none, which leaves the mark at full width.
  double _halfWidthSaving(String mark, TextStyle resolved) {
    if (_savings.length > 64) _savings.clear();
    return _savings.putIfAbsent((mark, resolved, textScaler, locale), () {
      double measure(TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: mark, style: style),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
          locale: locale,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      final plainStyle = resolved.copyWith(letterSpacing: 0);
      final full = measure(plainStyle);
      final half = measure(
        plainStyle.copyWith(
          fontFeatures: [...?resolved.fontFeatures, _halfWidth],
        ),
      );
      return half < full * 0.75 ? full - half : 0.0;
    });
  }
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x3000 || unit == 0x09 || unit == 0xA0;

/// Whether spare width may go between [before] and [after]: beside a
/// character set on the CJK square or after a space, and never inside a run
/// of anything else, a Latin word, a number or a doubled dash or ellipsis
/// among them. A Latin word takes its share after the space that follows it,
/// so its letters keep their ligatures.
bool _separable(String before, String after) =>
    _isSquare(before) || _isSquare(after) || _isSpace(before.codeUnitAt(0));

/// Ideographs, kana, hangul and full-width forms.
bool _isSquare(String cluster) {
  final c = cluster.runes.first;
  return (c >= 0x2E80 && c <= 0x9FFF) ||
      (c >= 0xAC00 && c <= 0xD7AF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0xFE30 && c <= 0xFE4F) ||
      (c >= 0xFF00 && c <= 0xFFEF) ||
      (c >= 0x20000 && c <= 0x3FFFF);
}

/// Where the visible text of a line running from [start] to [next] ends:
/// before its newline and any whitespace hanging past the margin.
int _visibleEnd(String plain, int start, int next) {
  var end = next;
  while (end > start &&
      (plain.codeUnitAt(end - 1) == 0x0A ||
          _isSpace(plain.codeUnitAt(end - 1)))) {
    end--;
  }
  return end;
}

_Leaf _leafAt(List<_Leaf> leaves, int offset) {
  for (var i = leaves.length - 1; i > 0; i--) {
    if (leaves[i].start <= offset) return leaves[i];
  }
  return leaves.first;
}

List<InlineSpan> _restyled(List<_Leaf> leaves, List<_Change> changes) {
  final spans = <InlineSpan>[];
  var next = 0;
  for (final leaf in leaves) {
    final content = leaf.span.text!;
    final leafEnd = leaf.start + content.length;
    var cut = leaf.start;
    void emit(int to, _Change? change) {
      if (to <= cut) return;
      TextStyle? style = leaf.style;
      if (change != null) {
        final extra = change.extra;
        style = (style ?? const TextStyle()).copyWith(
          letterSpacing:
              change.spacing ??
              (extra == null
                  ? null
                  : (leaf.resolved.letterSpacing ?? 0) + extra),
          fontFeatures: change.halfWidth
              ? [...?leaf.resolved.fontFeatures, _halfWidth]
              : null,
        );
      }
      spans.add(
        TextSpan(
          text: content.substring(cut - leaf.start, to - leaf.start),
          style: style,
          recognizer: leaf.span.recognizer,
          mouseCursor: leaf.span.mouseCursor,
          onEnter: leaf.span.onEnter,
          onExit: leaf.span.onExit,
          locale: leaf.span.locale,
          spellOut: leaf.span.spellOut,
        ),
      );
      cut = to;
    }

    while (next < changes.length && changes[next].end <= leaf.start) {
      next++;
    }
    for (var i = next; i < changes.length; i++) {
      final change = changes[i];
      if (change.start >= leafEnd) break;
      emit(math.max(change.start, leaf.start), null);
      emit(math.min(change.end, leafEnd), change);
    }
    emit(leafEnd, null);
  }
  return spans;
}
