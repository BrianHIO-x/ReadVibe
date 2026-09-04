import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/reading_paragraph.dart';
import '../../models/reader_settings.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_theme.dart';

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

/// EPUB-specific text layout and rich-block rendering.
///
/// The reader owns navigation and viewport state; this engine owns the EPUB
/// typography contract shared by measurement, anchor mapping and rendering.
class ReaderEpubLayout {
  const ReaderEpubLayout({
    required this.textScaler,
    required this.resolveSimulationLineExtent,
  });

  final TextScaler textScaler;
  final double Function(ReaderSettings settings) resolveSimulationLineExtent;

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
    final double content;
    if (block.isImage) {
      content = imageHeight(block, width: width, settings: settings);
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
    var total = leading + content + trailing;
    if (mode == ReaderReadingMode.simulation && baseLine > 0) {
      total = math.max(baseLine, (total / baseLine).ceil() * baseLine);
    }
    return EpubBlockLayoutMetrics(
      leading: leading,
      content: content,
      trailing: math.max(0, total - leading - content),
      total: total,
    );
  }

  double blockExtent(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) => blockMetrics(block, settings: settings, mode: mode, width: width).total;

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
  }) {
    final mode = simulationPage
        ? ReaderReadingMode.simulation
        : settings.readingMode;
    final metrics = blockMetrics(
      block,
      settings: settings,
      mode: mode,
      width: width,
    );
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
        height: metrics.content,
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
      content = SizedBox(
        width: width,
        height: metrics.content,
        child: Text.rich(
          _textSpan(
            block,
            settings: settings,
            foreground: foreground,
            background: blockBackground == Colors.transparent
                ? themeColors.background
                : blockBackground,
          ),
          textAlign: _textAlign(block.style.textAlign),
          textScaler: textScaler,
          strutStyle: simulationPage
              ? _simulationStrutStyle(block, settings)
              : null,
        ),
      );
    }

    final backgroundPath = block.style.backgroundImagePath;
    final decoration =
        blockBackground == Colors.transparent && backgroundPath == null
        ? null
        : BoxDecoration(
            color: blockBackground == Colors.transparent
                ? null
                : blockBackground,
            image: backgroundPath != null && File(backgroundPath).existsSync()
                ? DecorationImage(
                    image: FileImage(File(backgroundPath)),
                    fit: BoxFit.cover,
                    opacity: 0.22,
                  )
                : null,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          );
    return SizedBox(
      height: metrics.total,
      child: Padding(
        padding: EdgeInsets.only(
          top: metrics.leading,
          bottom: metrics.trailing,
        ),
        child: DecoratedBox(
          decoration: decoration ?? const BoxDecoration(),
          child: content,
        ),
      ),
    );
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
      for (final run in block.runs) {
        children.add(
          TextSpan(
            text: run.text,
            style: _runTextStyle(
              run.style,
              settings: settings,
              foreground: foreground,
              background: background,
            ),
          ),
        );
      }
    }
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
