import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Shared motion tokens: durations and curves used across every hand-rolled
/// animation in the app. Mirrors the token style of AppSpacing/AppRadius —
/// there is no third-party animation dependency, everything here is driven
/// by Flutter's built-in animation APIs.
class AppMotion {
  /// Micro press feedback (see [PressableScale]).
  static const quick = Duration(milliseconds: 96);

  /// Small UI entrances such as overlay bars.
  static const fast = Duration(milliseconds: 180);

  /// General UI colour/shape changes.
  static const normal = Duration(milliseconds: 240);

  /// Segmented controls and small setting chips. Long enough to read as
  /// deliberate, short enough to keep repeated setting changes responsive.
  static const control = Duration(milliseconds: 260);

  /// Reader top/bottom chrome.
  static const menu = Duration(milliseconds: 280);

  /// Bottom sheets.
  static const sheet = Duration(milliseconds: 360);

  /// Side drawer.
  static const drawer = Duration(milliseconds: 360);

  /// Delay applying expensive reader relayout after a settings tap so the
  /// control's own selection animation gets a clean first few frames.
  static const settingApplyDelay = Duration(milliseconds: 120);

  /// Finger-up page settle. Dragging is still fully finger-tracked; this only
  /// affects the release-to-settle portion.
  static const pageTurn = Duration(milliseconds: 220);

  /// Book opening route transition.
  ///
  /// The motion now has enough runway to read as a deliberate transition:
  /// original cover snapshot enlarges → one page opens → reader content takes
  /// over. This is intentionally slower than a generic app route push because
  /// the book is the emotional centre of the reader.
  static const bookOpen = Duration(milliseconds: 680);

  /// Book closing route transition. Slightly shorter than opening, but it
  /// follows the same choreography in reverse so the model stays consistent.
  static const bookClose = Duration(milliseconds: 520);

  /// Low-frequency route/dialog transition.
  static const slow = Duration(milliseconds: 360);

  static const standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const gentle = Curves.easeInOutCubic;
  static const controlCurve = Cubic(0.16, 1.0, 0.3, 1.0);

  /// A soft material-like pickup curve: quick response at the beginning,
  /// then a calm settle before the heavier page expansion.
  static const bookPickupCurve = Cubic(0.18, 0.82, 0.18, 1.0);

  /// Cover rotation is allowed to accelerate early, then decelerate near the
  /// hinge so it does not read as a flat card sliding away.
  static const bookCoverCurve = Cubic(0.16, 0.0, 0.05, 1.0);

  /// Reserved for low-frequency emphasis moments (e.g. a delete
  /// confirmation dialog). The slight overshoot reads as "pay attention
  /// here" — do not use it on anything that repeats often, it gets
  /// tiring fast.
  static const emphasized = Curves.easeOutBack;
}

/// Book-like page transition used for pushing the reader screen.
///
/// The implementation follows the same mental model as HarmonyOS' official
/// animation guidance around page transitions and shared-element/"one shot"
/// continuity: the tapped object remains visually identifiable, changes
/// position and size continuously, then hands off to the destination page.
///
/// The old route was a generic fade/scale. This one stages the interaction as
/// a single-page opening transition:
///
/// 1. the original shelf cover snapshot is enlarged;
/// 2. that single page rotates around its left edge, opening from right to
///    left;
/// 3. the reader surface takes over only after the page is open.
///
/// Popping the route runs the same timeline backwards, so closing feels like
/// folding that page shut and returning it to the shelf.
Route<T> buildFadeScaleRoute<T>(
  WidgetBuilder builder, {
  RouteSettings? settings,
  Rect? sourceRect,
  ui.Image? coverImage,
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    opaque: false,
    transitionDuration: AppMotion.bookOpen,
    reverseTransitionDuration: AppMotion.bookClose,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return _BookRouteTransition(
        animation: animation,
        sourceRect: sourceRect,
        coverImage: coverImage,
        child: child,
      );
    },
  );
}

class _BookRouteTransition extends StatelessWidget {
  final Animation<double> animation;
  final Rect? sourceRect;
  final ui.Image? coverImage;
  final Widget child;

