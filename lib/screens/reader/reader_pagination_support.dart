part of '../reader_screen.dart';

class _SimulationLayoutSignature {
  final double contentWidth;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final String? importedFontFamily;
  final String? importedFontPath;
  final FontWeight fontWeight;
  final ReaderParagraphSpacing paragraphSpacing;

  _SimulationLayoutSignature({
    required this.contentWidth,
    required ReaderSettings settings,
  }) : fontSize = settings.fontSize,
       lineHeight = settings.lineHeight,
       fontFamily = settings.fontFamily,
       importedFontFamily = settings.importedFontFamily,
       importedFontPath = settings.importedFontPath,
       fontWeight = settings.effectiveFontWeight,
       paragraphSpacing = settings.paragraphSpacing;

  bool matches(_SimulationLayoutSignature other) {
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
class _ExactScrollExtentSliverChildBuilderDelegate
    extends SliverChildBuilderDelegate {
  final double exactScrollExtent;

  _ExactScrollExtentSliverChildBuilderDelegate(
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

class _SimulationPageTarget {
  final int chapterIndex;
  final double offset;
  final double progress;
  final bool goingNext;

  const _SimulationPageTarget({
    required this.chapterIndex,
    required this.offset,
    required this.progress,
    required this.goingNext,
  });

  bool matches(_SimulationPageTarget other) {
    return chapterIndex == other.chapterIndex &&
        goingNext == other.goingNext &&
        (offset - other.offset).abs() < 0.5;
  }
}

double _fullViewportMaxScrollExtent(
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
class _FullViewportPagingScrollController extends ScrollController {
  _FullViewportPagingScrollController({super.initialScrollOffset})
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
      _fullViewportMaxScrollExtent(maxScrollExtent, viewportDimension),
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
/// Once a non-empty selection exists, a finger dragging the underlying
/// Scrollable must not compete with the selection handle for the same pointer.
/// Chapter and continuous modes still allow programmatic [animateTo] calls so
/// Flutter can extend the selection at the viewport edge. Simulation mode adds
/// the stricter finite-page lock and rejects every pixel mutation.
class _SelectionAwareScrollController extends ScrollController {
  final ValueListenable<bool> selectionActive;
  final bool Function() freezeSelectionViewport;
  final bool paginateToFullViewports;

  _SelectionAwareScrollController({
    required this.selectionActive,
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
      viewportIsFrozen: () =>
          selectionActive.value && freezeSelectionViewport(),
      paginateToFullViewports: paginateToFullViewports,
    );
  }
}

class _SelectionAwareScrollPosition extends ScrollPositionWithSingleContext
    with _PageGridRealignMixin {
  final ValueListenable<bool> selectionActive;
  final bool Function() viewportIsFrozen;
  final bool paginateToFullViewports;
  Completer<void>? _frozenAnimationCompleter;

  _SelectionAwareScrollPosition({
    required super.physics,
    required super.context,
    required this.selectionActive,
    required this.viewportIsFrozen,
    required this.paginateToFullViewports,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    super.debugLabel,
  }) {
    selectionActive.addListener(_handleSelectionActivityChanged);
  }

  @override
  bool get pageGridRealignEnabled => paginateToFullViewports;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = super.applyContentDimensions(
      minScrollExtent,
      paginateToFullViewports
          ? _fullViewportMaxScrollExtent(maxScrollExtent, viewportDimension)
          : maxScrollExtent,
    );
    _schedulePageGridRealign();
    return applied;
  }

  void _handleSelectionActivityChanged() {
    if (!viewportIsFrozen()) _releaseFrozenAnimation();
  }

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
    if (selectionActive.value) return;
    super.applyUserOffset(delta);
  }

  @override
  void pointerScroll(double delta) {
    if (selectionActive.value) return;
    super.pointerScroll(delta);
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
    _releaseFrozenAnimation();
    super.dispose();
  }
}

class _ReadingTextAnchor {
  final int chapterIndex;
  final int paragraphIndex;
  final int characterOffset;

  const _ReadingTextAnchor({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.characterOffset,
  });
}

class _ScrollSnapshot {
  final double offset;
  final double progress;

  const _ScrollSnapshot({required this.offset, required this.progress});
}

enum _StraightPaperPaintLayer { base, lighting }

class _StraightLeafFrontClipper extends CustomClipper<Path> {
  final double progress;

  const _StraightLeafFrontClipper({required this.progress});

  @override
  Path getClip(Size size) =>
      _StraightLeafGeometry.calculate(size: size, progress: progress).frontPath;

  @override
  bool shouldReclip(covariant _StraightLeafFrontClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

class _StraightLeafBackClipper extends CustomClipper<Path> {
  final double progress;

  const _StraightLeafBackClipper({required this.progress});

  @override
  Path getClip(Size size) =>
      _StraightLeafGeometry.calculate(size: size, progress: progress).backPath;

  @override
  bool shouldReclip(covariant _StraightLeafBackClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

class _StraightPaperPainter extends CustomPainter {
  final double progress;
  final Color pageColor;
  final _StraightPaperPaintLayer layer;

  const _StraightPaperPainter({
    required this.progress,
    required this.pageColor,
    required this.layer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final p = progress.clamp(0.0, 1.0).toDouble();
    if (p <= 0 || p >= 1) return;
    final geometry = _StraightLeafGeometry.calculate(size: size, progress: p);
    final strength = geometry.foldStrength;
    final visibleBounds = geometry.backPath.getBounds().intersect(
      Offset.zero & size,
    );
    if (visibleBounds.width <= 0.1) return;

    final isDarkPage = pageColor.computeLuminance() < 0.25;
    if (layer == _StraightPaperPaintLayer.base) {
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
  bool shouldRepaint(covariant _StraightPaperPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.pageColor != pageColor ||
        oldDelegate.layer != layer;
  }
}

class _StraightLeafGeometry {
  final Path frontPath;
  final Path backPath;
  final double creaseX;
  final double outerEdgeX;
  final double foldStrength;

  const _StraightLeafGeometry({
    required this.frontPath,
    required this.backPath,
    required this.creaseX,
    required this.outerEdgeX,
    required this.foldStrength,
  });

  static _StraightLeafGeometry calculate({
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
    return _StraightLeafGeometry(
      frontPath: front,
      backPath: back,
      creaseX: creaseX,
      outerEdgeX: outerEdgeX,
      foldStrength: math.sin(math.pi * p).clamp(0.0, 1.0).toDouble(),
    );
  }
}
