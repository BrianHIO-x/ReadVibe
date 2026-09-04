import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../controllers/reader_pagination_controller.dart';
import '../../models/reader_settings.dart';
import '../../theme/app_theme.dart';

const _simulationPageExtentTolerance = 0.01;

class SimulationLayoutSignature {
  final double contentWidth;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final String? importedFontFamily;
  final String? importedFontPath;
  final FontWeight fontWeight;
  final ReaderParagraphSpacing paragraphSpacing;

  SimulationLayoutSignature({
    required this.contentWidth,
    required ReaderSettings settings,
  }) : fontSize = settings.fontSize,
       lineHeight = settings.lineHeight,
       fontFamily = settings.fontFamily,
       importedFontFamily = settings.importedFontFamily,
       importedFontPath = settings.importedFontPath,
       fontWeight = settings.effectiveFontWeight,
       paragraphSpacing = settings.paragraphSpacing;

  bool matches(SimulationLayoutSignature other) {
    return contentWidth == other.contentWidth &&
        fontSize == other.fontSize &&
        lineHeight == other.lineHeight &&
        fontFamily == other.fontFamily &&
        importedFontFamily == other.importedFontFamily &&
        importedFontPath == other.importedFontPath &&
        fontWeight == other.fontWeight &&
        paragraphSpacing == other.paragraphSpacing;
  }
}

/// Keeps a lazily built simulation chapter's scroll metrics exact before its
/// final paragraph is materialized. Flutter's default variable-height sliver
/// extrapolates unseen children from the currently visible average; a one-page
/// overestimate at the chapter tail makes a forward turn target a phantom page
/// and then clamp back to the same visible page when the real tail is laid out.
class ExactScrollExtentSliverChildBuilderDelegate
    extends SliverChildBuilderDelegate {
  final double exactScrollExtent;

  ExactScrollExtentSliverChildBuilderDelegate(
    super.builder, {
    required int childCount,
    required double exactScrollExtent,
  }) : exactScrollExtent = exactScrollExtent.isFinite
           ? math.max(0.0, exactScrollExtent)
           : 0,
       super(childCount: childCount);

  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => exactScrollExtent;
}

class SimulationPageTarget {
  final int chapterIndex;
  final double offset;
  final double progress;
  final bool goingNext;

  const SimulationPageTarget({
    required this.chapterIndex,
    required this.offset,
    required this.progress,
    required this.goingNext,
  });

  bool matches(SimulationPageTarget other) {
    return chapterIndex == other.chapterIndex &&
        goingNext == other.goingNext &&
        (offset - other.offset).abs() < 0.5;
  }
}

double fullViewportMaxScrollExtent(
  double rawMaxScrollExtent,
  double viewportDimension,
) => ReaderPaginationController.fullViewportMaxScrollExtent(
  rawMaxScrollExtent,
  viewportDimension,
  tolerance: _simulationPageExtentTolerance,
);

/// Extends a simulation chapter's logical scroll range to a whole number of
/// pages. The added range is blank paper after the real chapter content, so
/// the final page starts at the next exact viewport boundary instead of
/// overlapping the preceding page to bottom-align a short remainder.
class FullViewportPagingScrollController extends ScrollController {
  FullViewportPagingScrollController({super.initialScrollOffset})
    : super(keepScrollOffset: false);

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _FullViewportPagingScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
    );
  }
}

class _FullViewportPagingScrollPosition extends ScrollPositionWithSingleContext
    with _PageGridRealignMixin {
  _FullViewportPagingScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  bool get pageGridRealignEnabled => true;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = super.applyContentDimensions(
      minScrollExtent,
      fullViewportMaxScrollExtent(maxScrollExtent, viewportDimension),
    );
    _schedulePageGridRealign();
    return applied;
  }
}

