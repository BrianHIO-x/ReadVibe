import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/reading_paragraph.dart';
import '../../models/reader_settings.dart';
import '../../theme/app_spacing.dart';
import '../../services/resource_presence.dart';
import '../../theme/app_theme.dart';
import 'reader_justified_text.dart';

class EpubBlockLayoutMetrics {
  final double leading;
  final double content;
  final double trailing;
  final double total;

  const EpubBlockLayoutMetrics({
    required this.leading,
    required this.content,
    required this.trailing,
    required this.total,
  });
}

/// Column geometry of a directory-style table row.
///
/// The same values drive measurement, page-mode item extents and drawing, so a
/// row cannot measure as one width and paint at another.
class EpubTableRowGeometry {
  /// Width of the left cell, which keeps wrapping naturally.
  final double leftWidth;

  /// Width of the narrow, end-aligned trailing cell.
  final double rightWidth;

  /// Gap that separates the two columns.
  final double gap;

  /// Offset in the formatted paragraph where the trailing cell starts.
  final int trailingStart;

  const EpubTableRowGeometry({
    required this.leftWidth,
    required this.rightWidth,
    required this.gap,
    required this.trailingStart,
  });
}

/// A measured directory row: two painters that share one block layout.
class EpubTableRowLayout {
  const EpubTableRowLayout({
    required this.geometry,
    required this.leftPainter,
    required this.rightPainter,
    required this.leftTextLength,
    required this.rightTextLength,
    required this.trailingStart,
  });

  final EpubTableRowGeometry geometry;
  final TextPainter leftPainter;
  final TextPainter rightPainter;
  final int leftTextLength;
  final int rightTextLength;
  final int trailingStart;

  /// A row is as tall as its taller cell; both columns are top-aligned.
  double get contentHeight => math.max(leftPainter.height, rightPainter.height);

  /// Maps a left-column caret offset back into the block's formatted text.
  int clampLeftOffset(int offset) => offset.clamp(0, leftTextLength).toInt();

  /// The vertical caret position for [formattedOffset] in this row.
  ///
  /// Offsets inside the trailing cell are resolved against its own painter;
  /// the separator between the cells belongs to neither column and falls back
  /// to the top of the row.
  double caretDyForOffset(int formattedOffset) {
    if (formattedOffset <= leftTextLength) {
      return leftPainter
          .getOffsetForCaret(
            TextPosition(offset: formattedOffset.clamp(0, leftTextLength)),
            Rect.zero,
          )
          .dy;
    }
    if (formattedOffset >= trailingStart) {
      return rightPainter
          .getOffsetForCaret(
            TextPosition(
              offset: (formattedOffset - trailingStart).clamp(
                0,
                rightTextLength,
              ),
            ),
            Rect.zero,
          )
          .dy;
    }
    return 0;
  }

  void dispose() {
    leftPainter.dispose();
    rightPainter.dispose();
  }
}

class _EpubRowRun {
  const _EpubRowRun({
    required this.start,
    required this.text,
    required this.style,
    required this.link,
    required this.runIndex,
  });

  /// Offset in the block's formatted paragraph.
  final int start;
  final String text;
  final EpubContentStyle style;
  final EpubLinkTarget? link;

  /// Index into the block's persisted run list, or -1 for the indent prefix.
  final int runIndex;
}

class _EpubRowTextParts {
  const _EpubRowTextParts({
    required this.leftRuns,
    required this.leftRunIndexes,
    required this.rightRuns,
    required this.rightRunIndexes,
    required this.leftTextLength,
    required this.rightTextLength,
    required this.trailingStart,
  });

  final List<EpubTextRun> leftRuns;
  final List<int> leftRunIndexes;
  final List<EpubTextRun> rightRuns;
  final List<int> rightRunIndexes;
  final int leftTextLength;
  final int rightTextLength;
  final int trailingStart;
}

/// EPUB-specific text layout and rich-block rendering.
///
/// The reader owns navigation and viewport state; this engine owns the EPUB
/// typography contract shared by measurement, anchor mapping and rendering.
class ReaderEpubLayout {
  const ReaderEpubLayout({
    required this.textScaler,
    required this.resolveSimulationLineExtent,
    this.onOpenLink,
  });

  final TextScaler textScaler;
  final double Function(ReaderSettings settings) resolveSimulationLineExtent;

  /// Opens an internal EPUB link. Null in measurement-only contexts, where a
  /// tap target would only allocate recognizers no one can reach.
  final void Function(EpubLinkTarget target)? onOpenLink;

  String formatParagraph(EpubContentBlock block) {
    final body = visibleParagraphBody(block.text);
    if (body.isEmpty) return '';
    return '${richParagraphPrefix(block)}$body';
  }

