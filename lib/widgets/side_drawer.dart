import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/app_motion.dart';

/// Opens [builder] as a panel that slides in from the left edge.
///
/// While a finger drags the panel towards the edge it follows the finger
/// exactly, and the dimmed backdrop lightens by the same share. Letting go
/// past 40% of the way, or with a flick towards the edge, closes the panel
/// from where it is. Anything less springs it back open at the speed the
/// finger left it.
Future<T?> showSideDrawer<T>({
  required BuildContext context,
  required String barrierLabel,
  required Color barrierColor,
  required WidgetBuilder builder,
  double widthFactor = 0.86,
  double maxWidth = 360,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return Navigator.of(context).push(
    _SideDrawerRoute<T>(
      barrierLabel: barrierLabel,
      shade: barrierColor,
      builder: builder,
      widthFactor: widthFactor,
      maxWidth: maxWidth,
      openDuration: reduceMotion ? Duration.zero : AppMotion.drawer,
      closeDuration: reduceMotion ? Duration.zero : AppMotion.drawerClose,
    ),
  );
}

class _SideDrawerRoute<T> extends PopupRoute<T> {
  _SideDrawerRoute({
    required this.barrierLabel,
    required this.shade,
    required this.builder,
    required this.widthFactor,
    required this.maxWidth,
    required this.openDuration,
    required this.closeDuration,
  });

  @override
  final String barrierLabel;

  /// The backdrop colour when the panel is fully open. The route draws it
  /// itself, so the backdrop can lighten with the panel's drag.
  final Color shade;
  final WidgetBuilder builder;
  final double widthFactor;
  final double maxWidth;
  final Duration openDuration;
  final Duration closeDuration;

  /// How far the finger has pulled the panel towards the edge, in logical
  /// pixels, never positive.
  final ValueNotifier<double> _pull = ValueNotifier<double>(0);
  CurvedAnimation? _slide;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => openDuration;

  @override
  Duration get reverseTransitionDuration => closeDuration;

  double _panelWidth(BuildContext context) =>
      math.min(MediaQuery.sizeOf(context).width * widthFactor, maxWidth);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final width = _panelWidth(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: _DraggablePanel(
          pull: _pull,
          width: width,
          onDismiss: () {
            if (isCurrent) navigator?.pop();
          },
          child: Builder(builder: builder),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_slide?.parent != animation) {
      _slide?.dispose();
      _slide = CurvedAnimation(
        parent: animation,
        curve: AppMotion.sheetCurve,
        reverseCurve: AppMotion.exitOf(AppMotion.sheetCurve),
      );
    }
    final slide = _slide!;
    final width = _panelWidth(context);
    return AnimatedBuilder(
      animation: Listenable.merge([slide, _pull]),
      child: child,
      builder: (context, child) {
        final open = slide.value;
        final pull = _pull.value;
        // One source drives both: the backdrop is always exactly as light as
        // the panel is far from open, mid-drag and mid-close alike.
        final shown = width <= 0
            ? open
            : (open * (1 + pull / width)).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: ColoredBox(
                color: shade.withValues(alpha: shade.a * shown),
              ),
            ),
            Transform.translate(
              // Closing slides on from wherever the finger let go, so a
              // released drag carries on without jumping back first.
              offset: Offset((open - 1) * width + pull, 0),
              child: child,
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _slide?.dispose();
    _pull.dispose();
    super.dispose();
  }
}

class _DraggablePanel extends StatefulWidget {
  const _DraggablePanel({
    required this.pull,
    required this.width,
    required this.onDismiss,
    required this.child,
  });

  final ValueNotifier<double> pull;
  final double width;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_DraggablePanel> createState() => _DraggablePanelState();
}

class _DraggablePanelState extends State<_DraggablePanel>
    with SingleTickerProviderStateMixin {
  /// Flicks faster than this, in logical pixels per second, decide the
  /// outcome whatever the distance.
  static const double _flingVelocity = 200;

  /// The share of the panel's width a slow drag must cover to close it.
  static const double _closeShare = 0.4;

  /// Critically damped, so the panel returns quickly without swinging past
  /// the edge it is pinned to.
  static final SpringDescription _snapBack = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 700,
    ratio: 1,
  );

  late final AnimationController _settle;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        widget.pull.value = math.min(0.0, _settle.value);
      });
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _start(DragStartDetails _) {
    if (_closing) return;
    // Catching a panel that is still springing back keeps it where it is.
    _settle.stop();
  }

  void _update(DragUpdateDetails details) {
    if (_closing) return;
    widget.pull.value = math.min(0.0, widget.pull.value + details.delta.dx);
  }

  void _end(DragEndDetails details) {
    if (_closing) return;
    final velocity = details.primaryVelocity ?? 0;
    final pulled = widget.width <= 0 ? 0.0 : -widget.pull.value / widget.width;
    final close =
        velocity < -_flingVelocity ||
        (velocity <= _flingVelocity && pulled > _closeShare);
    if (close) {
      _closing = true;
      widget.onDismiss();
      return;
    }
    final from = widget.pull.value;
    if (from == 0) return;
    _settle.value = from;
    _settle.animateWith(SpringSimulation(_snapBack, from, 0, velocity));
  }

  void _cancel() => _end(DragEndDetails(primaryVelocity: 0));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _cancel,
      child: widget.child,
    );
  }
}
