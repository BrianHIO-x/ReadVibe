import 'package:flutter/material.dart';

import 'app_motion.dart';
import 'app_spacing.dart';
import 'app_theme.dart';

/// Shared button, chip, switch, and checkbox styles eliminating default dark
/// ink splashes and shadow elevation flashes across the entire application.
class AppButtonStyles {
  static const _zeroElevation = WidgetStatePropertyAll<double>(0);
  static const _noColor = WidgetStatePropertyAll<Color>(Colors.transparent);
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
          alpha: dark ? 0.14 : 0.12,
        ),
        base,
      );

  static Color _hoveredFill(Color base, {required bool dark}) =>
      Color.alphaBlend(
        (dark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        base,
      );

  static Widget _tactileForeground(
    BuildContext context,
    Set<WidgetState> states,
    Widget? child,
  ) {
    final childWidget = child ?? const SizedBox.shrink();
    final pressed =
        !states.contains(WidgetState.disabled) &&
        states.contains(WidgetState.pressed);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : (pressed ? AppMotion.pressDown : AppMotion.pressUp);
    final curve = pressed ? AppMotion.standard : AppMotion.controlCurve;
    return AnimatedScale(
      scale: pressed ? 0.96 : 1.0,
      duration: duration,
      curve: curve,
      child: AnimatedOpacity(
        opacity: pressed ? 0.86 : 1.0,
        duration: duration,
        curve: curve,
        child: childWidget,
      ),
    );
  }

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
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledBg;
        if (states.contains(WidgetState.pressed)) {
          return _pressedFill(fill, dark: dark);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return _hoveredFill(fill, dark: dark);
        }
        return fill;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return fg.withValues(alpha: 0.85);
        }
        return fg;
      }),
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
      padding: const WidgetStatePropertyAll(_buttonPadding),
      shape: WidgetStatePropertyAll(_pillShape),
      foregroundBuilder: _tactileForeground,
    );
  }

  static ButtonStyle destructiveText(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final fg = scheme.error;
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) {
          return fg.withValues(alpha: dark ? 0.14 : 0.09);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return fg.withValues(alpha: dark ? 0.08 : 0.05);
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return fg.withValues(alpha: 0.45);
        }
        return fg;
      }),
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
      padding: const WidgetStatePropertyAll(_buttonPadding),
      shape: WidgetStatePropertyAll(_pillShape),
      foregroundBuilder: _tactileForeground,
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
    final disabledBg = Color.alphaBlend(
      fill.withValues(alpha: dark ? 0.36 : 0.42),
      colors.headerBg,
    );
    final disabledFg = fg.withValues(alpha: 0.86);

    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledBg;
        if (states.contains(WidgetState.pressed)) {
          return _pressedFill(fill, dark: dark);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return _hoveredFill(fill, dark: dark);
        }
        return fill;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: WidgetStatePropertyAll(minimumSize ?? const Size(64, 48)),
      padding: WidgetStatePropertyAll(padding ?? _buttonPadding),
      textStyle: WidgetStatePropertyAll(_baseButtonText(colors)),
      shape: WidgetStatePropertyAll(shape ?? _pillShape),
      foregroundBuilder: _tactileForeground,
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
    final pressedTint = fg.withValues(alpha: dark ? 0.16 : 0.09);
    final hoverTint = fg.withValues(alpha: dark ? 0.09 : 0.05);
    final disabledFg = colors.secondary.withValues(alpha: 0.55);

    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) return pressedTint;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return hoverTint;
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return BorderSide(color: sideColor.withValues(alpha: 0.55));
        }
        if (states.contains(WidgetState.pressed)) {
          return BorderSide(color: fg.withValues(alpha: 0.55));
        }
        return BorderSide(color: sideColor);
      }),
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: WidgetStatePropertyAll(minimumSize ?? const Size(64, 48)),
      padding: WidgetStatePropertyAll(padding ?? _buttonPadding),
      textStyle: WidgetStatePropertyAll(_baseButtonText(colors)),
      shape: WidgetStatePropertyAll(shape ?? _pillShape),
      foregroundBuilder: _tactileForeground,
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
    final pressedTint = fg.withValues(alpha: dark ? 0.14 : 0.09);
    final hoverTint = fg.withValues(alpha: dark ? 0.08 : 0.05);
    final disabledFg = colors.secondary.withValues(alpha: 0.45);

    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) return pressedTint;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return hoverTint;
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
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
      foregroundBuilder: _tactileForeground,
    );
  }

  static ButtonStyle iconOverride(
    ReaderThemeColors colors, {
    Color? foregroundColor,
    Size? minimumSize,
  }) {
    final dark = _isDark(colors);
    final fg = foregroundColor ?? colors.secondary;
    final pressedTint = colors.accent.withValues(alpha: dark ? 0.16 : 0.10);
    final hoverTint = colors.text.withValues(alpha: dark ? 0.08 : 0.05);
    final disabledFg = colors.secondary.withValues(alpha: 0.4);

    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) return pressedTint;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return hoverTint;
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledFg;
        return fg;
      }),
      overlayColor: _noColor,
      splashFactory: NoSplash.splashFactory,
      elevation: _zeroElevation,
      shadowColor: _noColor,
      surfaceTintColor: _noColor,
      animationDuration: AppMotion.pressDown,
      minimumSize: WidgetStatePropertyAll(minimumSize ?? const Size(48, 48)),
      shape: WidgetStatePropertyAll(_pillShape),
      foregroundBuilder: _tactileForeground,
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