/// Self-healing page-grid guard for simulation pages.
///
/// Flutter silently re-interprets a ScrollPosition's pixels whenever content
/// dimensions change — a new font size, different device metrics, system
/// inset changes — and any drift from the page grid shows up as half-clipped
/// first/last glyph rows, or as the chapter tail bouncing between two
/// candidate offsets. After every layout, drift beyond half a pixel is
/// snapped back to the nearest page boundary on the next frame.
mixin _PageGridRealignMixin on ScrollPositionWithSingleContext {
  bool get pageGridRealignEnabled;

  bool _pageGridRealignScheduled = false;

  void _schedulePageGridRealign() {
    if (!pageGridRealignEnabled ||
        _pageGridRealignScheduled ||
        !hasPixels ||
        !hasContentDimensions) {
      return;
    }
    final snapped = _nearestPageGridOffset();
    if (snapped == null || (pixels - snapped).abs() <= 0.5) return;
    _pageGridRealignScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pageGridRealignScheduled = false;
      if (!hasPixels || !hasContentDimensions) return;
      final target = _nearestPageGridOffset();
      if (target == null || (pixels - target).abs() <= 0.5) return;
      jumpTo(target);
    });
  }

  double? _nearestPageGridOffset() {
    final extent = viewportDimension;
    if (!extent.isFinite || extent <= 0) return null;
    final minExtent = minScrollExtent;
    final maxExtent = maxScrollExtent;
    if (!minExtent.isFinite || !maxExtent.isFinite) return null;
    return ((pixels / extent).round() * extent)
        .clamp(minExtent, maxExtent)
        .toDouble();
  }
}

/// Separates direct reader scrolling from Flutter's selection edge scroller.
///
/// A retained selection allows normal scrolling; an active selection gesture
/// owns the viewport and blocks direct offsets and flings.
/// Programmatic selection-edge scrolling remains available. Simulation keeps
/// the stricter finite-page lock and rejects every pixel mutation.
class SelectionAwareScrollController extends ScrollController {
  final ValueListenable<bool> selectionActive;
  final ValueListenable<bool> selectionDragging;
  final bool Function() freezeSelectionViewport;
  final bool paginateToFullViewports;

  SelectionAwareScrollController({
    required this.selectionActive,
    required this.selectionDragging,
    required this.freezeSelectionViewport,
    required this.paginateToFullViewports,
    super.initialScrollOffset,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SelectionAwareScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
      selectionActive: selectionActive,
      selectionDragging: selectionDragging,
      viewportIsFrozen: () =>
          selectionActive.value && freezeSelectionViewport(),
      paginateToFullViewports: paginateToFullViewports,
    );
  }
}

