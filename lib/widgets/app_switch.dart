import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// Fluid liquid-pill toggle switch with an elongating thumb during press and
/// state transition, smooth track tinting, and subtle haptic feedback.
class AppSwitch extends StatefulWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final ReaderThemeColors colors;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> {
  bool _pressed = false;
  bool _stretching = false;
  Timer? _stretchTimer;

  @override
  void didUpdateWidget(covariant AppSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _triggerStretch();
    }
  }

  void _triggerStretch() {
    _stretchTimer?.cancel();
    if (mounted) setState(() => _stretching = true);
    _stretchTimer = Timer(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => _stretching = false);
    });
  }

  @override
  void dispose() {
    _stretchTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final dark = AppOverlayTheme.isDark(colors);
    final enabled = widget.onChanged != null;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced ? Duration.zero : AppMotion.control;

    final trackOff = Color.alphaBlend(
      colors.text.withValues(alpha: dark ? 0.18 : 0.13),
      colors.headerBg,
    );
    final trackColor = widget.value ? colors.accent : trackOff;
    final thumbColor = widget.value
        ? (dark ? colors.background : Colors.white)
        : (dark
              ? Color.alphaBlend(
                  Colors.white.withValues(alpha: 0.85),
                  colors.headerBg,
                )
              : Colors.white);
    final isWide = !reduced && (_pressed || _stretching);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              widget.onChanged!(!widget.value);
            }
          : null,
      child: AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.45,
        duration: AppMotion.fast,
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.controlCurve,
          width: 50,
          height: 29,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: trackColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: widget.value
                  ? Colors.transparent
                  : colors.border.withValues(alpha: dark ? 0.65 : 0.9),
              width: 0.9,
            ),
            boxShadow: widget.value
                ? [
                    BoxShadow(
                      color: colors.accent.withValues(
                        alpha: dark ? 0.30 : 0.22,
                      ),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: AnimatedAlign(
            duration: duration,
            curve: const Cubic(0.22, 1.18, 0.36, 1.0),
            alignment: widget.value
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              width: isWide ? 27 : 23,
              height: 23,
              decoration: BoxDecoration(
                color: thumbColor,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.35 : 0.16),
                    blurRadius: 5,
                    offset: const Offset(0, 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drop-in replacement for [SwitchListTile.adaptive] pairing [AppSwitch] with
/// soft highlight row feedback and zero Material ink flash.
class AppSwitchTile extends StatefulWidget {
  const AppSwitchTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.colors,
    this.subtitle,
    this.secondary,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 11,
    ),
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final Widget? secondary;
  final ReaderThemeColors colors;
  final EdgeInsetsGeometry contentPadding;

  @override
  State<AppSwitchTile> createState() => _AppSwitchTileState();
}

class _AppSwitchTileState extends State<AppSwitchTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final colors = widget.colors;
    final dark = AppOverlayTheme.isDark(colors);
    final highlight = _pressed && enabled
        ? colors.accent.withValues(alpha: dark ? 0.10 : 0.06)
        : Colors.transparent;

    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                widget.onChanged!(!widget.value);
              }
            : null,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.controlCurve,
          color: highlight,
          padding: widget.contentPadding,
          child: Row(
            children: [
              if (widget.secondary != null) ...[
                IconTheme.merge(
                  data: IconThemeData(color: colors.secondary, size: 22),
                  child: widget.secondary!,
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: enabled
                            ? colors.text
                            : colors.secondary.withValues(alpha: 0.55),
                        height: 1.35,
                      ),
                      child: widget.title,
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 3),
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondary,
                          height: 1.4,
                        ),
                        child: widget.subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              AppSwitch(
                value: widget.value,
                onChanged: widget.onChanged,
                colors: colors,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
