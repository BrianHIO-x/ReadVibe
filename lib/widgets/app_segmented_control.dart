import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'pressable_scale.dart';

/// Descriptor for one item inside [AppSegmentedControl].
class AppSegmentOption<T> {
  const AppSegmentOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.icon,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool enabled;
}

/// Visual presentation for [AppSegmentedControl].
enum AppSegmentedVariant {
  /// Elevated crisp paper/slate floating thumb on a recessed track (ideal for
  /// sheet tabs such as Data Safety, Backup, and Notes Hub).
  elevated,

  /// Rich accent-filled glowing pill with contrasting white label (ideal for
  /// compact reading settings and font pickers).
  accent,
}

/// Spring-physics sliding pill segmented control with velocity-driven liquid
/// stretch, live thumb-synchronized icon/text tinting, and subtle haptic ticks.
class AppSegmentedControl<T> extends StatefulWidget {
  const AppSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.colors,
    required this.onChanged,
    this.enabled = true,
    this.variant = AppSegmentedVariant.elevated,
    this.height = 44,
    this.fontSize = 13.5,
  });

  final List<AppSegmentOption<T>> options;
  final T value;
  final ReaderThemeColors colors;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final AppSegmentedVariant variant;
  final double height;
  final double fontSize;

  @override
  State<AppSegmentedControl<T>> createState() => _AppSegmentedControlState<T>();
}

