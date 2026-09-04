import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/reader_settings.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

enum AppToastTone { info, success, error }

class AppToast {
  AppToast._();

  static void show(
    BuildContext context,
    String message, {
    AppToastTone tone = AppToastTone.info,
    Duration? duration,
    ReaderThemeColors? colors,
  }) => _present(
    context,
    message,
    tone: tone,
    duration: duration,
    colors: colors,
  );

  static void info(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
  }) => show(context, message, colors: colors);
  static void success(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
  }) => show(context, message, tone: AppToastTone.success, colors: colors);
  static void error(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
  }) => show(context, message, tone: AppToastTone.error, colors: colors);
  static void loading(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
  }) => _present(context, message, colors: colors, loading: true);

  static void hide(BuildContext context) =>
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();

  static void _present(
    BuildContext context,
    String message, {
    AppToastTone tone = AppToastTone.info,
    Duration? duration,
    ReaderThemeColors? colors,
    bool loading = false,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final palette =
        colors ??
        AppTheme.getReaderTheme(
          ReaderThemeMode.system,
          systemBrightness: Theme.of(context).brightness,
        );
    final dark = AppOverlayTheme.isDark(palette);
    final iconColor = switch (tone) {
      AppToastTone.info => palette.accent,
      AppToastTone.success => dark ? const Color(0xFF95BEA0) : AppTheme.success,
      AppToastTone.error => AppOverlayTheme.danger(palette),
    };
    final icon = switch (tone) {
      AppToastTone.info => Icons.info_outline_rounded,
      AppToastTone.success => Icons.check_circle_outline_rounded,
      AppToastTone.error => Icons.error_outline_rounded,
    };
    final side = math.max(16.0, (MediaQuery.sizeOf(context).width - 560) / 2);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          elevation: 0,
          backgroundColor: Colors.transparent,
          padding: EdgeInsets.zero,
          margin: EdgeInsets.fromLTRB(side, 0, side, 16),
          duration:
              duration ??
              (loading
                  ? const Duration(seconds: 30)
                  : Duration(
                      milliseconds: tone == AppToastTone.error ? 3200 : 2400,
                    )),
          dismissDirection: DismissDirection.none,
          content: Semantics(
            liveRegion: true,
            child: Material(
              key: const ValueKey('app-toast-surface'),
              color: palette.headerBg,
              surfaceTintColor: Colors.transparent,
              shape: AppOverlayTheme.shape(palette, AppRadius.lg),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: loading ? null : messenger.hideCurrentSnackBar,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        if (loading)
                          SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: iconColor,
                            ),
                          )
                        else
                          Icon(icon, color: iconColor, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            message,
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 14,
                              height: 1.5,
                              fontWeight: FontWeight.w400,
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
        ),
      );
  }
}
