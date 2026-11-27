import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'pressable_scale.dart';

/// Tactile animated pill replacing Material's rigid [ChoiceChip], [FilterChip],
/// and [ActionChip].
///
/// Animates fill, border, ambient selection glow, text/icon tint, and a subtle
/// spring pop when selected — without jarring width jumps or dark ink flashes.
class AppChoicePill extends StatefulWidget {
  const AppChoicePill({
    super.key,
    required this.label,
    required this.colors,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
    this.icon,
    this.accentColor,
    this.showCheckmark = false,
    this.compact = false,
    this.pillShape = false,
    this.maxLabelWidth = 200,
  });

  final String label;
  final ReaderThemeColors colors;
  final VoidCallback? onTap;
  final bool selected;
  final bool enabled;
  final IconData? icon;
  final Color? accentColor;
  final bool showCheckmark;
  final bool compact;
  final bool pillShape;
  final double maxLabelWidth;

  @override
  State<AppChoicePill> createState() => _AppChoicePillState();
}

class _AppChoicePillState extends State<AppChoicePill>
    with SingleTickerProviderStateMixin {
  static const _popSpring = SpringDescription(
    mass: 1.0,
    stiffness: 440.0,
    damping: 20.0,
  );

  late final AnimationController _popController;

  @override
  void initState() {
    super.initState();
    _popController = AnimationController.unbounded(vsync: this, value: 0.0);
  }

  @override
  void didUpdateWidget(covariant AppChoicePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.selected && widget.selected) {
      if (!MediaQuery.disableAnimationsOf(context)) {
        _popController.value = 1.0;
        _popController.animateWith(
          SpringSimulation(_popSpring, 1.0, 0.0, 0.0),
        );
      }
    }
  }

  @override
  void dispose() {
    _popController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final dark = AppOverlayTheme.isDark(colors);
    final accent = widget.accentColor ?? colors.accent;
    final interactive = widget.enabled && widget.onTap != null;
    final selected = widget.selected;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced ? Duration.zero : AppMotion.control;

    final fillColor = selected
        ? Color.alphaBlend(
            accent.withValues(alpha: dark ? 0.26 : 0.14),
            colors.headerBg,
          )
        : Color.alphaBlend(
            colors.text.withValues(alpha: dark ? 0.05 : 0.02),
            colors.headerBg,
          );
    final borderColor = selected
        ? accent.withValues(alpha: dark ? 0.72 : 0.58)
        : colors.border;
    final fgColor = !widget.enabled
        ? colors.secondary.withValues(alpha: 0.5)
        : (selected ? accent : colors.text);
    final radius = widget.pillShape
        ? AppRadius.pill
        : (widget.compact ? AppRadius.sm + 2 : AppRadius.md);
    final padding = widget.compact
        ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
        : const EdgeInsets.symmetric(horizontal: 13, vertical: 8.5);
    final fontSize = widget.compact ? 12.0 : 13.0;

    return Semantics(
      button: true,
      selected: selected,
      enabled: interactive,
      label: widget.label,
      child: AnimatedBuilder(
        animation: _popController,
        builder: (context, child) {
          final popScale = 1.0 + 0.045 * _popController.value.clamp(-0.2, 1.0);
          return Transform.scale(scale: popScale, child: child);
        },
        child: PressableScale(
          enabled: interactive,
          pressedScale: 0.93,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: interactive
                  ? () {
                      HapticFeedback.selectionClick();
                      widget.onTap!();
                    }
                  : null,
              borderRadius: BorderRadius.circular(radius),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              child: AnimatedContainer(
                duration: duration,
                curve: AppMotion.controlCurve,
                padding: padding,
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: borderColor,
                    width: selected ? 1.25 : 0.95,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: accent.withValues(
                              alpha: dark ? 0.24 : 0.14,
                            ),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : const <BoxShadow>[],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.showCheckmark)
                      AnimatedSize(
                        duration: duration,
                        curve: AppMotion.controlCurve,
                        child: selected
                            ? Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: AnimatedScale(
                                  scale: selected ? 1.0 : 0.0,
                                  duration: duration,
                                  curve: AppMotion.controlCurve,
                                  child: Icon(
                                    Icons.check_rounded,
                                    size: widget.compact ? 14 : 15,
                                    color: fgColor,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    if (widget.icon != null) ...[
                      Icon(
                        widget.icon,
                        size: widget.compact ? 14 : 16,
                        color: selected ? accent : colors.secondary,
                      ),
                      const SizedBox(width: 5),
                    ],
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: widget.maxLabelWidth,
                      ),
                      child: AnimatedDefaultTextStyle(
                        duration: duration,
                        curve: AppMotion.controlCurve,
                        style: TextStyle(
                          fontSize: fontSize,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: fgColor,
                          height: 1.2,
                        ),
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
