import 'dart:io';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/word_count_service.dart';
import 'pressable_scale.dart';

/// A book card displayed on the library shelf
class BookCard extends StatelessWidget {
  final Book book;
  final ReadingProgress? progress;
  final BookAvailability availability;
  final ReaderThemeColors? colors;
  final Key? coverKey;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookCard({
    super.key,
    required this.book,
    this.progress,
    this.availability = BookAvailability.available,
    this.colors,
    this.coverKey,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette =
        colors ??
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
    final scrimColor = isDark
        ? Colors.black.withValues(alpha: 0.22)
        : palette.text.withValues(alpha: 0.18);
    final coverPath = book.coverImagePath;
    final hasCoverImage = coverPath != null && File(coverPath).existsSync();
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
    final metaLine = book.isPdf
        ? '${book.pageCount ?? 0} 页${progress != null ? ' · 已读 ${(progressPercent * 100).toInt()}%' : ''}'
        : [
            if (book.author.isNotEmpty) book.author,
            '$totalChapters 章${progress != null ? ' · 已读 ${(progressPercent * 100).toInt()}%' : ''}',
          ].join(' · ');
    final wordCountLine = book.isPdf
        ? 'PDF 原版页面'
        : formatBookWordCount(book.wordCount);
    final availabilityLabel = availability.label;
    final availabilityColor = availability.blocksOpening
        ? const Color(0xFFC84B46)
        : const Color(0xFFC17A24);

    return Semantics(
      button: true,
      label:
          '$metaLine。${availabilityLabel.isEmpty ? wordCountLine : availabilityLabel}。${book.title}${book.author.isNotEmpty ? '，作者 ${book.author}' : ''}',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: PressableScale(
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cover
                  RepaintBoundary(
                    key: coverKey,
                    child: AspectRatio(
                      aspectRatio: 0.7,
                      child: Stack(
                        children: [
                          // 1. Background block. Colour/border/shadow only;
                          //    text lives in its own layer above so the
                          //    gradient scrim (layer 3) doesn't have to sit
                          //    on top of it. The reader route samples this
                          //    cover's Rect and image snapshot, then performs
                          //    the visible shared-element/page-opening
                          //    choreography.
                          Container(
                            decoration: BoxDecoration(
                              color: coverColor,
                              borderRadius: BorderRadius.circular(AppRadius.md),
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
                          //    book.
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
                          if (hasCoverImage)
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.md,
                                ),
                                child: Image.file(
                                  File(coverPath),
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.medium,
                                  errorBuilder: (_, _, _) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          if (availabilityLabel.isNotEmpty)
                            Positioned(
                              left: AppSpacing.xs,
                              top: AppSpacing.xs,
                              child: Container(
                                constraints: const BoxConstraints(maxWidth: 82),
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
                          // 3. Bottom gradient scrim — lifts contrast for the
                          //    title/author text sitting above it. Wrapped in
                          //    Positioned.fill + Align so FractionallySizedBox
                          //    receives a bounded height to take a fraction
                          //    of (Positioned with only left/right/bottom set
                          //    would hand it unbounded height and crash).
                          Positioned.fill(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: 0.4,
                                widthFactor: 1.0,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: const BorderRadius.only(
                                      bottomLeft: Radius.circular(AppRadius.md),
                                      bottomRight: Radius.circular(
                                        AppRadius.md,
                                      ),
                                    ),
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        hasCoverImage
                                            ? Colors.black.withValues(
                                                alpha: 0.72,
                                              )
                                            : scrimColor,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 4. Title / author text — pulled out of the
                          //    background container so it can sit above the
                          //    scrim instead of being covered by it.
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    book.title,
                                    style: TextStyle(
                                      fontFamily: 'Georgia',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: hasCoverImage
                                          ? Colors.white
                                          : palette.text,
                                      height: 1.25,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (book.author.isNotEmpty) ...[
                                    const SizedBox(height: AppSpacing.xs),
                                    Text(
                                      book.author,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: hasCoverImage
                                            ? Colors.white70
                                            : palette.secondary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
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
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Meta line: author + chapter count / progress
                  Text(
                    metaLine,
                    style: TextStyle(fontSize: 11, color: palette.secondary),
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
                        size: 12,
                        color: availabilityLabel.isEmpty
                            ? palette.secondary
                            : availabilityColor,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          availabilityLabel.isEmpty
                              ? wordCountLine
                              : availabilityLabel,
                          style: TextStyle(
                            fontSize: 11,
                            color: availabilityLabel.isEmpty
                                ? palette.secondary
                                : availabilityColor,
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
                      valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
                      minHeight: 3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