class _SelectionAwareScrollPosition extends ScrollPositionWithSingleContext
    with _PageGridRealignMixin {
  final ValueListenable<bool> selectionActive;
  final ValueListenable<bool> selectionDragging;
  final bool Function() viewportIsFrozen;
  final bool paginateToFullViewports;
  Completer<void>? _frozenAnimationCompleter;

  _SelectionAwareScrollPosition({
    required super.physics,
    required super.context,
    required this.selectionActive,
    required this.selectionDragging,
    required this.viewportIsFrozen,
    required this.paginateToFullViewports,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    super.debugLabel,
  }) {
    selectionActive.addListener(_handleSelectionActivityChanged);
    selectionDragging.addListener(_handleSelectionDragChanged);
  }

  @override
  bool get pageGridRealignEnabled => paginateToFullViewports;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = super.applyContentDimensions(
      minScrollExtent,
      paginateToFullViewports
          ? fullViewportMaxScrollExtent(maxScrollExtent, viewportDimension)
          : maxScrollExtent,
    );
    _schedulePageGridRealign();
    return applied;
  }

  void _handleSelectionActivityChanged() {
    if (selectionActive.value && activity?.isScrolling == true) {
      // Stop pre-existing inertia as selection takes ownership of the viewport.
      // Blocking drag deltas alone leaves ballistic motion running underneath.
      goIdle();
    }
    if (!viewportIsFrozen()) _releaseFrozenAnimation();
  }

  void _handleSelectionDragChanged() {
    if (selectionDragging.value && activity?.isScrolling == true) goIdle();
  }

  bool get _blocksDirectScrolling =>
      selectionDragging.value || viewportIsFrozen();

  void _releaseFrozenAnimation() {
    final completer = _frozenAnimationCompleter;
    _frozenAnimationCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  double get minScrollExtent =>
      viewportIsFrozen() ? pixels : super.minScrollExtent;

  @override
  double get maxScrollExtent =>
      viewportIsFrozen() ? pixels : super.maxScrollExtent;

  @override
  double setPixels(double newPixels) {
    if (viewportIsFrozen()) return newPixels - pixels;
    return super.setPixels(newPixels);
  }

  @override
  void forcePixels(double value) {
    if (viewportIsFrozen()) return;
    super.forcePixels(value);
  }

  @override
  void applyUserOffset(double delta) {
    if (_blocksDirectScrolling) return;
    super.applyUserOffset(delta);
  }

  @override
  void pointerScroll(double delta) {
    if (_blocksDirectScrolling) return;
    super.pointerScroll(delta);
  }

  @override
  void goBallistic(double velocity) {
    if (_blocksDirectScrolling) {
      // A selection gesture must not turn its release into a reading fling.
      goIdle();
      return;
    }
    super.goBallistic(velocity);
  }

  @override
  void jumpTo(double value) {
    if (viewportIsFrozen()) return;
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (viewportIsFrozen()) {
      return (_frozenAnimationCompleter ??= Completer<void>()).future;
    }
    _releaseFrozenAnimation();
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void dispose() {
    selectionActive.removeListener(_handleSelectionActivityChanged);
    selectionDragging.removeListener(_handleSelectionDragChanged);
    _releaseFrozenAnimation();
    super.dispose();
  }
}

class ReadingTextAnchor {
  final int chapterIndex;
  final int paragraphIndex;
  final int characterOffset;

  const ReadingTextAnchor({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.characterOffset,
  });
}

class ScrollSnapshot {
  final double offset;
  final double progress;

  const ScrollSnapshot({required this.offset, required this.progress});
}

class SmoothTurnPages extends StatelessWidget {
  final double width;
  final double dragOffset;
  final Widget currentPage;
  final Widget? previousPage;
  final Widget? nextPage;
  final Widget? keepAlivePreviousPage;
  final Widget? keepAliveNextPage;

  const SmoothTurnPages({
    super.key,
    required this.width,
    required this.dragOffset,
    required this.currentPage,
    required this.previousPage,
    required this.nextPage,
    this.keepAlivePreviousPage,
    this.keepAliveNextPage,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (keepAlivePreviousPage != null &&
            !identical(keepAlivePreviousPage, previousPage))
          Offstage(child: keepAlivePreviousPage!),
        if (keepAliveNextPage != null &&
            !identical(keepAliveNextPage, nextPage))
          Offstage(child: keepAliveNextPage!),
        if (previousPage != null)
          KeyedSubtree(
            key: const ValueKey('previous-page'),
            child: Transform.translate(
              offset: Offset(dragOffset - width, 0),
              child: _inactivePage(previousPage!),
            ),
          ),
        if (nextPage != null)
          KeyedSubtree(
            key: const ValueKey('next-page'),
            child: Transform.translate(
              offset: Offset(dragOffset + width, 0),
              child: _inactivePage(nextPage!),
            ),
          ),
        KeyedSubtree(
          key: const ValueKey('current-page'),
          child: Transform.translate(
            offset: Offset(dragOffset, 0),
            child: currentPage,
          ),
        ),
      ],
    );
  }
}