  int paragraphPrefixLength(Chapter chapter, int paragraphIndex) {
    var current = 0;
    for (final block in chapter.epubBlocks) {
      if (!block.isText || block.text.trim().isEmpty) continue;
      if (current == paragraphIndex) {
        return block.style.textIndentEm.round().clamp(0, 8);
      }
      current++;
    }
    return 0;
  }

  String formatChapterTitle(String title) {
    return title.replaceFirst(RegExp(r'^[\s　]+'), '').trimRight();
  }

  bool hasEmbeddedHeading(Chapter chapter, {bool avoidLazyLoad = false}) {
    if (!chapter.hasRichEpubContent) return false;
    if (avoidLazyLoad && !chapter.hasKnownSemanticHeading) return false;
    if (chapter.hasSemanticHeading) return true;
    for (final block in chapter.epubBlocks) {
      if (!block.isText || block.text.trim().isEmpty) continue;
      if (block.isHeading) return true;
      final sameTitle =
          formatChapterTitle(block.text) == formatChapterTitle(chapter.title);
      return sameTitle &&
          block.style.textIndentEm == 0 &&
          (block.style.fontScale > 1.05 || block.style.fontWeight >= 600);
    }
    return false;
  }

  EpubBlockLayoutMetrics blockMetrics(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final spacing = blockSpacing(block, settings: settings, mode: mode);
    final leading = spacing.leading;
    final trailing = spacing.trailing;
    final double content;
    if (block.isImage) {
      content = imageHeight(block, width: width, settings: settings);
    } else {
      final row = layoutTableRow(
        block,
        settings: settings,
        mode: mode,
        width: width,
      );
      if (row != null) {
        content = row.contentHeight;
        row.dispose();
      } else {
        final painter = layoutTextBlock(
          block,
          settings: settings,
          mode: mode,
          width: width,
        );
        content = painter.height;
        painter.dispose();
      }
    }
    var total = leading + content + trailing;
    if (mode == ReaderReadingMode.simulation) {
      final baseLine = resolveSimulationLineExtent(settings);
      if (baseLine > 0) {
        total = math.max(baseLine, (total / baseLine).ceil() * baseLine);
      }
    }
    return EpubBlockLayoutMetrics(
      leading: leading,
      content: content,
      trailing: math.max(0, total - leading - content),
      total: total,
    );
  }