  const _BookRouteTransition({
    required this.animation,
    required this.sourceRect,
    required this.coverImage,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final routeChild = RepaintBoundary(child: child);

    return AnimatedBuilder(
      animation: animation,
      child: routeChild,
      builder: (context, child) {
        final screenSize = MediaQuery.sizeOf(context);
        if (screenSize.width <= 0 || screenSize.height <= 0) {
          return child ?? const SizedBox.shrink();
        }

        final progress = _clamp01(animation.value);
        final fullRect = Offset.zero & screenSize;
        final startRect = _resolveStartRect(sourceRect, fullRect);

        final pickupProgress = _interval(
          progress,
          0.0,
          0.22,
          AppMotion.bookPickupCurve,
        );
        final travelProgress = _interval(
          progress,
          0.02,
          0.48,
          AppMotion.standard,
        );
        final coverOpenProgress = _interval(
          progress,
          0.38,
          0.96,
          AppMotion.bookCoverCurve,
        );
        final contentProgress = _interval(
          progress,
          0.46,
          0.92,
          AppMotion.standard,
        );
        final radiusProgress = _interval(
          progress,
          0.34,
          1.0,
          AppMotion.standard,
        );

        final liftedRect = _scaleRect(
          startRect,
          _lerpDouble(1.0, 1.08, pickupProgress),
        ).translate(0, _lerpDouble(0, -8, pickupProgress));
        final rect = Rect.lerp(liftedRect, fullRect, travelProgress)!;
        final radius = _lerpDouble(16, 0, radiusProgress);
        final dimOpacity =
            0.16 * _interval(progress, 0.0, 0.58, AppMotion.gentle);
        final liftShadow = math.sin(progress * math.pi).abs();
        final shadowOpacity = 0.08 + 0.24 * liftShadow * (1 - radiusProgress);

        return AbsorbPointer(
          absorbing: progress < 0.995,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: dimOpacity),
                ),
              ),
              Positioned.fromRect(
                rect: rect,
                child: RepaintBoundary(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: shadowOpacity),
                          blurRadius: _lerpDouble(18, 44, liftShadow),
                          spreadRadius: _lerpDouble(0, 2, liftShadow),
                          offset: Offset(0, _lerpDouble(8, 22, liftShadow)),
                        ),
                      ],
                    ),
                    child: _BookRouteFrame(
                      screenSize: screenSize,
                      radius: radius,
                      contentProgress: contentProgress,
                      coverOpenProgress: coverOpenProgress,
                      coverImage: coverImage,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BookRouteFrame extends StatelessWidget {
  final Size screenSize;
  final double radius;
  final double contentProgress;
  final double coverOpenProgress;
  final ui.Image? coverImage;
  final Widget child;

  const _BookRouteFrame({
    required this.screenSize,
    required this.radius,
    required this.contentProgress,
    required this.coverOpenProgress,
    required this.coverImage,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = isDark ? const Color(0xFF1A1816) : AppTheme.background;
    final contentOpacity = _lerpDouble(0.0, 1.0, contentProgress);
    final pageOpacity =
        1.0 - _interval(coverOpenProgress, 0.86, 1.0, Curves.easeOutCubic);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: pageColor,
        child: Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            Opacity(
              opacity: contentOpacity,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: screenSize.width,
                  height: screenSize.height,
                  child: child,
                ),
              ),
            ),
            if (pageOpacity > 0.001)
              Opacity(
                opacity: pageOpacity,
                child: _OpeningPage(
                  coverImage: coverImage,
                  openProgress: coverOpenProgress,
                  isDark: isDark,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OpeningPage extends StatelessWidget {
  final ui.Image? coverImage;
  final double openProgress;
  final bool isDark;

  const _OpeningPage({
    required this.coverImage,
    required this.openProgress,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final angle = -math.pi / 2 * openProgress;
    final foldShadow = math.sin(openProgress * math.pi).abs();
    final fallbackColor = isDark
        ? const Color(0xFF2A2623)
        : AppTheme.surfaceWarm;

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform(
          alignment: Alignment.centerLeft,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateY(angle),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fallbackColor,
              border: Border.all(
                color: isDark ? const Color(0xFF3A3530) : AppTheme.border,
                width: 0.7,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (coverImage != null)
                  RawImage(image: coverImage, fit: BoxFit.fill)
                else
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: isDark
                            ? const [Color(0xFF2C2723), Color(0xFF211D1A)]
                            : const [Color(0xFFFBF5EC), Color(0xFFEDE2D3)],
                      ),
                    ),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.black.withValues(
                          alpha: (isDark ? 0.22 : 0.12) * foldShadow,
                        ),
                        Colors.transparent,
                        Colors.white.withValues(
                          alpha: (isDark ? 0.04 : 0.10) * (1 - openProgress),
                        ),
                      ],
                      stops: const [0.0, 0.42, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (foldShadow > 0.001)
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.11,
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(
                        alpha: (isDark ? 0.30 : 0.18) * foldShadow,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

Rect _resolveStartRect(Rect? sourceRect, Rect fullRect) {
  final fallback = Rect.fromCenter(
    center: fullRect.center,
    width: fullRect.width * 0.42,
    height: fullRect.height * 0.42,
  );

  if (sourceRect == null ||
      sourceRect.isEmpty ||
      !sourceRect.left.isFinite ||
      !sourceRect.top.isFinite ||
      !sourceRect.width.isFinite ||
      !sourceRect.height.isFinite) {
    return fallback;
  }

  final minWidth = math.min(96.0, fullRect.width * 0.36);
  final minHeight = math.min(136.0, fullRect.height * 0.36);
  final maxWidth = fullRect.width * 0.92;
  final maxHeight = fullRect.height * 0.92;
  final width = sourceRect.width.clamp(minWidth, maxWidth).toDouble();
  final height = sourceRect.height.clamp(minHeight, maxHeight).toDouble();
  final center = Offset(
    sourceRect.center.dx.clamp(0.0, fullRect.width).toDouble(),
    sourceRect.center.dy.clamp(0.0, fullRect.height).toDouble(),
  );

  return Rect.fromCenter(center: center, width: width, height: height);
}

Rect _scaleRect(Rect rect, double scale) {
  return Rect.fromCenter(
    center: rect.center,
    width: rect.width * scale,
    height: rect.height * scale,
  );
}

double _interval(double value, double begin, double end, Curve curve) {
  if (value <= begin) return 0;
  if (value >= end) return 1;
  final t = (value - begin) / (end - begin);
  return _clamp01(curve.transform(_clamp01(t)));
}

double _clamp01(double value) => value.clamp(0.0, 1.0).toDouble();

double _lerpDouble(double begin, double end, double t) {
  return begin + (end - begin) * _clamp01(t);
}
