import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'book_card.dart';

Offset _centerDragAnchorStrategy(
  Draggable<Object> draggable,
  BuildContext context,
  Offset position,
) {
  final renderBox = context.findRenderObject()! as RenderBox;
  return renderBox.size.center(Offset.zero);
}

({int columns, double cardWidth, double cardHeight}) computeShelfGridMetrics(
  double availableWidth, {
  int minColumns = 3,
  int maxColumns = 8,
  double cardAspectRatio = 0.52,
}) {
  const maxCardWidth = 148.0;
  const gap = AppSpacing.xs;
  final gridWidth = math.max(0.0, availableWidth - AppSpacing.md * 2);
  final fitted = gridWidth <= 0
      ? minColumns
      : ((gridWidth + gap) / (maxCardWidth + gap)).ceil();
  final columns = fitted.clamp(minColumns, maxColumns);
  final cardWidth = math.max(
    0.0,
    (gridWidth - gap * (columns - 1)) / columns,
  );
  return (
    columns: columns,
    cardWidth: cardWidth,
    cardHeight: cardWidth / cardAspectRatio,
  );
}

/// Drag-and-drop shelf reordering grid.
class LibraryReorderGrid extends StatelessWidget {
  const LibraryReorderGrid({
    super.key,
    required this.books,
    required this.progressMap,
    required this.availabilityMap,
    required this.colors,
    required this.scrollController,
    required this.openingBook,
    required this.reorderFocusBookId,
    required this.onBooksFitChanged,
    required this.onPinOffsetWhenFits,
    required this.onMoveDraggedBook,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final List<Book> books;
  final Map<String, ReadingProgress> progressMap;
  final Map<String, BookAvailability> availabilityMap;
  final ReaderThemeColors colors;
  final ScrollController scrollController;
  final bool openingBook;
  final String? reorderFocusBookId;
  final ValueChanged<bool> onBooksFitChanged;
  final void Function(ScrollController controller, bool booksFit)
  onPinOffsetWhenFits;
  final ValueChanged<String> onMoveDraggedBook;
  final ValueChanged<Book> onDragStarted;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final ValueChanged<Book> onDragEnd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPadding = AppSpacing.md;
        const horizontalGap = AppSpacing.xs;
        const verticalGap = AppSpacing.sm;
        final metrics = computeShelfGridMetrics(constraints.maxWidth);
        final columnCount = metrics.columns;
        final gridWidth = math.max(
          0.0,
          constraints.maxWidth - horizontalPadding * 2,
        );
        final cardWidth = metrics.cardWidth;
        final cardHeight = metrics.cardHeight;
        final rowCount = (books.length / columnCount).ceil();
        final contentHeight = rowCount == 0
            ? 0.0
            : rowCount * cardHeight + (rowCount - 1) * verticalGap;
        final gestureInset = MediaQuery.paddingOf(context).bottom;
        final paintedHeight = rowCount == 0
            ? 0.0
            : (rowCount - 1) * (cardHeight + verticalGap) +
                  math.min(
                    cardHeight,
                    BookCard.paintedHeight(context, cardWidth),
                  );
        final booksFit =
            paintedHeight <= constraints.maxHeight - gestureInset + 0.5;
        onBooksFitChanged(booksFit);
        onPinOffsetWhenFits(scrollController, booksFit);

        return SingleChildScrollView(
          key: const ValueKey('reorder-grid'),
          controller: scrollController,
          physics: booksFit ? const NeverScrollableScrollPhysics() : null,
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            booksFit
                ? 0
                : horizontalPadding + MediaQuery.paddingOf(context).bottom,
          ),
          child: SizedBox(
            width: gridWidth,
            height: contentHeight,
            child: Stack(
              alignment: Alignment.topLeft,
              clipBehavior: Clip.none,
              children: [
                for (var index = 0; index < books.length; index++)
                  _buildItem(
                    book: books[index],
                    index: index,
                    columnCount: columnCount,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    horizontalGap: horizontalGap,
                    verticalGap: verticalGap,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildItem({
    required Book book,
    required int index,
    required int columnCount,
    required double cardWidth,
    required double cardHeight,
    required double horizontalGap,
    required double verticalGap,
  }) {
    final column = index % columnCount;
    final row = index ~/ columnCount;
    final left = column * (cardWidth + horizontalGap);
    final top = row * (cardHeight + verticalGap);

    return AnimatedPositioned(
      key: ValueKey<String>(book.id),
      duration: AppMotion.shelfReorder,
      curve: AppMotion.shelfReorderCurve,
      left: left,
      top: top,
      width: cardWidth,
      height: cardHeight,
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) => details.data != book.id,
        onMove: (_) => onMoveDraggedBook(book.id),
        builder: (context, candidateData, rejectedData) {
          final isTarget = candidateData.any((id) => id != book.id);
          final isFocused = reorderFocusBookId == book.id;
          final card = _buildCard(book);
          return Semantics(
            label: '拖动移动《${book.title}》',
            hint: '按住并拖动到新的书架位置',
            child: AnimatedScale(
              scale: isTarget ? 0.965 : (isFocused ? 1.035 : 1.0),
              duration: isTarget ? AppMotion.quick : AppMotion.shelfLift,
              curve: AppMotion.shelfReorderCurve,
              child: AnimatedContainer(
                duration: AppMotion.shelfLift,
                curve: AppMotion.shelfReorderCurve,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(
                    color: isTarget || isFocused
                        ? colors.accent.withValues(alpha: 0.42)
                        : Colors.transparent,
                    width: 1.2,
                  ),
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: colors.accent.withValues(alpha: 0.16),
                            blurRadius: 18,
                            offset: const Offset(0, 7),
                          ),
                        ]
                      : const [],
                ),
                child: Draggable<String>(
                  data: book.id,
                  maxSimultaneousDrags: openingBook ? 0 : 1,
                  dragAnchorStrategy: _centerDragAnchorStrategy,
                  onDragStarted: () => onDragStarted(book),
                  onDragUpdate: onDragUpdate,
                  onDragEnd: (_) => onDragEnd(book),
                  feedback: _buildLiftedFeedback(
                    book: book,
                    width: cardWidth,
                    height: cardHeight,
                  ),
                  childWhenDragging: _buildPlaceholder(card),
                  child: card,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard(Book book) {
    return BookCard(
      book: book,
      progress: progressMap[book.id],
      availability: availabilityMap[book.id] ?? BookAvailability.available,
      colors: colors,
      onTap: () {},
    );
  }

  Widget _buildPlaceholder(Widget card) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: colors.accent.withValues(alpha: 0.18),
          width: 1,
        ),
      ),
      child: Opacity(opacity: 0.12, child: card),
    );
  }

  Widget _buildLiftedFeedback({
    required Book book,
    required double width,
    required double height,
  }) {
    return IgnorePointer(
      child: Material(
        color: Colors.transparent,
        elevation: 18,
        shadowColor: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Transform.scale(
          scale: 1.055,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.headerBg.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.42),
                width: 1.2,
              ),
            ),
            child: SizedBox(
              width: width,
              height: height,
              child: _buildCard(book),
            ),
          ),
        ),
      ),
    );
  }
}

/// Scroll physics for a shelf whose cards all sit above the gesture bar.
class PinnedShelfScrollPhysics extends ScrollPhysics {
  const PinnedShelfScrollPhysics({super.parent});

  @override
  PinnedShelfScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      PinnedShelfScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) =>
      value - position.pixels;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => null;
}