class _AppSegmentedControlState<T> extends State<AppSegmentedControl<T>>
    with SingleTickerProviderStateMixin {
  static const _spring = SpringDescription(
    mass: 1.0,
    stiffness: 380.0,
    damping: 26.5,
  );

  late final AnimationController _controller;

  int _resolveIndex() {
    if (widget.options.isEmpty) return 0;
    final idx = widget.options.indexWhere((o) => o.value == widget.value);
    return idx < 0 ? 0 : idx;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(
      vsync: this,
      value: _resolveIndex().toDouble(),
    );
  }

  @override
  void didUpdateWidget(covariant AppSegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _resolveIndex().toDouble();
    final maxIdx = (widget.options.length - 1).clamp(0, 100).toDouble();
    if (_controller.value > maxIdx) {
      _controller.value = target;
      return;
    }
    if ((target - _controller.value).abs() < 0.001 && !_controller.isAnimating) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = target;
      return;
    }
    final sim = SpringSimulation(
      _spring,
      _controller.value,
      target,
      _controller.velocity,
    );
    _controller.animateWith(sim);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) return const SizedBox.shrink();
    final colors = widget.colors;
    final dark = AppOverlayTheme.isDark(colors);
    final selectedIndex = _resolveIndex();
    final count = widget.options.length;
    final isAccent = widget.variant == AppSegmentedVariant.accent;

    final trackColor = Color.alphaBlend(
      colors.text.withValues(alpha: dark ? 0.10 : 0.055),
      colors.headerBg,
    );
    final thumbColor = isAccent
        ? colors.accent
        : (dark
              ? Color.alphaBlend(
                  Colors.white.withValues(alpha: 0.11),
                  colors.headerBg,
                )
              : Color.alphaBlend(
                  Colors.white.withValues(alpha: 0.88),
                  colors.headerBg,
                ));
    final activeFg = isAccent
        ? (dark ? colors.background : Colors.white)
        : colors.accent;
    final inactiveFg = isAccent ? colors.text : colors.secondary;
    final outerRadius = isAccent ? AppRadius.md : AppRadius.lg - 2;
    final innerRadius = outerRadius - 3;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 280.0;
        const inset = 3.5;
        final innerWidth = (totalWidth - inset * 2).clamp(1.0, double.infinity);
        final slotWidth = innerWidth / count;
        final scaler = MediaQuery.textScalerOf(context);
        final hasSubtitle = widget.options.any(
          (option) => option.subtitle != null,
        );
        final scaledTextHeight = hasSubtitle
            ? scaler.scale(widget.fontSize) * 1.15 +
                  1 +
                  scaler.scale(9.5) * 1.1
            : scaler.scale(widget.fontSize) * 1.25;
        final minScaledHeight = scaledTextHeight + inset * 2 + 12;
        final effectiveHeight = widget.height >= minScaledHeight
            ? widget.height
            : minScaledHeight;
        final horizontalPad = count >= 5 ? 3.0 : 6.0;
        final effectiveFontSize =
            count >= 5 && widget.fontSize > 12.5 ? 12.5 : widget.fontSize;

        return AnimatedOpacity(
          opacity: widget.enabled ? 1.0 : 0.62,
          duration: AppMotion.fast,
          child: SizedBox(
            width: totalWidth,
            height: effectiveHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: trackColor,
                borderRadius: BorderRadius.circular(outerRadius),
                border: Border.all(
                  color: colors.border.withValues(alpha: dark ? 0.75 : 0.85),
                  width: 0.85,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(inset),
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final maxPos = (count - 1).toDouble();
                    final pos = _controller.value.clamp(-0.08, maxPos + 0.08);
                    final speed = _controller.isAnimating
                        ? _controller.velocity.abs()
                        : 0.0;
                    final stretchX =
                        1.0 + (speed * 0.014).clamp(0.0, 0.085);
                    final stretchY = 1.0 - (stretchX - 1.0) * 0.35;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: pos * slotWidth,
                          top: 0,
                          bottom: 0,
                          width: slotWidth,
                          child: Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.diagonal3Values(
                              stretchX,
                              stretchY,
                              1.0,
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: thumbColor,
                                borderRadius: BorderRadius.circular(innerRadius),
                                border: Border.all(
                                  color: isAccent
                                      ? Colors.white.withValues(
                                          alpha: dark ? 0.16 : 0.22,
                                        )
                                      : (dark
                                            ? Colors.white.withValues(alpha: 0.10)
                                            : colors.accent.withValues(alpha: 0.24)),
                                  width: 0.85,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: isAccent
                                        ? colors.accent.withValues(
                                            alpha: dark ? 0.36 : 0.28,
                                          )
                                        : Colors.black.withValues(
                                            alpha: dark ? 0.34 : 0.09,
                                          ),
                                    blurRadius: isAccent ? 12 : 10,
                                    offset: Offset(0, isAccent ? 4 : 2.5),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (var i = 0; i < count; i++)
                              SizedBox(
                                width: slotWidth,
                                height: double.infinity,
                                child: _SegmentSlot<T>(
                                  option: widget.options[i],
                                  closeness: (1.0 - (pos - i).abs())
                                      .clamp(0.0, 1.0),
                                  selected: i == selectedIndex,
                                  enabled:
                                      widget.enabled && widget.options[i].enabled,
                                  activeFg: activeFg,
                                  inactiveFg: inactiveFg,
                                  disabledFg: colors.secondary.withValues(
                                    alpha: 0.45,
                                  ),
                                  fontSize: effectiveFontSize,
                                  horizontalPadding: horizontalPad,
                                  borderRadius: innerRadius,
                                  onTap: () {
                                    final item = widget.options[i];
                                    if (!widget.enabled || !item.enabled) return;
                                    if (item.value != widget.value) {
                                      HapticFeedback.selectionClick();
                                      widget.onChanged(item.value);
                                    }
                                  },
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SegmentSlot<T> extends StatelessWidget {
  const _SegmentSlot({
    required this.option,
    required this.closeness,
    required this.selected,
    required this.enabled,
    required this.activeFg,
    required this.inactiveFg,
    required this.disabledFg,
    required this.fontSize,
    this.horizontalPadding = 6,
    required this.borderRadius,
    required this.onTap,
  });

  final AppSegmentOption<T> option;
  final double closeness;
  final bool selected;
  final bool enabled;
  final Color activeFg;
  final Color inactiveFg;
  final Color disabledFg;
  final double fontSize;
  final double horizontalPadding;
  final double borderRadius;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fgColor = !enabled
        ? disabledFg
        : (Color.lerp(inactiveFg, activeFg, closeness) ?? inactiveFg);
    final weight = closeness > 0.5 ? FontWeight.w600 : FontWeight.w500;

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: option.label,
      child: PressableScale(
        enabled: enabled,
        pressedScale: 0.94,
        pressedOpacity: 0.86,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(borderRadius),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: Center(
                child: option.subtitle != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            option.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: fontSize,
                              fontWeight: weight,
                              color: fgColor,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            option.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9.5,
                              color: fgColor.withValues(alpha: 0.78),
                              height: 1.1,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (option.icon != null) ...[
                            Icon(option.icon, size: 16, color: fgColor),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: fontSize,
                                fontWeight: weight,
                                color: fgColor,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Direction-aware sliding + fading + height-morphing content transition paired
/// with [AppSegmentedControl] so switching tabs inside floating sheets feels
/// fluid instead of snapping abruptly.
class AppTabTransition extends StatefulWidget {
  const AppTabTransition({
    super.key,
    required this.index,
    required this.child,
    this.animateSize = true,
  });

  final int index;
  final Widget child;
  final bool animateSize;

  @override
  State<AppTabTransition> createState() => _AppTabTransitionState();
}

class _AppTabTransitionState extends State<AppTabTransition> {
  int _direction = 1;

  @override
  void didUpdateWidget(covariant AppTabTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      _direction = widget.index > oldWidget.index ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced ? Duration.zero : AppMotion.tabSwitch;
    final switcher = AnimatedSwitcher(
      duration: duration,
      reverseDuration: reduced
          ? Duration.zero
          : const Duration(milliseconds: 200),
      switchInCurve: AppMotion.controlCurve,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        fit: widget.animateSize ? StackFit.loose : StackFit.passthrough,
        children: [
          ...previousChildren,
          ?currentChild,
        ],
      ),
      transitionBuilder: (child, animation) {
        if (reduced) return child;
        final isIncoming = child.key == widget.child.key;
        final dx = isIncoming ? 0.055 * _direction : -0.045 * _direction;
        final offsetTween = Tween<Offset>(
          begin: Offset(dx, 0),
          end: Offset.zero,
        );
        final scaleTween = Tween<double>(begin: 0.985, end: 1.0);
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0.08, 1.0, curve: Curves.easeOut),
          ),
          child: SlideTransition(
            position: offsetTween.animate(animation),
            child: ScaleTransition(
              scale: scaleTween.animate(animation),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );

    if (!widget.animateSize || reduced) return switcher;
    return AnimatedSize(
      duration: duration,
      curve: AppMotion.controlCurve,
      alignment: Alignment.topCenter,
      child: switcher,
    );
  }
}
