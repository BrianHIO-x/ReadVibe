import 'package:flutter/material.dart';
import '../theme/app_motion.dart';

/// Visual-only press feedback: shrinks [child] slightly while a pointer is
/// down on it.
///
/// This does NOT participate in gesture arbitration — it listens to raw
/// pointer events via [Listener] rather than registering a tap recognizer,
/// so it can wrap an [InkWell], [OutlinedButton], or [GestureDetector]
/// without stealing or delaying their own tap handling.
class PressableScale extends StatefulWidget {
  final Widget child;
  final double pressedScale;

  /// When false, press feedback is suppressed entirely — use this to wrap
  /// a button that is currently disabled, so a disabled control doesn't
  /// visually "react" to a tap it will never act on.
  final bool enabled;

  const PressableScale({
    super.key,
    required this.child,
    this.pressedScale = 0.97,
    this.enabled = true,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  void didUpdateWidget(covariant PressableScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) _pressed = false;
  }

  void _setPressed(bool value) {
    if (!widget.enabled) return;
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: (widget.enabled && _pressed) ? widget.pressedScale : 1.0,
        duration: AppMotion.quick,
        curve: AppMotion.standard,
        child: widget.child,
      ),
    );
  }
}
