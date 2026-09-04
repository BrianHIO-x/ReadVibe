import 'package:flutter/material.dart';

import 'app_spacing.dart';
import 'app_theme.dart';

/// The reader palette is explicit: a route need not match the system theme.
class AppOverlayTheme extends StatelessWidget {
  const AppOverlayTheme({super.key, required this.colors, required this.child});

  final ReaderThemeColors colors;
  final Widget child;

  static bool isDark(ReaderThemeColors colors) =>
      colors.background.computeLuminance() < 0.35;

  static Color danger(ReaderThemeColors colors) =>
      isDark(colors) ? const Color(0xFFE6A09B) : AppTheme.error;

  static Color onAccent(ReaderThemeColors colors) =>
      isDark(colors) ? colors.background : Colors.white;

  static Color barrier(ReaderThemeColors colors) =>
      Colors.black.withValues(alpha: isDark(colors) ? 0.48 : 0.32);

  static RoundedRectangleBorder shape(
    ReaderThemeColors colors,
    double radius,
  ) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radius),
    side: BorderSide(color: colors.border),
  );

  static ThemeData data(ThemeData base, ReaderThemeColors colors) {
    final dark = isDark(colors);
    final error = danger(colors);
    final body = (base.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: colors.text,
      fontSize: 14,
      height: 1.5,
    );
    final title = body.copyWith(
      color: colors.text,
      fontSize: 18,
      height: 1.35,
      fontWeight: FontWeight.w600,
    );
    OutlineInputBorder inputBorder(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: color),
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.pill),
    );
    final buttonText = body.copyWith(fontSize: 14, fontWeight: FontWeight.w600);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 12);
    return base.copyWith(
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: (dark ? const ColorScheme.dark() : const ColorScheme.light())
          .copyWith(
            primary: colors.accent,
            onPrimary: onAccent(colors),
            secondary: colors.accent,
            onSecondary: onAccent(colors),
            surface: colors.headerBg,
            onSurface: colors.text,
            onSurfaceVariant: colors.secondary,
            outline: colors.border,
            error: error,
            onError: dark ? colors.background : Colors.white,
            surfaceTint: Colors.transparent,
          ),
      textTheme: base.textTheme
          .apply(bodyColor: colors.text, displayColor: colors.text)
          .copyWith(
            titleLarge: title,
            titleMedium: body.copyWith(fontWeight: FontWeight.w600),
            bodyLarge: body,
            bodyMedium: body,
            bodySmall: body.copyWith(fontSize: 12, color: colors.secondary),
            labelLarge: buttonText.copyWith(color: colors.text),
          ),
      iconTheme: IconThemeData(color: colors.secondary, size: 22),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.headerBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: shape(colors, AppRadius.pill),
        titleTextStyle: title,
        contentTextStyle: body,
        barrierColor: barrier(colors),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.headerBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        modalBarrierColor: barrier(colors),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.pill),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: onAccent(colors),
          disabledBackgroundColor: colors.text.withValues(alpha: 0.08),
          disabledForegroundColor: colors.secondary,
          minimumSize: const Size(64, 48),
          padding: buttonPadding,
          textStyle: buttonText,
          shape: buttonShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.secondary,
          minimumSize: const Size(64, 48),
          padding: buttonPadding,
          textStyle: buttonText,
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.accent,
          side: BorderSide(color: colors.border),
          minimumSize: const Size(64, 48),
          padding: buttonPadding,
          textStyle: buttonText,
          shape: buttonShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colors.secondary,
          minimumSize: const Size(48, 48),
          shape: buttonShape,
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: Color.alphaBlend(
          colors.text.withValues(alpha: 0.035),
          colors.headerBg,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: inputBorder(colors.border),
        enabledBorder: inputBorder(colors.border),
        focusedBorder: inputBorder(colors.accent),
        errorBorder: inputBorder(error),
        focusedErrorBorder: inputBorder(error),
        disabledBorder: inputBorder(colors.border),
        hintStyle: body.copyWith(color: colors.secondary),
        labelStyle: body.copyWith(color: colors.secondary),
        floatingLabelStyle: body.copyWith(color: colors.accent),
        helperStyle: body.copyWith(fontSize: 12, color: colors.secondary),
        errorStyle: body.copyWith(fontSize: 12, color: error),
        errorMaxLines: 3,
        counterStyle: body.copyWith(fontSize: 12, color: colors.secondary),
        prefixIconColor: colors.secondary,
        suffixIconColor: colors.secondary,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.accent,
        selectionColor: colors.accent.withValues(alpha: 0.24),
        selectionHandleColor: colors.accent,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minTileHeight: 52,
        iconColor: colors.secondary,
        textColor: colors.text,
        titleTextStyle: body.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: body.copyWith(color: colors.secondary, fontSize: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.headerBg,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        shape: shape(colors, AppRadius.lg),
        textStyle: body,
        labelTextStyle: WidgetStatePropertyAll(body),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.headerBg,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: body.copyWith(fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.accent),
    );
  }

  @override
  Widget build(BuildContext context) =>
      Theme(data: data(Theme.of(context), colors), child: child);
}
