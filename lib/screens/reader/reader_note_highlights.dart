import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../models/reader_note.dart';

class ReaderNoteHighlightSpan {
  const ReaderNoteHighlightSpan({
    required this.note,
    required this.startOffset,
    required this.endOffset,
  });

  final ReaderNote note;
  final int startOffset;
  final int endOffset;
}

/// Tracks currently mounted annotated paragraph render boxes so taps on
/// highlighted or underlined passages open the quick note popover directly.
class ReaderNoteHighlightRegistry {
  final Set<RenderNoteHighlights> _targets = <RenderNoteHighlights>{};

  void register(RenderNoteHighlights target) => _targets.add(target);
  void unregister(RenderNoteHighlights target) => _targets.remove(target);

  ReaderNote? hitTest(Offset globalPosition, Size viewportSize) {
    final screenRect = Offset.zero & viewportSize;
    ReaderNote? bestMatch;
    for (final target in _targets) {
      if (!target.attached || !target.hasSize) continue;
      if (_isHiddenInOffstage(target)) continue;
      final bounds = MatrixUtils.transformRect(
        target.getTransformTo(null),
        Offset.zero & target.size,
      );
      if (!bounds.overlaps(screenRect)) continue;
      final hit = target.hitTestNote(globalPosition);
      if (hit != null) {
        bestMatch = hit;
        if (hit.hasContent) return hit;
      }
    }
    return bestMatch;
  }

  static bool _isHiddenInOffstage(RenderObject node) {
    var parent = node.parent;
    while (parent != null) {
      if (parent is RenderOffstage && parent.offstage) return true;
      parent = parent.parent;
    }
    return false;
  }
}

/// Decorates any descendant [RenderParagraph] with inline highlights,
/// underlines, wavy strokes, dashed strokes, and written-note indicators
/// without altering text layout or simulation pagination metrics.
class ReaderAnnotatedParagraph extends SingleChildRenderObjectWidget {
  const ReaderAnnotatedParagraph({
    super.key,
    required this.spans,
    required this.isDarkTheme,
    this.registry,
    super.child,
  });

  final List<ReaderNoteHighlightSpan> spans;
  final bool isDarkTheme;
  final ReaderNoteHighlightRegistry? registry;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderNoteHighlights(
      initialSpans: spans,
      initialIsDarkTheme: isDarkTheme,
      initialRegistry: registry,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNoteHighlights renderObject,
  ) {
    renderObject
      ..spans = spans
      ..isDarkTheme = isDarkTheme
      ..registry = registry;
  }
}

class _HitRegion {
  const _HitRegion(this.note, this.rect);
  final ReaderNote note;
  final Rect rect;
}

class _ResolvedPaintItem {
  const _ResolvedPaintItem(this.note, this.rects);
  final ReaderNote note;
  final List<Rect> rects;
}

class RenderNoteHighlights extends RenderProxyBox {
  RenderNoteHighlights({
    required List<ReaderNoteHighlightSpan> initialSpans,
    required bool initialIsDarkTheme,
    ReaderNoteHighlightRegistry? initialRegistry,
  }) : _spans = initialSpans,
       _isDarkTheme = initialIsDarkTheme,
       _registry = initialRegistry;

  List<ReaderNoteHighlightSpan> _spans;
  set spans(List<ReaderNoteHighlightSpan> value) {
    if (identical(_spans, value)) return;
    _spans = value;
    markNeedsPaint();
  }

  bool _isDarkTheme;
  set isDarkTheme(bool value) {
    if (_isDarkTheme == value) return;
    _isDarkTheme = value;
    markNeedsPaint();
  }

  ReaderNoteHighlightRegistry? _registry;
  set registry(ReaderNoteHighlightRegistry? value) {
    if (identical(_registry, value)) return;
    if (attached) _registry?.unregister(this);
    _registry = value;
    if (attached) _registry?.register(this);
  }

