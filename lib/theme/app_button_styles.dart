import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'app_motion.dart';
import 'app_spacing.dart';
import 'app_theme.dart';

/// Shared button, chip, switch, and checkbox styles eliminating default dark
/// ink splashes and delivering genuine whole-button elastic tactile motion
/// across the entire application.
class AppButtonStyles {
  static const _zeroElevation = WidgetStatePropertyAll<double>(0);
  static const _noColor = WidgetStatePropertyAll<Color>(Colors.transparent);
  static const _noSide = WidgetStatePropertyAll<BorderSide>(BorderSide.none);
  static const _buttonPadding = EdgeInsets.symmetric(
    horizontal: 18,
    vertical: 12,
  );
  static final _pillShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.pill),
  );

  static bool _isDark(ReaderThemeColors colors) =>
      colors.background.computeLuminance() < 0.35;

  static Color _onAccent(ReaderThemeColors colors) =>
      _isDark(colors) ? colors.background : Colors.white;

  static Color _pressedFill(Color base, {required bool dark}) =>
      Color.alphaBlend(
        (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? 0.14 : 0.11,
        ),
        base,
      );

  static Color _hoveredFill(Color base, {required bool dark}) =>
      Color.alphaBlend(
        (dark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        base,
      );

  static TextStyle _baseButtonText(ReaderThemeColors colors) => TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w600,
    color: colors.text,
  );

  static FilledButtonThemeData filledTheme(ReaderThemeColors colors) =>
      FilledButtonThemeData(style: filledOverride(colors));

  static ElevatedButtonThemeData elevatedTheme(ReaderThemeColors colors) =>
      ElevatedButtonThemeData(style: filledOverride(colors));

  static OutlinedButtonThemeData outlinedTheme(ReaderThemeColors colors) =>
      OutlinedButtonThemeData(style: outlinedOverride(colors));

  static TextButtonThemeData textTheme(ReaderThemeColors colors) =>
      TextButtonThemeData(style: textOverride(colors));

  static IconButtonThemeData iconTheme(ReaderThemeColors colors) =>
      IconButtonThemeData(style: iconOverride(colors));

  static ButtonStyle destructiveFilled(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final fill = scheme.error;
    final fg = scheme.onError;
    final disabledBg = Color.alphaBlend(
      fill.withValues(alpha: dark ? 0.36 : 0.42),
      scheme.surface,
    );
    return ButtonStyle(
      backgroundColor: _noColor,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return fg.withValues(alpha: 0.85);
        }
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return fg.withValues(alpha: 0.85);
        }
        return fg;
      }),
      side: _noSide,
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
      padding: const WidgetStatePropertyAll(_buttonPadding),
      shape: WidgetStatePropertyAll(_pillShape),
      backgroundBuilder: (context, states, child) => _TactileButtonChrome(
        states: states,
        shape: _pillShape,
        normalFill: fill,
        pressedFill: _pressedFill(fill, dark: dark),
        hoveredFill: _hoveredFill(fill, dark: dark),
        disabledFill: disabledBg,
        isFilled: true,
        dark: dark,
        pressedScale: 0.945,
        child: child,
      ),
    );
  }

  static ButtonStyle destructiveText(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final fg = scheme.error;
    return ButtonStyle(
      backgroundColor: _noColor,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return fg.withValues(alpha: 0.45);
        }
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return fg.withValues(alpha: 0.45);
        }
        return fg;
      }),
      side: _noSide,
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
      padding: const WidgetStatePropertyAll(_buttonPadding),
      shape: WidgetStatePropertyAll(_pillShape),
      backgroundBuilder: (context, states, child) => _TactileButtonChrome(
        states: states,
        shape: _pillShape,
        normalFill: Colors.transparent,
        pressedFill: fg.withValues(alpha: dark ? 0.16 : 0.10),
        hoveredFill: fg.withValues(alpha: dark ? 0.08 : 0.05),
        disabledFill: Colors.transparent,
        isFilled: false,
        dark: dark,
        pressedScale: 0.945,
        child: child,
      ),
    );
  }

  static ButtonStyle filledOverride(
    ReaderThemeColors colors, {
    Color? backgroundColor,
    Color? foregroundColor,
    EdgeInsetsGeometry? padding,
    OutlinedBorder? shape,
    Size? minimumSize,
  }) {
    final dark = _isDark(colors);
    final fill = backgroundColor ?? colors.accent;
    final fg = foregroundColor ?? _onAccent(colors);
    final effectiveShape = shape ?? _pillShape;
    final disabledBg = Color.alphaBlend(
      fill.withValues(alpha: dark ? 0.36 : 0.42),
      colors.headerBg,
    );
    final disabledFg = fg.withValues(alpha: 0.86);

    return ButtonStyle(
      backgroundColor: _noColor,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      side: _noSide,
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: WidgetStatePropertyAll(minimumSize ?? const Size(64, 48)),
      padding: WidgetStatePropertyAll(padding ?? _buttonPadding),
      textStyle: WidgetStatePropertyAll(_baseButtonText(colors)),
      shape: WidgetStatePropertyAll(effectiveShape),
      backgroundBuilder: (context, states, child) => _TactileButtonChrome(
        states: states,
        shape: effectiveShape,
        normalFill: fill,
        pressedFill: _pressedFill(fill, dark: dark),
        hoveredFill: _hoveredFill(fill, dark: dark),
        disabledFill: disabledBg,
        isFilled: true,
        dark: dark,
        pressedScale: 0.948,
        child: child,
      ),
    );
  }

  static ButtonStyle outlinedOverride(
    ReaderThemeColors colors, {
    Color? foregroundColor,
    Color? borderColor,
    EdgeInsetsGeometry? padding,
    OutlinedBorder? shape,
    Size? minimumSize,
  }) {
    final dark = _isDark(colors);
    final fg = foregroundColor ?? colors.accent;
    final sideColor = borderColor ?? colors.border;
    final effectiveShape = shape ?? _pillShape;
    final pressedTint = fg.withValues(alpha: dark ? 0.18 : 0.11);
    final hoverTint = fg.withValues(alpha: dark ? 0.09 : 0.05);
    final disabledFg = colors.secondary.withValues(alpha: 0.55);

    return ButtonStyle(
      backgroundColor: _noColor,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      side: _noSide,
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: WidgetStatePropertyAll(minimumSize ?? const Size(64, 48)),
      padding: WidgetStatePropertyAll(padding ?? _buttonPadding),
      textStyle: WidgetStatePropertyAll(_baseButtonText(colors)),
      shape: WidgetStatePropertyAll(effectiveShape),
      backgroundBuilder: (context, states, child) => _TactileButtonChrome(
        states: states,
        shape: effectiveShape,
        normalFill: Colors.transparent,
        pressedFill: pressedTint,
        hoveredFill: hoverTint,
        disabledFill: Colors.transparent,
        normalBorder: BorderSide(color: sideColor),
        pressedBorder: BorderSide(color: fg.withValues(alpha: 0.65), width: 1.2),
        disabledBorder: BorderSide(color: sideColor.withValues(alpha: 0.55)),
        isFilled: false,
        dark: dark,
        pressedScale: 0.948,
        child: child,
      ),
    );
  }

  static ButtonStyle textOverride(
    ReaderThemeColors colors, {
    Color? foregroundColor,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? tapTargetSize,
    TextStyle? textStyle,
  }) {
    final dark = _isDark(colors);
    final fg = foregroundColor ?? colors.secondary;
    final pressedTint = fg.withValues(alpha: dark ? 0.16 : 0.10);
    final hoverTint = fg.withValues(alpha: dark ? 0.08 : 0.05);
    final disabledFg = colors.secondary.withValues(alpha: 0.45);

    return ButtonStyle(
      backgroundColor: _noColor,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      side: _noSide,
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: WidgetStatePropertyAll(minimumSize ?? const Size(64, 48)),
      padding: WidgetStatePropertyAll(padding ?? _buttonPadding),
      textStyle: WidgetStatePropertyAll(textStyle ?? _baseButtonText(colors)),
      shape: WidgetStatePropertyAll(_pillShape),
      visualDensity: visualDensity,
      tapTargetSize: tapTargetSize,
      backgroundBuilder: (context, states, child) => _TactileButtonChrome(
        states: states,
        shape: _pillShape,
        normalFill: Colors.transparent,
        pressedFill: pressedTint,
        hoveredFill: hoverTint,
        disabledFill: Colors.transparent,
        isFilled: false,
        dark: dark,
        pressedScale: 0.945,
        child: child,
      ),
    );
  }

  static ButtonStyle iconOverride(
    ReaderThemeColors colors, {
    Color? foregroundColor,
    Size? minimumSize,
  }) {
    final dark = _isDark(colors);
    final fg = foregroundColor ?? colors.secondary;
    final pressedTint = colors.accent.withValues(alpha: dark ? 0.18 : 0.12);
    final hoverTint = colors.text.withValues(alpha: dark ? 0.08 : 0.05);
    final disabledFg = colors.secondary.withValues(alpha: 0.4);

    return ButtonStyle(
      backgroundColor: _noColor,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      side: _noSide,
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: WidgetStatePropertyAll(minimumSize ?? const Size(48, 48)),
      shape: WidgetStatePropertyAll(_pillShape),
      backgroundBuilder: (context, states, child) => _TactileButtonChrome(
        states: states,
        shape: _pillShape,
        normalFill: Colors.transparent,
        pressedFill: pressedTint,
        hoveredFill: hoverTint,
        disabledFill: Colors.transparent,
        isFilled: false,
        dark: dark,
        pressedScale: 0.88,
        child: child,
      ),
    );
  }

  static SegmentedButtonThemeData segmentedTheme(ReaderThemeColors colors) {
    final dark = _isDark(colors);
    final selectedBg = Color.alphaBlend(
      colors.accent.withValues(alpha: dark ? 0.24 : 0.14),
      colors.headerBg,
    );
    return SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return selectedBg;
          if (states.contains(WidgetState.pressed)) {
            return colors.accent.withValues(alpha: dark ? 0.14 : 0.08);
          }
          return colors.headerBg;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.secondary.withValues(alpha: 0.5);
          }
          if (states.contains(WidgetState.selected)) return colors.accent;
          return colors.text;
        }),
        side: WidgetStatePropertyAll(BorderSide(color: colors.border)),
        overlayColor: _noColor,
        splashFactory: NoSplash.splashFactory,
        elevation: _zeroElevation,
        shadowColor: _noColor,
        surfaceTintColor: _noColor,
        animationDuration: AppMotion.control,
      ),
    );
  }

  static ChipThemeData chipTheme(ReaderThemeColors colors) {
    final dark = _isDark(colors);
    final selectedTint = Color.alphaBlend(
      colors.accent.withValues(alpha: dark ? 0.24 : 0.14),
      colors.headerBg,
    );
    final selectedPressedTint = Color.alphaBlend(
      colors.accent.withValues(alpha: dark ? 0.32 : 0.20),
      colors.headerBg,
    );
    final unselectedPressedTint = Color.alphaBlend(
      colors.accent.withValues(alpha: dark ? 0.14 : 0.08),
      colors.headerBg,
    );

    return ChipThemeData(
      elevation: 0,
      pressElevation: 0,
      shadowColor: Colors.transparent,
      selectedShadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      backgroundColor: colors.headerBg,
      selectedColor: selectedTint,
      disabledColor: colors.headerBg.withValues(alpha: 0.55),
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.headerBg.withValues(alpha: 0.55);
        }
        if (states.contains(WidgetState.selected)) {
          return states.contains(WidgetState.pressed)
              ? selectedPressedTint
              : selectedTint;
        }
        if (states.contains(WidgetState.pressed)) {
          return unselectedPressedTint;
        }
        return colors.headerBg;
      }),
      checkmarkColor: colors.accent,
      side: WidgetStateBorderSide.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return BorderSide(color: colors.accent.withValues(alpha: 0.55));
        }
        return BorderSide(color: colors.border);
      }),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      labelStyle: TextStyle(fontSize: 13, color: colors.text),
      secondaryLabelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: colors.accent,
      ),
    );
  }

  static SwitchThemeData switchTheme(ReaderThemeColors colors) {
    final dark = _isDark(colors);
    final trackOff = Color.alphaBlend(
      colors.text.withValues(alpha: dark ? 0.16 : 0.12),
      colors.headerBg,
    );
    return SwitchThemeData(
      overlayColor: _noColor,
      splashRadius: 0,
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.secondary.withValues(alpha: 0.5);
        }
        if (states.contains(WidgetState.selected)) {
          return _onAccent(colors);
        }
        return colors.headerBg;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return trackOff.withValues(alpha: 0.5);
        }
        if (states.contains(WidgetState.selected)) {
          return colors.accent;
        }
        return trackOff;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return Colors.transparent;
        }
        return colors.border;
      }),
    );
  }

  static CheckboxThemeData checkboxTheme(ReaderThemeColors colors) {
    final fg = _onAccent(colors);
    return CheckboxThemeData(
      overlayColor: _noColor,
      splashRadius: 0,
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.secondary.withValues(alpha: 0.25);
        }
        if (states.contains(WidgetState.selected)) return colors.accent;
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(fg),
      side: WidgetStateBorderSide.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return BorderSide(color: colors.accent, width: 1.8);
        }
        return BorderSide(color: colors.border, width: 1.6);
      }),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    );
  }
}

