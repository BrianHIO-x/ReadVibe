import '../services/resource_presence.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/word_count_service.dart';
import 'pressable_scale.dart';

/// A book card displayed on the library shelf
class BookCard extends StatefulWidget {
  final Book book;
  final ReadingProgress? progress;
  final BookAvailability availability;
  final ReaderThemeColors? colors;
  final Key? coverKey;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  static const _inset = 6.0;
  static const _coverAspectRatio = 0.7;
  static const _metaFontSize = 11.0;
  static const _iconSize = 12.0;
  static const _progressHeight = 3.0;

  /// Height a card paints in a shelf cell of [cellWidth], from the cell top
  /// to the bottom of the progress bar.
  ///
  /// Shelf cells keep a fixed aspect ratio, so each one ends about twenty
  /// pixels below its progress bar. The shelf compares this height with the
  /// gesture bar to tell whether the last row is really on screen. It mirrors
  /// the column in [_BookCardState.build], and the two have to change together.
  static double paintedHeight(BuildContext context, double cellWidth) {
    final style = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .merge(const TextStyle(fontSize: _metaFontSize));
    final painter = TextPainter(
      text: TextSpan(text: '全文 0 章 · 已读 0%', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final lineHeight = painter.height;
    painter.dispose();
    final coverWidth = math.max(0.0, cellWidth - _inset * 2);
    return _inset +
        coverWidth / _coverAspectRatio +
        6 +
        lineHeight +
        AppSpacing.xs +
        math.max(lineHeight, _iconSize) +
        AppSpacing.xs +
        _progressHeight +
        _inset;
  }

  const BookCard({
    super.key,
    required this.book,
    this.progress,
    this.availability = BookAvailability.available,
    this.colors,
    this.coverKey,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  // The imported cover file can disappear between the presence check and the
  // decode, or simply be unreadable. The card then falls back to the text face
  // instead of drawing an empty coloured block.
  bool _coverFailed = false;
  bool _coverFailureScheduled = false;

  @override
  void didUpdateWidget(BookCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.id != widget.book.id ||
        oldWidget.book.coverImagePath != widget.book.coverImagePath) {
      _coverFailed = false;
      _coverFailureScheduled = false;
    }
  }

  /// Switches to the text face after an image decode failure.
  ///
  /// The image provider reports the error while the card is building, so the
  /// rebuild happens after the frame instead of inside build.
  void _handleCoverError() {
    if (_coverFailed || _coverFailureScheduled) return;
    // The callback runs after the frame, when this card may already be showing
    // another book or another cover. Only the image that actually failed may
    // switch this card to the text face.
    final failedBookId = widget.book.id;
    final failedCoverPath = widget.book.coverImagePath;
    _coverFailureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.book.id != failedBookId ||
          widget.book.coverImagePath != failedCoverPath) {
        return;
      }
      _coverFailureScheduled = false;
      if (_coverFailed) return;
      setState(() => _coverFailed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final progress = widget.progress;
    final availability = widget.availability;
    final palette =
        widget.colors ??
        AppTheme.getReaderTheme(
          ReaderThemeMode.system,
          systemBrightness: MediaQuery.platformBrightnessOf(context),
        );
    final isDark = palette.background.computeLuminance() < 0.28;
    final coverColor = isDark ? const Color(0xFF2A2623) : AppTheme.surfaceWarm;
    final coverShadow = isDark
        ? Colors.black.withValues(alpha: 0.24)
        : palette.text.withValues(alpha: 0.08);
    final spineShadow = isDark
        ? Colors.black.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.06);
    final coverPath = book.coverImagePath;
    final showCoverImage = importedResourceExists(coverPath) && !_coverFailed;
    final totalChapters = book.chapterCount;
    final totalUnits = book.isPdf ? (book.pageCount ?? 0) : totalChapters;
    final currentChapter = totalUnits > 0
        ? (progress?.chapterIndex ?? 0).clamp(0, totalUnits - 1)
        : 0;
    final localProgress =
        progress?.chapterProgress[currentChapter] ??
        progress?.scrollProgress ??
        0.0;
    final progressPercent = book.isPdf
        ? (progress?.scrollProgress ??
                  (totalUnits > 1 ? currentChapter / (totalUnits - 1) : 0.0))
              .clamp(0.0, 1.0)
              .toDouble()
        : totalUnits > 0
        ? ((currentChapter + localProgress.clamp(0.0, 1.0)) / totalUnits)
              .clamp(0.0, 1.0)
              .toDouble()
        : 0.0;
    final progressPercentLabel = (progressPercent * 100).toInt();
    final metaLine = book.isPdf
        ? '${book.pageCount ?? 0} 页${progress != null ? ' · 已读 $progressPercentLabel%' : ''}'
        : [
            if (book.author.isNotEmpty) book.author,
            '$totalChapters 章${progress != null ? ' · 已读 $progressPercentLabel%' : ''}',
          ].join(' · ');
    final wordCountLine = book.isPdf
        ? 'PDF 原版页面'
        : formatBookWordCount(book.wordCount);
    final availabilityLabel = availability.label;
    final availabilityColor = availability.blocksOpening
        ? const Color(0xFFC84B46)
        : const Color(0xFFC17A24);
    // A book with a cover carries its title on the card face only when the
    // cover cannot be drawn. Otherwise the line under the cover names it, so a
    // title-less piece of cover art is still identifiable in the grid.
    final underCoverLine = showCoverImage ? book.title : metaLine;
    final underCoverStyle = showCoverImage
        ? TextStyle(
            fontSize: BookCard._metaFontSize,
            fontWeight: FontWeight.w600,
            color: palette.text,
          )
        : TextStyle(fontSize: BookCard._metaFontSize, color: palette.secondary);
    // The cover already names the book, so the line under it carries the
    // reading status the old card showed (author, chapters or pages, and the
    // visible progress percentage). Without a cover that status is the face
    // line, and the row below keeps the word count.
    final statusLine = availabilityLabel.isEmpty
        ? (showCoverImage ? metaLine : wordCountLine)
        : availabilityLabel;
    final statusColor = availabilityLabel.isEmpty
        ? palette.secondary
        : availabilityColor;
    final semanticsStatus = availabilityLabel.isEmpty
        ? wordCountLine
        : availabilityLabel;
    final semanticsLabel = [
      book.title,
      if (book.author.isNotEmpty) '作者 ${book.author}',
      book.format.name.toUpperCase(),
      if (book.isPdf) '${book.pageCount ?? 0} 页' else '$totalChapters 章',
      if (progress != null) '已读 $progressPercentLabel%',
      semanticsStatus,
    ].join('，');

    return Semantics(
      button: true,
      label: semanticsLabel,
      hint: widget.onLongPress == null ? null : '长按可管理这本书',
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: PressableScale(
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              overlayColor: WidgetStateProperty.all(Colors.transparent),
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: const EdgeInsets.all(BookCard._inset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Cover
                    RepaintBoundary(
                      key: widget.coverKey,
                      child: AspectRatio(
                        aspectRatio: BookCard._coverAspectRatio,
                        child: Stack(
                          children: [
                            // 1. Background block. Colour/border/shadow only.
                            //    The reader route samples this cover's Rect and
                            //    image snapshot, then performs the visible
                            //    shared-element/page-opening choreography.
                            Container(
                              decoration: BoxDecoration(
                                color: coverColor,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.md,
                                ),
                                border: Border.all(color: palette.border),
                                boxShadow: [
                                  BoxShadow(
                                    color: coverShadow,
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                            ),
                            // 2. Spine shadow — a narrow gradient hugging the
                            //    left edge to suggest the thickness of a bound
                            //    book. A real cover paints over it.
                            Positioned(
                              left: 0,
                              top: 0,
                              bottom: 0,
                              width: 7,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(AppRadius.md),
                                    bottomLeft: Radius.circular(AppRadius.md),
                                  ),
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [spineShadow, Colors.transparent],
                                  ),
                                ),
                              ),
                            ),
                            // 3. The cover itself. Nothing is laid over it but
                            //    the format and availability badges below, so
                            //    the artwork is not dimmed or covered by
                            //    title/author text it already contains.
                            if (showCoverImage)
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
                                  child: Image.file(
                                    File(coverPath!),
                                    fit: BoxFit.cover,
                                    filterQuality: FilterQuality.medium,
                                    errorBuilder: (_, _, _) {
                                      _handleCoverError();
                                      return const SizedBox.shrink();
                                    },
                                  ),
                                ),
                              )
                            // 4. Missing or undecodable cover: the card keeps
                            //    the old text face, which also carries the
                            //    title the reader route samples when opening.
                            else
                              Positioned.fill(
                                top: 26,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    AppSpacing.md,
                                    0,
                                    AppSpacing.md,
                                    AppSpacing.md,
                                  ),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) => Align(
                                      alignment: Alignment.bottomLeft,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.bottomLeft,
                                        child: SizedBox(
                                          width: constraints.maxWidth,
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                book.title,
                                                style: TextStyle(
                                                  fontFamily: 'Georgia',
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: palette.text,
                                                  height: 1.25,
                                                ),
                                                maxLines: 3,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              if (book.author.isNotEmpty) ...[
                                                const SizedBox(
                                                  height: AppSpacing.xs,
                                                ),
                                                Text(
                                                  book.author,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: palette.secondary,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (availabilityLabel.isNotEmpty)
                              Positioned(
                                left: AppSpacing.xs,
                                top: AppSpacing.xs,
                                child: Container(
                                  constraints: const BoxConstraints(
                                    maxWidth: 82,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: availabilityColor,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.sm,
                                    ),
                                  ),
                                  child: Text(
                                    availabilityLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            // 5. Format badge
                            Positioned(
                              top: AppSpacing.xs,
                              right: AppSpacing.xs,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.accent,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.sm,
                                  ),
                                ),
                                child: Text(
                                  book.format.name.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: palette.accent.computeLuminance() >
                                            0.35
                                        ? palette.background
                                        : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            if (widget.selectionMode)
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.md,
                                    ),
                                    border: Border.all(
                                      color: widget.selected
                                          ? palette.accent
                                          : palette.border.withValues(
                                              alpha: 0.7,
                                            ),
                                      width: widget.selected ? 2.2 : 1,
                                    ),
                                    color: widget.selected
                                        ? palette.accent.withValues(alpha: 0.14)
                                        : null,
                                  ),
                                  child: Align(
                                    alignment: Alignment.bottomRight,
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Container(
                                        decoration: widget.selected
                                            ? null
                                            : BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Colors.black.withValues(
                                                  alpha: 0.34,
                                                ),
                                              ),
                                        child: Icon(
                                          widget.selected
                                              ? Icons.check_circle_rounded
                                              : Icons
                                                    .radio_button_unchecked_rounded,
                                          size: 20,
                                          color: widget.selected
                                              ? palette.accent
                                              : Colors.white.withValues(
                                                  alpha: 0.94,
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Title under a real cover, or the author/progress line
                    // when the card face already shows the title.
                    Text(
                      underCoverLine,
                      style: underCoverStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Icon(
                          availabilityLabel.isEmpty
                              ? Icons.text_snippet_outlined
                              : Icons.warning_amber_rounded,
                          size: BookCard._iconSize,
                          color: statusColor,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            statusLine,
                            style: TextStyle(
                              fontSize: BookCard._metaFontSize,
                              color: statusColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progressPercent,
                        backgroundColor: palette.border,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          palette.accent,
                        ),
                        minHeight: BookCard._progressHeight,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
