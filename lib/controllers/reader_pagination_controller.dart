import 'dart:math' as math;

/// Pure pagination math shared by simulation scroll positions and tests.
class ReaderPaginationController {
  const ReaderPaginationController._();

  static double fullViewportMaxScrollExtent(
    double rawMaxScrollExtent,
    double viewportDimension, {
    double tolerance = 0.01,
  }) {
    if (!rawMaxScrollExtent.isFinite || rawMaxScrollExtent <= 0) return 0;
    if (!viewportDimension.isFinite || viewportDimension <= 0) {
      return rawMaxScrollExtent;
    }
    final rawPageCount = rawMaxScrollExtent / viewportDimension;
    final nearestPageCount = rawPageCount.round();
    final nearestExtent = nearestPageCount * viewportDimension;
    final pageCount = (rawMaxScrollExtent - nearestExtent).abs() <= tolerance
        ? nearestPageCount
        : rawPageCount.ceil();
    return math.max(0.0, pageCount * viewportDimension);
  }
}
