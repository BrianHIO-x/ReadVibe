import 'package:flutter/material.dart';

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
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

/// Sliding pill segmented control matching ReadVibe's warm minimalist motion
/// language, replacing Material's ink-splash [SegmentedButton].
class AppSegmentedControl<T> extends StatelessWidget {
  const AppSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.colors,
    required this.onChanged,
    this.enabled = true,
  });

  final List<AppSegmentOption<T>> options;
  final T value;
  final ReaderThemeColors colors;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    final dark = AppOverlayTheme.isDark(colors);
    final selectedIndex = options
        .indexWhere((o) => o.value == value)
        .clamp(0, options.length - 1);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced ? Duration.zero : AppMotion.control;

    final trackColor = Color.alphaBlend(
      colors.text.withValues(alpha: dark ? 0.09 : 0.045),
      colors.headerBg,
    );
    final thumbColor = Color.alphaBlend(
      colors.accent.withValues(alpha: dark ? 0.24 : 0.14),
      colors.headerBg,
    );
    final borderColor = colors.border;

    return LayoutBuilder(
      builder: (context, constraints) {
        final count = options.length;
        final totalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 280.0;
        final slotWidth = totalWidth / count;
        const height = 42.0;

        return AnimatedOpacity(
          opacity: enabled ? 1.0 : 0.65,
          duration: duration,
          child: SizedBox(
            width: totalWidth,
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: trackColor,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: borderColor),
              ),
              child: Stack(
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: selectedIndex.toDouble(),
                      end: selectedIndex.toDouble(),
                    ),
                    duration: duration,
                    curve: AppMotion.controlCurve,
                    builder: (context, animatedIndex, child) =>
                        Transform.translate(
                          offset: Offset(animatedIndex * slotWidth, 0),
                          child: child,
                        ),
                    child: SizedBox(
                      width: slotWidth,
                      height: height,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: thumbColor,
                            borderRadius: BorderRadius.circular(
                              AppRadius.md - 2,
                            ),
                            border: Border.all(
                              color: colors.accent.withValues(
                                alpha: dark ? 0.45 : 0.35,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        SizedBox(
                          width: slotWidth,
                          height: height,
                          child: _SegmentSlot(
                            option: options[i],
                            selected: i == selectedIndex,
                            enabled: enabled,
                            colors: colors,
                            duration: duration,
                            onTap: () {
                              if (enabled && options[i].value != value) {
                                onChanged(options[i].value);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ],
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
    required this.selected,
    required this.enabled,
    required this.colors,
    required this.duration,
    required this.onTap,
  });

  final AppSegmentOption<T> option;
  final bool selected;
  final bool enabled;
  final ReaderThemeColors colors;
  final Duration duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fgColor = selected ? colors.accent : colors.text;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: option.label,
      child: PressableScale(
        enabled: enabled,
        pressedScale: 0.965,
        pressedOpacity: 0.85,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(AppRadius.md - 2),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (option.icon != null) ...[
                      Icon(option.icon, size: 16, color: fgColor),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: AnimatedDefaultTextStyle(
                        duration: duration,
                        curve: AppMotion.controlCurve,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: fgColor,
                        ),
                        child: Text(
                          option.label,
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