  final List<_HitRegion> _hitRegions = <_HitRegion>[];

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _registry?.register(this);
  }

  @override
  void detach() {
    _registry?.unregister(this);
    _hitRegions.clear();
    super.detach();
  }

  ReaderNote? hitTestNote(Offset globalPosition) {
    if (!attached || !hasSize || _hitRegions.isEmpty) return null;
    final local = globalToLocal(globalPosition);
    if (!(Offset.zero & size).inflate(8).contains(local)) return null;
    for (var i = _hitRegions.length - 1; i >= 0; i--) {
      final region = _hitRegions[i];
      if (region.rect.inflate(6).contains(local)) {
        return region.note;
      }
    }
    return null;
  }

  RenderParagraph? _findDescendantParagraph(RenderObject node) {
    if (node is RenderOffstage && node.offstage) return null;
    if (node is RenderParagraph) return node;
    RenderParagraph? match;
    node.visitChildren((child) {
      match ??= _findDescendantParagraph(child);
    });
    return match;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _hitRegions.clear();
    final paragraph = child == null ? null : _findDescendantParagraph(child!);
    if (paragraph == null || !paragraph.hasSize || _spans.isEmpty) {
      super.paint(context, offset);
      return;
    }

    final plainText = paragraph.text.toPlainText(includeSemanticsLabels: false);
    if (plainText.isEmpty) {
      super.paint(context, offset);
      return;
    }

    final transform = paragraph.getTransformTo(this);
    final items = <_ResolvedPaintItem>[];

    for (final span in _spans) {
      final range = _resolveOffsetRange(plainText, span);
      if (range == null) continue;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: range.$1, extentOffset: range.$2),
        boxHeightStyle: ui.BoxHeightStyle.tight,
      );
      if (boxes.isEmpty) continue;
      final lineRects = _mergeLineBands([
        for (final box in boxes) MatrixUtils.transformRect(transform, box.toRect()),
      ]);
      if (lineRects.isEmpty) continue;
      items.add(_ResolvedPaintItem(span.note, lineRects));
      for (final rect in lineRects) {
        _hitRegions.add(_HitRegion(span.note, rect));
      }
    }

    // 1. Background highlights sit underneath text ink.
    for (final item in items) {
      if (item.note.style != NoteStyle.highlight) continue;
      final paint = Paint()..color = item.note.color.highlightFill(_isDarkTheme);
      for (final rect in item.rects) {
        context.canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect.shift(offset).inflate(1.2),
            const Radius.circular(4),
          ),
          paint,
        );
      }
    }

    // 2. Render crisp typography above highlight fills.
    super.paint(context, offset);

    // 3. Render foreground underlines, waves, dashes, and written-note pips.
    for (final item in items) {
      final swatch = item.note.color.swatchColor(_isDarkTheme);
      switch (item.note.style) {
        case NoteStyle.highlight:
          break;
        case NoteStyle.underline:
          final paint = Paint()
            ..color = swatch.withValues(alpha: 0.9)
            ..strokeWidth = 2.0
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;
          for (final rect in item.rects) {
            final y = rect.bottom + offset.dy + 1.0;
            context.canvas.drawLine(
              Offset(rect.left + offset.dx, y),
              Offset(rect.right + offset.dx, y),
              paint,
            );
          }
        case NoteStyle.dashed:
          final paint = Paint()
            ..color = swatch.withValues(alpha: 0.9)
            ..strokeWidth = 2.0
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;
          for (final rect in item.rects) {
            final y = rect.bottom + offset.dy + 1.0;
            final startX = rect.left + offset.dx;
            final endX = rect.right + offset.dx;
            for (var x = startX; x < endX - 2; x += 8.5) {
              context.canvas.drawLine(
                Offset(x, y),
                Offset(math.min(x + 5.0, endX), y),
                paint,
              );
            }
          }
        case NoteStyle.wavy:
          final paint = Paint()
            ..color = swatch.withValues(alpha: 0.92)
            ..strokeWidth = 1.75
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;
          for (final rect in item.rects) {
            final y = rect.bottom + offset.dy + 1.2;
            final startX = rect.left + offset.dx;
            final endX = rect.right + offset.dx;
            if (endX - startX < 3) continue;
            final path = Path()..moveTo(startX, y);
            const step = 4.2;
            var up = true;
            var x = startX;
            while (x + step <= endX) {
              path.quadraticBezierTo(
                x + step / 2,
                y + (up ? -1.8 : 1.8),
                x + step,
                y,
              );
              up = !up;
              x += step;
            }
            if (x < endX) {
              path.lineTo(endX, y);
            }
            context.canvas.drawPath(path, paint);
          }
      }

      if (item.note.hasContent && item.rects.isNotEmpty) {
        final last = item.rects.last.shift(offset);
        final cx = last.right + 4.5;
        final cy = last.top + 4.0;
        context.canvas.drawCircle(
          Offset(cx, cy),
          3.4,
          Paint()..color = swatch,
        );
      }
    }
  }

  static (int, int)? _resolveOffsetRange(
    String plainText,
    ReaderNoteHighlightSpan span,
  ) {
    final length = plainText.length;
    var start = span.startOffset.clamp(0, length);
    var end = span.endOffset.clamp(0, length);
    final quote = span.note.quote.trim();

    if (end > start && quote.isNotEmpty) {
      final slice = plainText.substring(start, end).trim();
      final prefixLen = math.min(12, quote.length);
      if (slice.contains(quote.substring(0, prefixLen))) {
        return (start, end);
      }
    }

    if (quote.isNotEmpty) {
      final exact = plainText.indexOf(quote);
      if (exact >= 0) {
        return (exact, math.min(length, exact + quote.length));
      }
      final condensedQuote = quote.replaceAll(RegExp(r'\s+'), '');
      if (condensedQuote.length >= 4) {
        final probeLen = math.min(14, condensedQuote.length);
        final anchor = condensedQuote.substring(0, probeLen);
        final hit = plainText.indexOf(anchor);
        if (hit >= 0) {
          return (hit, math.min(length, hit + quote.length));
        }
      }
    }

    if (end > start) return (start, end);
    return null;
  }

  static List<Rect> _mergeLineBands(List<Rect> rects) {
    final sorted = [...rects]
      ..sort((a, b) => a.center.dy.compareTo(b.center.dy));
    final bands = <Rect>[];
    Rect? widest;
    var left = 0.0;
    var right = 0.0;
    var bottom = 0.0;
    void flush() {
      final line = widest;
      if (line != null && right > left) {
        bands.add(Rect.fromLTRB(left, line.top, right, line.bottom));
      }
    }

    for (final rect in sorted) {
      final line = widest;
      if (line != null && rect.center.dy < bottom) {
        if (rect.left < left) left = rect.left;
        if (rect.right > right) right = rect.right;
        if (rect.bottom > bottom) bottom = rect.bottom;
        if (rect.width > line.width) widest = rect;
        continue;
      }
      flush();
      widest = rect;
      left = rect.left;
      right = rect.right;
      bottom = rect.bottom;
    }
    flush();
    return bands;
  }
}