class StraightBookTurnPages extends StatelessWidget {
  final double width;
  final double dragOffset;
  final Widget currentPage;
  final Widget? previousPage;
  final Widget? nextPage;
  final Widget? paperBackPage;
  final ReaderThemeColors themeColors;
  final Widget? keepAlivePreviousPage;
  final Widget? keepAliveNextPage;
  final ui.Image? pageTurnSnapshot;
  final ui.Image? reversePageTurnSnapshot;

  const StraightBookTurnPages({
    super.key,
    required this.width,
    required this.dragOffset,
    required this.currentPage,
    required this.previousPage,
    required this.nextPage,
    required this.paperBackPage,
    required this.themeColors,
    required this.pageTurnSnapshot,
    required this.reversePageTurnSnapshot,
    this.keepAlivePreviousPage,
    this.keepAliveNextPage,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (dragOffset.abs() / width).clamp(0.0, 1.0);
    final goingNext = dragOffset <= 0;
    final targetPage = goingNext ? nextPage : previousPage;
    final hasTarget = progress > 0.001 && targetPage != null;
    if (!hasTarget) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (previousPage != null) Offstage(child: previousPage!),
          if (nextPage != null) Offstage(child: nextPage!),
          currentPage,
        ],
      );
    }
    final resolvedTargetPage = targetPage;
    final leafProgress = goingNext ? progress : 1 - progress;
    final geometry = StraightLeafGeometry.calculate(
      size: Size(width, 1),
      progress: leafProgress,
    );
    final movingPage = goingNext ? currentPage : resolvedTargetPage;
    final paperBackSnapshot = goingNext
        ? pageTurnSnapshot
        : reversePageTurnSnapshot;
    final paperBackSource = paperBackSnapshot != null
        ? RawImage(
            image: paperBackSnapshot,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.high,
          )
        : paperBackPage;
    final inkTransmission = themeColors.background.computeLuminance() < 0.25
        ? 0.46
        : 0.38;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (keepAlivePreviousPage != null &&
            !identical(keepAlivePreviousPage, resolvedTargetPage))
          Offstage(child: keepAlivePreviousPage!),
        if (keepAliveNextPage != null &&
            !identical(keepAliveNextPage, resolvedTargetPage))
          Offstage(child: keepAliveNextPage!),
        if (goingNext)
          KeyedSubtree(
            key: const ValueKey('physical-next-page'),
            child: _inactivePage(resolvedTargetPage),
          )
        else
          KeyedSubtree(
            key: const ValueKey('physical-current-page-base'),
            child: currentPage,
          ),
        KeyedSubtree(
          key: ValueKey(
            goingNext
                ? 'physical-forward-sheet'
                : 'physical-reversed-forward-sheet',
          ),
          child: ClipPath(
            clipper: StraightLeafFrontClipper(progress: leafProgress),
            child: goingNext ? movingPage : _inactivePage(movingPage),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: StraightPaperPainter(
                progress: leafProgress,
                pageColor: themeColors.background,
                layer: StraightPaperPaintLayer.base,
              ),
            ),
          ),
        ),
        if (paperBackSource != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipper: StraightLeafBackClipper(progress: leafProgress),
                child: Transform.translate(
                  offset: Offset(geometry.creaseX * 2 - width, 0),
                  child: Transform.flip(
                    flipX: true,
                    child: Opacity(
                      opacity: inkTransmission,
                      child: _inactivePage(paperBackSource),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: StraightPaperPainter(
                progress: leafProgress,
                pageColor: themeColors.background,
                layer: StraightPaperPaintLayer.lighting,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Widget _inactivePage(Widget child) {
  return ExcludeSemantics(child: IgnorePointer(child: child));
}

enum StraightPaperPaintLayer { base, lighting }

class StraightLeafFrontClipper extends CustomClipper<Path> {
  final double progress;

  const StraightLeafFrontClipper({required this.progress});

  @override
  Path getClip(Size size) =>
      StraightLeafGeometry.calculate(size: size, progress: progress).frontPath;

  @override
  bool shouldReclip(covariant StraightLeafFrontClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

class StraightLeafBackClipper extends CustomClipper<Path> {
  final double progress;

  const StraightLeafBackClipper({required this.progress});

  @override
  Path getClip(Size size) =>
      StraightLeafGeometry.calculate(size: size, progress: progress).backPath;

  @override
  bool shouldReclip(covariant StraightLeafBackClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

class StraightPaperPainter extends CustomPainter {
  final double progress;
  final Color pageColor;
  final StraightPaperPaintLayer layer;

  const StraightPaperPainter({
    required this.progress,
    required this.pageColor,
    required this.layer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final p = progress.clamp(0.0, 1.0).toDouble();
    if (p <= 0 || p >= 1) return;
    final geometry = StraightLeafGeometry.calculate(size: size, progress: p);
    final strength = geometry.foldStrength;
    final visibleBounds = geometry.backPath.getBounds().intersect(
      Offset.zero & size,
    );
    if (visibleBounds.width <= 0.1) return;

    final isDarkPage = pageColor.computeLuminance() < 0.25;
    if (layer == StraightPaperPaintLayer.base) {
      canvas.drawShadow(
        geometry.backPath,
        Colors.black.withValues(alpha: 0.30 * strength),
        12 + 8 * strength,
        false,
      );
      final paper = Color.lerp(
        pageColor,
        Colors.white,
        isDarkPage ? 0.02 : 0.045,
      )!;
      canvas.drawPath(geometry.backPath, Paint()..color = paper);
      return;
    }

    final lighting = LinearGradient(
      colors: [
        Colors.black.withValues(alpha: 0.10 * strength),
        Colors.white.withValues(alpha: 0.11 * strength),
        Colors.transparent,
        Colors.black.withValues(alpha: 0.14 * strength),
      ],
      stops: const [0, 0.22, 0.70, 1],
    ).createShader(visibleBounds);
    canvas
      ..save()
      ..clipPath(geometry.backPath)
      ..drawRect(visibleBounds, Paint()..shader = lighting)
      ..restore();

    canvas.drawLine(
      Offset(geometry.outerEdgeX, 0),
      Offset(geometry.outerEdgeX, size.height),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.20 * strength)
        ..strokeWidth = 1.25,
    );
    canvas.drawLine(
      Offset(geometry.creaseX, 0),
      Offset(geometry.creaseX, size.height),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * strength)
        ..strokeWidth = 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8),
    );
    canvas.drawLine(
      Offset(geometry.creaseX - 0.75, 0),
      Offset(geometry.creaseX - 0.75, size.height),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.32 * strength)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant StraightPaperPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.pageColor != pageColor ||
        oldDelegate.layer != layer;
  }
}

class StraightLeafGeometry {
  final Path frontPath;
  final Path backPath;
  final double creaseX;
  final double outerEdgeX;
  final double foldStrength;

  const StraightLeafGeometry({
    required this.frontPath,
    required this.backPath,
    required this.creaseX,
    required this.outerEdgeX,
    required this.foldStrength,
  });

  static StraightLeafGeometry calculate({
    required Size size,
    required double progress,
  }) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    final creaseX = size.width * (1 - p);
    final outerEdgeX = creaseX * 2 - size.width;
    final front = Path()..addRect(Rect.fromLTRB(0, 0, creaseX, size.height));
    final back = Path()
      ..addRect(
        Rect.fromLTRB(
          math.min(outerEdgeX, creaseX),
          0,
          math.max(outerEdgeX, creaseX),
          size.height,
        ),
      );
    return StraightLeafGeometry(
      frontPath: front,
      backPath: back,
      creaseX: creaseX,
      outerEdgeX: outerEdgeX,
      foldStrength: math.sin(math.pi * p).clamp(0.0, 1.0).toDouble(),
    );
  }
}