/// Whole-button tactile chrome rendered inside [ButtonStyle.backgroundBuilder].
///
/// Scales the painted capsule, border, sheen highlight, AND foreground label
/// together as one cohesive physical object while keeping the outer [InkWell]
/// hit area rock-steady. A committed press impulse ensures even a brief 25 ms
/// tap clearly dips and rebounds smoothly.
class _TactileButtonChrome extends StatefulWidget {
  const _TactileButtonChrome({
    required this.states,
    required this.shape,
    required this.normalFill,
    required this.pressedFill,
    required this.hoveredFill,
    required this.disabledFill,
    required this.isFilled,
    required this.dark,
    required this.pressedScale,
    required this.child,
    this.normalBorder,
    this.pressedBorder,
    this.disabledBorder,
  });

  final Set<WidgetState> states;
  final OutlinedBorder shape;
  final Color normalFill;
  final Color pressedFill;
  final Color hoveredFill;
  final Color disabledFill;
  final BorderSide? normalBorder;
  final BorderSide? pressedBorder;
  final BorderSide? disabledBorder;
  final bool isFilled;
  final bool dark;
  final double pressedScale;
  final Widget? child;

  @override
  State<_TactileButtonChrome> createState() => _TactileButtonChromeState();
}

class _TactileButtonChromeState extends State<_TactileButtonChrome>
    with SingleTickerProviderStateMixin {
  static const _reboundSpring = SpringDescription(
    mass: 1.0,
    stiffness: 500.0,
    damping: 36.0,
  );

  late final AnimationController _pressController;
  bool _isPressed = false;
  DateTime? _pressedAt;
  Timer? _releaseTimer;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController.unbounded(vsync: this, value: 0.0);
    _isPressed = _statesPressed(widget.states);
  }

  static bool _statesPressed(Set<WidgetState> states) =>
      !states.contains(WidgetState.disabled) &&
      states.contains(WidgetState.pressed);

  @override
  void didUpdateWidget(covariant _TactileButtonChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextPressed = _statesPressed(widget.states);
    final disabled = widget.states.contains(WidgetState.disabled);
    if (disabled) {
      _releaseTimer?.cancel();
      _isPressed = false;
      if (_pressController.value != 0.0) {
        _pressController.animateTo(
          0.0,
          duration: AppMotion.fast,
          curve: AppMotion.controlCurve,
        );
      }
      return;
    }
    if (nextPressed && !_isPressed) {
      _isPressed = true;
      _pressedAt = DateTime.now();
      _releaseTimer?.cancel();
      if (MediaQuery.disableAnimationsOf(context)) {
        _pressController.value = 0.0;
      } else {
        _pressController.animateTo(
          1.0,
          duration: AppMotion.pressDown,
          curve: Curves.easeOutCubic,
        );
      }
    } else if (!nextPressed && _isPressed) {
      _isPressed = false;
      if (MediaQuery.disableAnimationsOf(context)) {
        _pressController.value = 0.0;
      } else {
        final elapsed = _pressedAt == null
            ? AppMotion.pressImpulseHold
            : DateTime.now().difference(_pressedAt!);
        final remaining = AppMotion.pressImpulseHold - elapsed;
        if (remaining > Duration.zero) {
          _releaseTimer?.cancel();
          _releaseTimer = Timer(remaining, _springBack);
        } else {
          _springBack();
        }
      }
    }
  }

  void _springBack() {
    if (!mounted || _isPressed) return;
    final sim = SpringSimulation(
      _reboundSpring,
      _pressController.value,
      0.0,
      0.0,
    );
    _pressController.animateWith(sim);
  }

  @override
  void dispose() {
    _releaseTimer?.cancel();
    _pressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.states.contains(WidgetState.disabled);
    final hovered =
        !disabled &&
        (widget.states.contains(WidgetState.hovered) ||
            widget.states.contains(WidgetState.focused));
    final baseColor = disabled
        ? widget.disabledFill
        : (hovered ? widget.hoveredFill : widget.normalFill);
    final baseBorder = disabled
        ? (widget.disabledBorder ?? BorderSide.none)
        : (widget.normalBorder ?? BorderSide.none);
    final targetPressedBorder = widget.pressedBorder ?? baseBorder;

    return AnimatedBuilder(
      animation: _pressController,
      child: widget.child,
      builder: (context, child) {
        final t = _pressController.value.clamp(0.0, 1.0);
        final scale = 1.0 + (widget.pressedScale - 1.0) * t;
        final color = Color.lerp(baseColor, widget.pressedFill, t) ?? baseColor;
        final side = BorderSide.lerp(baseBorder, targetPressedBorder, t);
        final sheenGradient = widget.isFilled && !disabled
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(
                    alpha: (widget.dark ? 0.12 : 0.16) * (1.0 - t * 0.65),
                  ),
                  Colors.transparent,
                  Colors.black.withValues(
                    alpha: (widget.dark ? 0.14 : 0.08) * (0.5 + t * 0.5),
                  ),
                ],
                stops: const [0.0, 0.45, 1.0],
              )
            : null;

        return Transform.scale(
          scale: scale,
          alignment: Alignment.center,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: color,
              shape: widget.shape.copyWith(side: side),
            ),
            child: sheenGradient != null
                ? DecoratedBox(
                    decoration: ShapeDecoration(
                      gradient: sheenGradient,
                      shape: widget.shape,
                    ),
                    child: child,
                  )
                : child,
          ),
        );
      },
    );
  }
}
