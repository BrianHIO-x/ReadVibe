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

/// Where a simulated turn lifts the leaf. The middle band folds the page
/// upright from its bottom corner.
enum PageCurlCorner { top, bottom, middle }

class CurlBookTurnPages extends StatelessWidget {
  final double width;
  final double height;
  final double dragOffset;
  final double curlLift;
  final PageCurlCorner curlCorner;
  final Widget currentPage;
  final Widget? previousPage;
  final Widget? nextPage;
  final Widget? paperBackPage;
  final ReaderThemeColors themeColors;
  final Widget? keepAlivePreviousPage;
  final Widget? keepAliveNextPage;
  final ui.Image? pageTurnSnapshot;
  final ui.Image? reversePageTurnSnapshot;

  const CurlBookTurnPages({
    super.key,
    required this.width,
    required this.height,
    required this.dragOffset,
    required this.curlLift,
    required this.curlCorner,
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
    final geometry = PageCurlGeometry.forDrag(
      size: Size(width, height),
      dragOffset: dragOffset,
      corner: curlCorner,
      lift: curlLift,
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
            clipper: PageCurlClipper(
              geometry: geometry,
              region: PageCurlRegion.front,
            ),
            child: goingNext ? movingPage : _inactivePage(movingPage),
          ),
        ),
        if (geometry != null) ...[
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: PageCurlPainter(
                  geometry: geometry,
                  pageColor: themeColors.background,
                  layer: PageCurlPaintLayer.base,
                ),
              ),
            ),
          ),
          if (paperBackSource != null)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(
                  clipper: PageCurlClipper(
                    geometry: geometry,
                    region: PageCurlRegion.back,
                  ),
                  // The back shows the leaf's own print mirrored across the
                  // fold, faint as ink seen through paper.
                  child: Transform(
                    transform: geometry.backTransform,
                    child: Opacity(
                      opacity: inkTransmission,
                      child: _inactivePage(paperBackSource),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: PageCurlPainter(
                  geometry: geometry,
                  pageColor: themeColors.background,
                  layer: PageCurlPaintLayer.lighting,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

Widget _inactivePage(Widget child) {
  return ExcludeSemantics(child: IgnorePointer(child: child));
}

enum PageCurlRegion { front, back }

class PageCurlClipper extends CustomClipper<Path> {
  final PageCurlGeometry? geometry;
  final PageCurlRegion region;

  const PageCurlClipper({required this.geometry, required this.region});

  @override
  Path getClip(Size size) {
    final geometry = this.geometry;
    if (geometry == null) {
      return region == PageCurlRegion.front
          ? (Path()..addRect(Offset.zero & size))
          : Path();
    }
    return region == PageCurlRegion.front
        ? geometry.frontPath
        : geometry.backPath;
  }

  @override
  bool shouldReclip(covariant PageCurlClipper oldClipper) {
    return !identical(oldClipper.geometry, geometry) ||
        oldClipper.region != region;
  }
}

enum PageCurlPaintLayer { base, lighting }

class PageCurlPainter extends CustomPainter {
  final PageCurlGeometry geometry;
  final Color pageColor;
  final PageCurlPaintLayer layer;

  const PageCurlPainter({
    required this.geometry,
    required this.pageColor,
    required this.layer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final curl = geometry;
    final strength = curl.strength;
    final crest = curl.pointAt(PageCurlGeometry.crest);
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    if (layer == PageCurlPaintLayer.base) {
      // The rolled paper shades the page it uncovers, darkest at the roll.
      final shadeWidth = (curl.reach * 0.2).clamp(6.0, 72.0).toDouble();
      canvas
        ..save()
        ..clipPath(curl.underPath)
        ..drawPaint(
          Paint()
            ..shader =
                ui.Gradient.linear(crest, crest - curl.direction * shadeWidth, [
                  Colors.black.withValues(alpha: 0.32 * strength),
                  Colors.black.withValues(alpha: 0),
                ]),
        )
        ..restore();
      // The lifted flap casts a soft shadow onto the part still lying flat.
      canvas
        ..save()
        ..clipPath(curl.frontPath)
        ..drawPath(
          curl.backPath.shift(curl.direction * 2),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.26 * strength)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 5 * strength),
        )
        ..restore();
      final isDarkPage = pageColor.computeLuminance() < 0.25;
      final paper = Color.lerp(
        pageColor,
        Colors.white,
        isDarkPage ? 0.02 : 0.045,
      )!;
      canvas.drawPath(curl.backPath, Paint()..color = paper);
    } else {
      canvas
        ..save()
        ..clipPath(curl.backPath)
        ..drawPaint(
          Paint()
            ..shader = ui.Gradient.linear(
              crest,
              curl.pointAt(1),
              [
                Colors.black.withValues(alpha: 0.16 * strength),
                Colors.white.withValues(alpha: 0.12 * strength),
                Colors.white.withValues(alpha: 0),
                Colors.black.withValues(alpha: 0.10 * strength),
              ],
              const [0, 0.14, 0.55, 1],
            ),
        )
        ..restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PageCurlPainter oldDelegate) {
    return !identical(oldDelegate.geometry, geometry) ||
        oldDelegate.pageColor != pageColor ||
        oldDelegate.layer != layer;
  }
}

/// A leaf lifted by one corner and rolled back over itself.
///
/// The fold is the perpendicular bisector between the corner and the lifted
/// tip. Each flank of the roll is a quadratic curve from the page edge to the
/// flap's side. In fold coordinates, with `s` measured from the corner toward
/// the tip and `t` along the fold, both flanks trace the same parabola whose
/// vertex sits at [crest] of the reach. The regions are built in that frame
/// and cut to a band around the page, so an upright fold never produces the
/// far-away control points the page-space construction needs.
class PageCurlGeometry {
  /// Where the roll's crest sits, as a fraction of the corner-to-tip reach.
  static const double crest = 0.625;
  static const double _far = 1e9;
  static const int _flankSegments = 12;

  /// The part of the turning page still lying flat.
  final Path frontPath;

  /// The leaf's back where it has rolled over the page.
  final Path backPath;

  /// The page underneath, uncovered between the corner and the roll.
  final Path underPath;

  /// Mirrors the turning page across the fold onto its own back.
  final Matrix4 backTransform;
  final Offset corner;

  /// Unit vector from the corner toward the lifted tip.
  final Offset direction;
  final double reach;

  const PageCurlGeometry._({
    required this.frontPath,
    required this.backPath,
    required this.underPath,
    required this.backTransform,
    required this.corner,
    required this.direction,
    required this.reach,
  });

  /// Eases shadows in while the lift is still shallow.
  double get strength => (reach / 36).clamp(0.0, 1.0).toDouble();

  Offset pointAt(double fraction) => corner + direction * (reach * fraction);

  /// The pose for a horizontal drag. A forward turn carries the corner twice
  /// as far as the drag, so the fold tracks the finger. A backward turn
  /// returns the previous leaf upright with the roll's crest at the drag.
  static PageCurlGeometry? forDrag({
    required Size size,
    required double dragOffset,
    required PageCurlCorner corner,
    required double lift,
  }) {
    final width = size.width;
    if (dragOffset <= 0) {
      final cornerY = corner == PageCurlCorner.top ? 0.0 : size.height;
      return calculate(
        size: size,
        corner: corner,
        touch: Offset(width + 2 * dragOffset, cornerY + lift),
      );
    }
    return calculate(
      size: size,
      corner: PageCurlCorner.middle,
      touch: Offset(width - (width - dragOffset) / crest, size.height),
    );
  }

  /// Limits how far the corner may rise for a given horizontal [travel].
  /// The leaf is bound at its left edge, so the roll must start on the page's
  /// own top or bottom edge, and the tip stays within the page height.
  static double constrainLift(
    double lift, {
    required PageCurlCorner corner,
    required double travel,
    required Size size,
  }) {
    if (corner == PageCurlCorner.middle) return 0;
    // The roll meets that edge 0.75 * reach² / travel from the corner.
    // Keeping it within the page width bounds reach² by travel * width / 0.75.
    final bound = math.sqrt(
      math.max(0.0, travel * (size.width / 0.75 - travel)),
    );
    final limit = math.min(bound, size.height);
    return corner == PageCurlCorner.top
        ? lift.clamp(0.0, limit).toDouble()
        : lift.clamp(-limit, 0.0).toDouble();
  }

  static PageCurlGeometry? calculate({
    required Size size,
    required PageCurlCorner corner,
    required Offset touch,
  }) {
    final width = size.width;
    final height = size.height;
    if (width <= 0 || height <= 0) return null;
    final cornerPoint = Offset(
      width,
      corner == PageCurlCorner.top ? 0.0 : height,
    );
    final travel = (cornerPoint.dx - touch.dx).clamp(0.0, width * 2).toDouble();
    final lift = constrainLift(
      touch.dy - cornerPoint.dy,
      corner: corner,
      travel: travel,
      size: size,
    );
    final reach = math.sqrt(travel * travel + lift * lift);
    if (reach < 0.5) return null;
    final along = Offset(-travel / reach, lift / reach);
    final across = Offset(-along.dy, along.dx);

    // Where the straight fold meets the page edge running from the corner
    // in [edge], as a coordinate along the fold.
    double foot(Offset edge) {
      final towardTip = edge.dx * along.dx + edge.dy * along.dy;
      final alongFold = edge.dx * across.dx + edge.dy * across.dy;
      if (towardTip.abs() < 1e-9) return alongFold.sign * _far;
      return reach / 2 * alongFold / towardTip;
    }

    final horizontalFoot = foot(const Offset(-1, 0));
    final verticalFoot = foot(Offset(0, corner == PageCurlCorner.top ? 1 : -1));

    void addFlank(List<Offset> points, double foot, double from, double to) {
      for (var i = 0; i <= _flankSegments; i++) {
        final w = from + (to - from) * i / _flankSegments;
        points.add(Offset(reach * (crest + 0.5 * (w - 1) * (w - 1)), foot * w));
      }
    }

    final curl = <Offset>[Offset.zero];
    addFlank(curl, horizontalFoot, 1.5, 0.5);
    curl.add(Offset(reach, 0));
    addFlank(curl, verticalFoot, 0.5, 1.5);

    final back = <Offset>[];
    addFlank(back, horizontalFoot, 1, 0.5);
    back.add(Offset(reach, 0));
    addFlank(back, verticalFoot, 0.5, 1);

    final under = <Offset>[Offset.zero];
    addFlank(under, horizontalFoot, 1.5, 1);
    addFlank(under, verticalFoot, 1, 1.5);

    final band = (width + height) * 2;
    List<Offset> onPage(List<Offset> foldPoints) => [
      for (final point in _clipBand(foldPoints, band))
        cornerPoint + along * point.dx + across * point.dy,
    ];

    final curlPoints = onPage(curl);
    final frontPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPolygon(curlPoints, true);

    // Reflection across the fold: p' = p - 2((p - m) . u) u, with m on the
    // fold. Its determinant is -1, which mirrors the print.
    final foldDistance =
        cornerPoint.dx * along.dx + cornerPoint.dy * along.dy + reach / 2;
    final backTransform = Matrix4.identity()
      ..setEntry(0, 0, 1 - 2 * along.dx * along.dx)
      ..setEntry(0, 1, -2 * along.dx * along.dy)
      ..setEntry(1, 0, -2 * along.dx * along.dy)
      ..setEntry(1, 1, 1 - 2 * along.dy * along.dy)
      ..setEntry(0, 3, 2 * foldDistance * along.dx)
      ..setEntry(1, 3, 2 * foldDistance * along.dy);

    return PageCurlGeometry._(
      frontPath: frontPath,
      backPath: Path()..addPolygon(onPage(back), true),
      underPath: Path()..addPolygon(onPage(under), true),
      backTransform: backTransform,
      corner: cornerPoint,
      direction: along,
      reach: reach,
    );
  }

  static List<Offset> _clipBand(List<Offset> polygon, double limit) {
    return _clipHalf(_clipHalf(polygon, limit), -limit);
  }

  /// Keeps the part of [polygon] on the near side of the line `y = edge`:
  /// below it for a positive edge, above it for a negative one.
  static List<Offset> _clipHalf(List<Offset> polygon, double edge) {
    if (polygon.isEmpty) return polygon;
    bool inside(Offset point) => edge > 0 ? point.dy <= edge : point.dy >= edge;
    final clipped = <Offset>[];
    var previous = polygon.last;
    var previousInside = inside(previous);
    for (final point in polygon) {
      final pointInside = inside(point);
      if (pointInside != previousInside) {
        final t = (edge - previous.dy) / (point.dy - previous.dy);
        clipped.add(Offset(previous.dx + (point.dx - previous.dx) * t, edge));
      }
      if (pointInside) clipped.add(point);
      previous = point;
      previousInside = pointInside;
    }
    return clipped;
  }
}