  /// The space [block] adds above and below its text, without measuring that
  /// text.
  ///
  /// Page mode needs every block's exact height before it draws one, so it
  /// uses [blockMetrics]. While reading, the text widget sizes itself; asking
  /// for the same measurement here only laid the paragraph out a second time
  /// in the frame that built it.
  EpubBlockLayoutMetrics blockSpacing(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
  }) {
    final baseLine = mode == ReaderReadingMode.simulation
        ? resolveSimulationLineExtent(settings)
        : settings.fontSize * settings.lineHeight;
    final rawLeading = block.style.marginTopEm * settings.fontSize;
    final leading = mode == ReaderReadingMode.simulation && baseLine > 0
        ? (rawLeading / baseLine).ceil() * baseLine
        : rawLeading;
    final paragraphGap =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? baseLine
        : 0.0;
    final trailing =
        block.style.marginBottomEm * settings.fontSize + paragraphGap;
    return EpubBlockLayoutMetrics(
      leading: leading,
      content: 0,
      trailing: trailing,
      total: leading + trailing,
    );
  }

  double blockExtent(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) => blockMetrics(block, settings: settings, mode: mode, width: width).total;

  /// Column geometry for a directory-style row, or null when this block is a
  /// normal line or the viewport is too narrow for two readable columns.
  ///
  /// Narrow screens fall back to the complete text line instead of squeezing
  /// the title; that fallback is also what keeps older payloads unchanged.
  EpubTableRowGeometry? tableRowGeometry(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required double width,
  }) {
    final parts = _rowTextParts(block);
    if (parts == null) return null;
    return _tableRowGeometryFor(block, parts, settings: settings, width: width);
  }

  EpubTableRowGeometry? _tableRowGeometryFor(
    EpubContentBlock block,
    _EpubRowTextParts parts, {
    required ReaderSettings settings,
    required double width,
  }) {
    // Columns are laid out in physical pixels, so the geometry uses the same
    // scaled font size the painters and Text.rich widgets apply.
    final fontSize = math.max(1.0, textScaler.scale(settings.fontSize));
    final desiredRight = (block.trailingCellWidthEm ?? 3.2) * fontSize;
    final gap = math.max(4.0, fontSize * 0.45);
    if (!desiredRight.isFinite || desiredRight <= 0) return null;
    // A right column wider than the reading measure cannot stay a column.
    if (desiredRight > width * 0.42) return null;
    final leftWidth = width - desiredRight - gap;
    // Leave the left cell enough room for a real title; otherwise the whole row
    // reads as an ordinary line.
    final minimumLeft = math.max(fontSize * 7, width * 0.5);
    if (leftWidth < minimumLeft) return null;
    return EpubTableRowGeometry(
      leftWidth: leftWidth,
      rightWidth: desiredRight,
      gap: gap,
      trailingStart: parts.trailingStart,
    );
  }

  /// Measures one trailing-cell row with the same geometry that draws it.
  ///
  /// The row's height is the taller of its cells. Callers own the painters and
  /// must dispose the result.
  EpubTableRowLayout? layoutTableRow(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final parts = _rowTextParts(block);
    if (parts == null) return null;
    final geometry = _tableRowGeometryFor(
      block,
      parts,
      settings: settings,
      width: width,
    );
    if (geometry == null) return null;
    final strutStyle = mode == ReaderReadingMode.simulation
        ? _simulationStrutStyle(block, settings)
        : null;
    final leftPainter = TextPainter(
      text: _textSpanForRuns(
        parts.leftRuns,
        parts.leftRunIndexes,
        settings: settings,
        foreground: Colors.black,
        background: Colors.white,
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.start,
      textScaler: textScaler,
      strutStyle: strutStyle,
    )..layout(maxWidth: geometry.leftWidth);
    final rightPainter = TextPainter(
      text: _textSpanForRuns(
        parts.rightRuns,
        parts.rightRunIndexes,
        settings: settings,
        foreground: Colors.black,
        background: Colors.white,
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.end,
      textScaler: textScaler,
      strutStyle: strutStyle,
    )..layout(maxWidth: geometry.rightWidth);
    return EpubTableRowLayout(
      geometry: geometry,
      leftPainter: leftPainter,
      rightPainter: rightPainter,
      leftTextLength: parts.leftTextLength,
      rightTextLength: parts.rightTextLength,
      trailingStart: parts.trailingStart,
    );
  }

  _EpubRowTextParts? _rowTextParts(EpubContentBlock block) {
    if (!block.hasTrailingCell) return null;
    final text = block.text;
    final body = visibleParagraphBody(text);
    if (body.isEmpty) return null;
    final bodyStart = text.indexOf(body);
    if (bodyStart < 0) return null;
    final bodyEnd = bodyStart + body.length;
    final trailingCellStart = block.trailingCellStart!;
    if (trailingCellStart <= bodyStart || trailingCellStart >= bodyEnd) {
      return null;
    }
    final formatted = formatParagraph(block);
    final prefixLength = formatted.length - body.length;
    final formattedTrailing = prefixLength + (trailingCellStart - bodyStart);
    if (formattedTrailing <= 0 || formattedTrailing >= formatted.length) {
      return null;
    }
    final rowRuns = _rowRuns(block, formatted, body, bodyStart);
    if (rowRuns == null) return null;
    var leftEnd = formattedTrailing;
    while (leftEnd > 0 && _isRowSeparator(formatted.codeUnitAt(leftEnd - 1))) {
      leftEnd--;
    }
    if (leftEnd <= 0) return null;
    final leftRuns = <EpubTextRun>[];
    final leftRunIndexes = <int>[];
    final rightRuns = <EpubTextRun>[];
    final rightRunIndexes = <int>[];
    for (final run in rowRuns) {
      final runStart = run.start;
      final runEnd = runStart + run.text.length;
      if (runStart < leftEnd) {
        final start = math.max(0, runStart);
        final end = math.min(runEnd, leftEnd);
        if (end > start) {
          leftRuns.add(
            EpubTextRun(
              text: formatted.substring(start, end),
              style: run.style,
              link: run.link,
            ),
          );
          leftRunIndexes.add(run.runIndex);
        }
      }
      if (runEnd > formattedTrailing) {
        final start = math.max(formattedTrailing, runStart);
        final end = math.min(runEnd, formatted.length);
        if (end > start) {
          rightRuns.add(
            EpubTextRun(
              text: formatted.substring(start, end),
              style: run.style,
              link: run.link,
            ),
          );
          rightRunIndexes.add(run.runIndex);
        }
      }
    }
    if (leftRuns.isEmpty || rightRuns.isEmpty) return null;
    return _EpubRowTextParts(
      leftRuns: List<EpubTextRun>.unmodifiable(leftRuns),
      leftRunIndexes: List<int>.unmodifiable(leftRunIndexes),
      rightRuns: List<EpubTextRun>.unmodifiable(rightRuns),
      rightRunIndexes: List<int>.unmodifiable(rightRunIndexes),
      leftTextLength: leftEnd,
      rightTextLength: formatted.length - formattedTrailing,
      trailingStart: formattedTrailing,
    );
  }

  /// Runs in formatted-paragraph coordinates, including the indent prefix.
  ///
  /// Persisted runs normally cover the complete block text. A partial run list
  /// (an edited payload, for one) falls back to the plain style so no character
  /// is dropped; only such a fallback loses inline styling.
  List<_EpubRowRun>? _rowRuns(
    EpubContentBlock block,
    String formatted,
    String body,
    int bodyStart,
  ) {
    final prefixLength = formatted.length - body.length;
    final bodyEnd = bodyStart + body.length;
    var runLength = 0;
    for (final run in block.runs) {
      runLength += run.text.length;
    }
    if (block.runs.isEmpty || runLength != block.text.length) {
      return <_EpubRowRun>[
        _EpubRowRun(
          start: 0,
          text: formatted,
          style: block.style,
          link: null,
          runIndex: -1,
        ),
      ];
    }
    final result = <_EpubRowRun>[];
    // The indent prefix is part of the formatted paragraph but not of the
    // persisted runs. Emit it first, in layout coordinates, so a section row's
    // left cell keeps its indent and caret offsets stay in formatted space.
    if (prefixLength > 0) {
      result.add(
        _EpubRowRun(
          start: 0,
          text: formatted.substring(0, prefixLength),
          style: block.style,
          link: null,
          runIndex: -1,
        ),
      );
    }
    var cursor = 0;
    for (var index = 0; index < block.runs.length; index++) {
      final run = block.runs[index];
      final start = math.max(cursor, bodyStart);
      final end = math.min(cursor + run.text.length, bodyEnd);
      cursor += run.text.length;
      if (end <= start) continue;
      result.add(
        _EpubRowRun(
          start: prefixLength + (start - bodyStart),
          text: block.text.substring(start, end),
          style: run.style,
          link: run.link,
          runIndex: index,
        ),
      );
    }
    return result.isEmpty ? null : result;
  }

  bool _isRowSeparator(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0xA0 || unit == 0x3000;

  /// The extent of every block, measured with one painter.
  ///
  /// Page mode measures a chapter's whole body before it draws the first page.
  /// Building a painter for each paragraph spent most of that time in setup
  /// rather than layout, so the work is shared here; the heights are the same
  /// ones [blockExtent] returns for each block on its own.
  List<double> blockExtents(
    Iterable<EpubContentBlock> blocks, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final extents = <double>[];
    TextPainter? painter;
    try {
      for (final block in blocks) {
        final spacing = blockSpacing(block, settings: settings, mode: mode);
        final double content;
        if (block.isImage) {
          content = imageHeight(block, width: width, settings: settings);
        } else {
          final row = layoutTableRow(
            block,
            settings: settings,
            mode: mode,
            width: width,
          );
          if (row != null) {
            content = row.contentHeight;
            row.dispose();
          } else {
            final shared = painter ??= TextPainter(
              textDirection: TextDirection.ltr,
              textScaler: textScaler,
            );
            shared.text = _textSpan(
              block,
              settings: settings,
              foreground: Colors.black,
              background: Colors.white,
            );
            shared.textAlign = _textAlign(block.style.textAlign);
            shared.strutStyle = mode == ReaderReadingMode.simulation
                ? _simulationStrutStyle(block, settings)
                : null;
            shared.layout(maxWidth: width);
            content = shared.height;
          }
        }
        var total = spacing.leading + content + spacing.trailing;
        if (mode == ReaderReadingMode.simulation) {
          final baseLine = resolveSimulationLineExtent(settings);
          if (baseLine > 0) {
            total = math.max(baseLine, (total / baseLine).ceil() * baseLine);
          }
        }
        extents.add(total);
      }
    } finally {
      painter?.dispose();
    }
    return extents;
  }

  TextPainter layoutTextBlock(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    return TextPainter(
      text: _textSpan(
        block,
        settings: settings,
        foreground: Colors.black,
        background: Colors.white,
      ),
      textDirection: TextDirection.ltr,
      textAlign: _textAlign(block.style.textAlign),
      textScaler: textScaler,
      strutStyle: mode == ReaderReadingMode.simulation
          ? _simulationStrutStyle(block, settings)
          : null,
    )..layout(maxWidth: width);
  }

  double imageHeight(
    EpubContentBlock block, {
    required double width,
    required ReaderSettings settings,
  }) {
    final requestedWidth = block.imageWidth;
    final displayWidth = requestedWidth != null && requestedWidth > 0
        ? math.min(width, requestedWidth)
        : width;
    final sourceWidth = block.imageWidth;
    final sourceHeight = block.imageHeight;
    final aspect =
        sourceWidth != null &&
            sourceHeight != null &&
            sourceWidth > 0 &&
            sourceHeight > 0
        ? sourceWidth / sourceHeight
        : 1.5;
    final naturalHeight = displayWidth / aspect;
    return naturalHeight.clamp(
      settings.fontSize * settings.lineHeight * 2,
      560.0,
    );
  }

  Widget buildBlock({
    required EpubContentBlock block,
    required ReaderThemeColors themeColors,
    required ReaderSettings settings,
    required double width,
    required bool simulationPage,
    double? itemExtent,
  }) {
    final mode = simulationPage
        ? ReaderReadingMode.simulation
        : settings.readingMode;
    // Page mode measures every item before it draws one. When that height is
    // handed in, the visible paragraph keeps it instead of being laid out a
    // second time for its slot. While reading, the text sizes itself and this
    // call only gathers the space above and below it.
    final spacing = blockSpacing(block, settings: settings, mode: mode);
    final metrics = itemExtent != null
        ? EpubBlockLayoutMetrics(
            leading: spacing.leading,
            content: math.max(
              0,
              itemExtent - spacing.leading - spacing.trailing,
            ),
            trailing: spacing.trailing,
            total: itemExtent,
          )
        : simulationPage
        ? blockMetrics(block, settings: settings, mode: mode, width: width)
        : spacing;
    final blockBackground = _blockBackground(block.style, themeColors);
    final foreground = _foreground(
      block.style,
      themeColors,
      blockBackground == Colors.transparent
          ? themeColors.background
          : blockBackground,
    );
    Widget content;
    if (block.isImage) {
      final path = block.imagePath;
      final requestedWidth = block.imageWidth;
      final displayWidth = requestedWidth != null && requestedWidth > 0
          ? math.min(width, requestedWidth)
          : width;
      content = SizedBox(
        width: displayWidth,
        height: simulationPage
            ? metrics.content
            : imageHeight(block, width: width, settings: settings),
        child: path == null
            ? _imageFallback(block, themeColors)
            : Image.file(
                File(path),
                fit: BoxFit.contain,
                alignment: Alignment.center,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => _imageFallback(block, themeColors),
              ),
      );
      content = Align(
        alignment: switch (block.style.textAlign) {
          'center' => Alignment.center,
          'end' => Alignment.centerRight,
          _ => Alignment.centerLeft,
        },
        child: content,
      );
    } else {
      final background = blockBackground == Colors.transparent
          ? themeColors.background
          : blockBackground;
      final openLink = onOpenLink;
      final rowGeometry = block.hasTrailingCell
          ? tableRowGeometry(block, settings: settings, width: width)
          : null;
      final Widget text;
      if (openLink != null && block.hasLinks) {
        text = _EpubLinkedText(
          layout: this,
          block: block,
          settings: settings,
          themeColors: themeColors,
          foreground: foreground,
          background: background,
          simulationPage: simulationPage,
          onOpenLink: openLink,
          rowGeometry: rowGeometry,
        );
      } else if (rowGeometry != null) {
        text = _buildTableRow(
          block,
          settings: settings,
          foreground: foreground,
          background: background,
          simulationPage: simulationPage,
          geometry: rowGeometry,
        );
      } else {
        text = _blockText(
          _textSpan(
            block,
            settings: settings,
            foreground: foreground,
            background: background,
          ),
          align: _textAlign(block.style.textAlign),
          strutStyle: simulationPage
              ? _simulationStrutStyle(block, settings)
              : null,
        );
      }
      content = simulationPage
          ? SizedBox(width: width, height: metrics.content, child: text)
          : SizedBox(width: width, child: text);
    }

    final backgroundPath = block.style.backgroundImagePath;
    final decoration =
        blockBackground == Colors.transparent && backgroundPath == null
        ? null
        : BoxDecoration(
            color: blockBackground == Colors.transparent
                ? null
                : blockBackground,
            image: importedResourceExists(backgroundPath)
                ? DecorationImage(
                    image: FileImage(File(backgroundPath!)),
                    fit: BoxFit.cover,
                    opacity: 0.22,
                  )
                : null,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          );
    final padded = Padding(
      padding: EdgeInsets.only(top: metrics.leading, bottom: metrics.trailing),
      child: DecoratedBox(
        decoration: decoration ?? const BoxDecoration(),
        child: content,
      ),
    );
    if (!simulationPage) return padded;
    return SizedBox(height: metrics.total, child: padded);
  }

  StrutStyle _simulationStrutStyle(
    EpubContentBlock block,
    ReaderSettings settings,
  ) {
    final baseLine = resolveSimulationLineExtent(settings);
    var naturalLineExtent =
        settings.fontSize *
        block.style.fontScale *
        settings.lineHeight *
        block.style.lineHeightScale;
    var weight = block.style.fontWeight;
    for (final run in block.runs) {
      naturalLineExtent = math.max(
        naturalLineExtent,
        settings.fontSize *
            run.style.fontScale *
            settings.lineHeight *
            run.style.lineHeightScale,
      );
      weight = math.max(weight, run.style.fontWeight);
    }
    final lineExtent = baseLine > 0
        ? math.max(baseLine, (naturalLineExtent / baseLine).ceil() * baseLine)
        : naturalLineExtent;
    return StrutStyle(
      fontFamily: block.style.fontFamily ?? settings.effectiveFontFamily,
      fontSize: settings.fontSize,
      height: lineExtent / settings.fontSize,
      fontWeight: weight >= 600
          ? (weight >= 800 ? FontWeight.w900 : FontWeight.w700)
          : settings.effectiveFontWeight,
      forceStrutHeight: true,
    );
  }

  TextSpan _textSpan(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required Color foreground,
    required Color background,
    Color? linkColor,
    Map<int, TapGestureRecognizer>? linkRecognizers,
  }) {
    final formatted = formatParagraph(block);
    final prefixLength = math.max(0, formatted.length - block.text.length);
    final children = <InlineSpan>[];
    if (prefixLength > 0) {
      children.add(
        TextSpan(
          text: formatted.substring(0, prefixLength),
          style: _runTextStyle(
            block.style,
            settings: settings,
            foreground: foreground,
            background: background,
          ),
        ),
      );
    }
    if (block.runs.isEmpty) {
      children.add(
        TextSpan(
          text: block.text.trim(),
          style: _runTextStyle(
            block.style,
            settings: settings,
            foreground: foreground,
            background: background,
          ),
        ),
      );
    } else {
      // Word splits one paragraph into a run per formatting change, and often
      // per revision or language marker as well. Neighbouring runs that draw
      // the same way are one span as far as the text engine is concerned, and
      // a long paragraph made of thousands of such runs is laid out an order
      // of magnitude slower than the same text in a single span.
      final mergedText = StringBuffer();
      TextStyle? mergedStyle;
      TapGestureRecognizer? mergedRecognizer;
      EpubLinkTarget? mergedLink;
      void flushMerged() {
        if (mergedText.isEmpty) return;
        children.add(
          TextSpan(
            text: mergedText.toString(),
            style: mergedStyle,
            recognizer: mergedRecognizer,
          ),
        );
        mergedText.clear();
        mergedStyle = null;
        mergedRecognizer = null;
        mergedLink = null;
      }

      for (var index = 0; index < block.runs.length; index++) {
        final run = block.runs[index];
        final isLink = run.link != null && linkColor != null;
        final style = isLink
            ? _runTextStyle(
                run.style,
                settings: settings,
                foreground: foreground,
                background: background,
              ).copyWith(
                color: linkColor,
                decoration: TextDecoration.underline,
                decorationColor: linkColor.withValues(alpha: 0.5),
              )
            : _runTextStyle(
                run.style,
                settings: settings,
                foreground: foreground,
                background: background,
              );
        final link = isLink ? run.link : null;
        final previousLink = mergedLink;
        final sameLink = previousLink == null
            ? link == null
            : link != null &&
                  previousLink.chapterIndex == link.chapterIndex &&
                  previousLink.blockIndex == link.blockIndex &&
                  previousLink.needDirectJump == link.needDirectJump;
        if (mergedText.isNotEmpty && style == mergedStyle && sameLink) {
          mergedText.write(run.text);
          continue;
        }
        flushMerged();
        mergedText.write(run.text);
        mergedStyle = style;
        if (isLink) {
          mergedRecognizer = linkRecognizers == null
              ? null
              : linkRecognizers[index];
        } else {
          mergedRecognizer = null;
        }
        mergedLink = link;
      }
      flushMerged();
    }
    return TextSpan(children: children);
  }

  /// Builds the two-column body of a trailing-cell row.
  ///
  /// Both cells are separate text widgets so the right one can be end-aligned
  /// and sized independently; they are top-aligned, and the block measures as
  /// the taller cell. Left and right therefore stay one selectable block.
  Widget _buildTableRow(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required Color foreground,
    required Color background,
    required bool simulationPage,
    required EpubTableRowGeometry geometry,
    Color? linkColor,
    Map<int, TapGestureRecognizer>? linkRecognizers,
  }) {
    final parts = _rowTextParts(block);
    if (parts == null) {
      return _blockText(
        _textSpan(
          block,
          settings: settings,
          foreground: foreground,
          background: background,
          linkColor: linkColor,
          linkRecognizers: linkRecognizers,
        ),
        align: _textAlign(block.style.textAlign),
        strutStyle: simulationPage
            ? _simulationStrutStyle(block, settings)
            : null,
      );
    }
    final strutStyle = simulationPage
        ? _simulationStrutStyle(block, settings)
        : null;
    final left = Text.rich(
      _textSpanForRuns(
        parts.leftRuns,
        parts.leftRunIndexes,
        settings: settings,
        foreground: foreground,
        background: background,
        linkColor: linkColor,
        linkRecognizers: linkRecognizers,
      ),
      textAlign: TextAlign.start,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      strutStyle: strutStyle,
    );
    final right = Text.rich(
      _textSpanForRuns(
        parts.rightRuns,
        parts.rightRunIndexes,
        settings: settings,
        foreground: foreground,
        background: background,
        linkColor: linkColor,
        linkRecognizers: linkRecognizers,
      ),
      textAlign: TextAlign.end,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      strutStyle: strutStyle,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: geometry.leftWidth, child: left),
        SizedBox(width: geometry.gap),
        SizedBox(width: geometry.rightWidth, child: right),
      ],
    );
  }

  /// The same span building as [_textSpan], for a pre-split run list.
  TextSpan _textSpanForRuns(
    List<EpubTextRun> runs,
    List<int> runIndexes, {
    required ReaderSettings settings,
    required Color foreground,
    required Color background,
    Color? linkColor,
    Map<int, TapGestureRecognizer>? linkRecognizers,
  }) {
    final children = <InlineSpan>[];
    final mergedText = StringBuffer();
    TextStyle? mergedStyle;
    TapGestureRecognizer? mergedRecognizer;
    EpubLinkTarget? mergedLink;
    void flushMerged() {
      if (mergedText.isEmpty) return;
      children.add(
        TextSpan(
          text: mergedText.toString(),
          style: mergedStyle,
          recognizer: mergedRecognizer,
        ),
      );
      mergedText.clear();
      mergedStyle = null;
      mergedRecognizer = null;
      mergedLink = null;
    }

    for (var index = 0; index < runs.length; index++) {
      final run = runs[index];
      final isLink = run.link != null && linkColor != null;
      final style = isLink
          ? _runTextStyle(
              run.style,
              settings: settings,
              foreground: foreground,
              background: background,
            ).copyWith(
              color: linkColor,
              decoration: TextDecoration.underline,
              decorationColor: linkColor.withValues(alpha: 0.5),
            )
          : _runTextStyle(
              run.style,
              settings: settings,
              foreground: foreground,
              background: background,
            );
      final link = isLink ? run.link : null;
      final previousLink = mergedLink;
      final sameLink = previousLink == null
          ? link == null
          : link != null &&
                previousLink.chapterIndex == link.chapterIndex &&
                previousLink.blockIndex == link.blockIndex &&
                previousLink.needDirectJump == link.needDirectJump;
      if (mergedText.isNotEmpty && style == mergedStyle && sameLink) {
        mergedText.write(run.text);
        continue;
      }
      flushMerged();
      mergedText.write(run.text);
      mergedStyle = style;
      final runIndex = index < runIndexes.length ? runIndexes[index] : -1;
      mergedRecognizer = isLink && linkRecognizers != null
          ? linkRecognizers[runIndex]
          : null;
      mergedLink = link;
    }
    flushMerged();
    return TextSpan(children: children);
  }

  TextStyle _runTextStyle(
    EpubContentStyle style, {
    required ReaderSettings settings,
    required Color foreground,
    required Color background,
  }) {
    final weight = style.fontWeight >= 600
        ? (style.fontWeight >= 800 ? FontWeight.w900 : FontWeight.w700)
        : settings.effectiveFontWeight;
    return TextStyle(
      fontFamily: style.fontFamily ?? settings.effectiveFontFamily,
      fontSize: settings.fontSize * style.fontScale,
      fontWeight: weight,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      decoration: style.underline
          ? TextDecoration.underline
          : TextDecoration.none,
      shadows: settings.effectiveFontShadows(foreground),
      height: settings.lineHeight * style.lineHeightScale,
      color: _safePublisherForeground(
        style.colorArgb,
        fallback: foreground,
        background: background,
      ),
      backgroundColor: style.backgroundColorArgb == null
          ? null
          : Color(style.backgroundColorArgb!).withValues(alpha: 0.18),
      letterSpacing:
          settings.fontSize * style.fontScale * style.letterSpacingEm + 0.2,
    );
  }

  TextAlign _textAlign(String value) => switch (value) {
    'center' => TextAlign.center,
    'end' => TextAlign.end,
    'justify' => TextAlign.justify,
    _ => TextAlign.start,
  };

  /// Body text meets both margins. A justified block is set this way too: the
  /// engine's own justification would drop its indent.
  Widget _blockText(
    InlineSpan text, {
    required TextAlign align,
    StrutStyle? strutStyle,
  }) {
    if (align == TextAlign.start || align == TextAlign.justify) {
      return ReaderJustifiedText(
        text,
        textScaler: textScaler,
        strutStyle: strutStyle,
      );
    }
    return Text.rich(
      text,
      textAlign: align,
      textScaler: textScaler,
      strutStyle: strutStyle,
    );
  }

  Color _blockBackground(
    EpubContentStyle style,
    ReaderThemeColors themeColors,
  ) {
    final raw = style.backgroundColorArgb;
    if (raw == null) return Colors.transparent;
    final publisher = Color(raw);
    final dark = themeColors.background.computeLuminance() < 0.25;
    return Color.lerp(themeColors.background, publisher, dark ? 0.16 : 0.42)!;
  }

  Color _foreground(
    EpubContentStyle style,
    ReaderThemeColors themeColors,
    Color background,
  ) {
    return _safePublisherForeground(
      style.colorArgb,
      fallback: themeColors.text,
      background: background,
    );
  }

  Color _safePublisherForeground(
    int? raw, {
    required Color fallback,
    required Color background,
  }) {
    if (raw == null) return fallback;
    final publisher = Color(raw);
    final first = publisher.computeLuminance() + 0.05;
    final second = background.computeLuminance() + 0.05;
    final contrast = first > second ? first / second : second / first;
    return contrast >= 3 ? publisher : fallback;
  }

  Widget _imageFallback(EpubContentBlock block, ReaderThemeColors themeColors) {
    final label = block.altText?.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: themeColors.headerBg,
        border: Border.all(color: themeColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                color: themeColors.secondary,
                size: 28,
              ),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: themeColors.secondary, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders a block that contains internal links.
///
/// Tap recognizers must outlive a single frame and be disposed with the widget,
/// so link-bearing blocks render through this stateful wrapper. Blocks without
/// links keep the cheaper stateless path.
class _EpubLinkedText extends StatefulWidget {
  const _EpubLinkedText({
    required this.layout,
    required this.block,
    required this.settings,
    required this.themeColors,
    required this.foreground,
    required this.background,
    required this.simulationPage,
    required this.onOpenLink,
    this.rowGeometry,
  });

  final ReaderEpubLayout layout;
  final EpubContentBlock block;
  final ReaderSettings settings;
  final ReaderThemeColors themeColors;
  final Color foreground;
  final Color background;
  final bool simulationPage;
  final void Function(EpubLinkTarget target) onOpenLink;

  /// Set when this block is a directory row with a trailing page-number cell.
  final EpubTableRowGeometry? rowGeometry;

  @override
  State<_EpubLinkedText> createState() => _EpubLinkedTextState();
}

class _EpubLinkedTextState extends State<_EpubLinkedText> {
  final _recognizers = <int, TapGestureRecognizer>{};

  @override
  void initState() {
    super.initState();
    _buildRecognizers();
  }

  @override
  void didUpdateWidget(_EpubLinkedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.block, widget.block)) return;
    _disposeRecognizers();
    _buildRecognizers();
  }

  void _buildRecognizers() {
    final runs = widget.block.runs;
    for (var index = 0; index < runs.length; index++) {
      final target = runs[index].link;
      if (target == null) continue;
      // The callback is read at tap time so a rebuilt parent stays authoritative.
      _recognizers[index] = TapGestureRecognizer()
        ..onTap = () => widget.onOpenLink(target);
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rowGeometry = widget.rowGeometry;
    if (rowGeometry != null) {
      return widget.layout._buildTableRow(
        widget.block,
        settings: widget.settings,
        foreground: widget.foreground,
        background: widget.background,
        simulationPage: widget.simulationPage,
        geometry: rowGeometry,
        linkColor: _safeLinkColor(),
        linkRecognizers: _recognizers,
      );
    }
    return widget.layout._blockText(
      widget.layout._textSpan(
        widget.block,
        settings: widget.settings,
        foreground: widget.foreground,
        background: widget.background,
        linkColor: _safeLinkColor(),
        linkRecognizers: _recognizers,
      ),
      align: widget.layout._textAlign(widget.block.style.textAlign),
      strutStyle: widget.simulationPage
          ? widget.layout._simulationStrutStyle(widget.block, widget.settings)
          : null,
    );
  }

  /// Keeps the accent readable on a publisher background by falling back to the
  /// block's own foreground when the two colors are too close.
  Color _safeLinkColor() {
    final accent = widget.themeColors.accent;
    final contrast =
        (accent.computeLuminance() - widget.background.computeLuminance())
            .abs();
    return contrast < 0.12 ? widget.foreground : accent;
  }
}
