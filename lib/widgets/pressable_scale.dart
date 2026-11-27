import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/app_motion.dart';

/// Visual-only press feedback with a committed spring-pulse animation:
/// even a quick light tap visibly compresses [child] to [pressedScale] and
/// springs smoothly back to 1.0 with an organic elastic settle.
///
/// Uses raw [Listener] pointer events so it never interferes with [InkWell],
/// [GestureDetector], or button gesture arenas.
class PressableScale extends StatefulWidget {
  final Widget child;
  final double pressedScale;
  final double pressedOpacity;

  /// When false, press feedback is suppressed entirely.
  final bool enabled;

  const PressableScale({
    super.key,
    required this.child,
    this.pressedScale = 0.955,
    this.pressedOpacity = 1.0,
    this.enabled = true,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale>
    with SingleTickerProviderStateMixin {
  static const _releaseSpring = SpringDescription(
    mass: 1.0,
    stiffness: 460.0,
    damping: 25.0,
  );

  late final AnimationController _controller;
  bool _pointerDown = false;
  DateTime? _downAt;
  Timer? _releaseTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this, value: 0.0);
  }

  @override
  void didUpdateWidget(covariant PressableScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _releaseTimer?.cancel();
      _pointerDown = false;
      _controller.value = 0.0;
    }
  }

  @override
  void dispose() {
    _releaseTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent _) {
    if (!widget.enabled || !mounted) return;
    _releaseTimer?.cancel();
    _pointerDown = true;
    _downAt = DateTime.now();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 0.0;
      return;
    }
    _controller.animateTo(
      1.0,
      duration: AppMotion.pressDown,
      curve: Curves.easeOutCubic,
    );
  }

  void _onUpOrCancel() {
    if (!_pointerDown || !mounted) return;
    _pointerDown = false;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 0.0;
      return;
    }
    final elapsed = _downAt == null
        ? AppMotion.pressImpulseHold
        : DateTime.now().difference(_downAt!);
    final remaining = AppMotion.pressImpulseHold - elapsed;
    if (remaining > Duration.zero) {
      _releaseTimer?.cancel();
      _releaseTimer = Timer(remaining, _springRelease);
    } else {
      _springRelease();
    }
  }

  void _springRelease() {
    if (!mounted || _pointerDown) return;
    final sim = SpringSimulation(_releaseSpring, _controller.value, 0.0, 0.0);
    _controller.animateWith(sim);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerUp: (_) => _onUpOrCancel(),
      onPointerCancel: (_) => _onUpOrCancel(),
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final t = _controller.value;
          final scale = 1.0 + (widget.pressedScale - 1.0) * t;
          Widget result = Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: child,
          );
          if (widget.pressedOpacity < 1.0) {
            final opacity = (1.0 + (widget.pressedOpacity - 1.0) * t.clamp(0.0, 1.0))
                .clamp(0.0, 1.0);
            result = Opacity(opacity: opacity, child: result);
          }
          return result;
        },
      ),
    );
  }
}
