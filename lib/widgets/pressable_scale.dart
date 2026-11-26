import 'package:flutter/material.dart';
import '../theme/app_motion.dart';

/// Visual-only press feedback: shrinks [child] slightly while a pointer is
/// down on it, then releases smoothly.
///
/// This does NOT participate in gesture arbitration — it listens to raw
/// pointer events via [Listener] rather than registering a tap recognizer,
/// so it can wrap an [InkWell], [OutlinedButton], or [GestureDetector]
/// without stealing or delaying their own tap handling.
class PressableScale extends StatefulWidget {
  final Widget child;
  final double pressedScale;
  final double pressedOpacity;

  /// When false, press feedback is suppressed entirely — use this to wrap
  /// a button that is currently disabled, so a disabled control doesn't
  /// visually "react" to a tap it will never act on.
  final bool enabled;

  const PressableScale({
    super.key,
    required this.child,
    this.pressedScale = 0.97,
    this.pressedOpacity = 1.0,
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
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _pressed;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : (active ? AppMotion.pressDown : AppMotion.pressUp);
    final curve = active ? AppMotion.standard : AppMotion.controlCurve;

    Widget content = AnimatedScale(
      scale: active ? widget.pressedScale : 1.0,
      duration: duration,
      curve: curve,
      child: widget.child,
    );
    if (widget.pressedOpacity < 1.0) {
      content = AnimatedOpacity(
        opacity: active ? widget.pressedOpacity : 1.0,
        duration: duration,
        curve: curve,
        child: content,
      );
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: content,
    );
  }
}
