import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// Visual tone for a short-lived in-app toast.
enum AppToastTone {
  /// Neutral status such as "checking for updates".
  info,

  /// Successful completion.
  success,

  /// Recoverable failure the user should notice.
  error,
}

/// Shared floating toast used everywhere the app needs brief feedback.
///
/// Design goals:
/// - soft surface colors that follow the current reader/shelf theme
/// - short automatic dismiss so the user never has to swipe it away
/// - tap-to-dismiss as the only manual close gesture
/// - no Material "swipe to dismiss" affordance and no instructional copy
class AppToast {
  AppToast._();

  static const Duration _infoDuration = Duration(milliseconds: 2200);
  static const Duration _successDuration = Duration(milliseconds: 2400);
  static const Duration _errorDuration = Duration(milliseconds: 3200);
  static const Duration _loadingDuration = Duration(seconds: 30);

  /// Shows a short auto-dismiss toast. Replaces any toast already on screen.
  static void show(
    BuildContext context,
    String message, {
    AppToastTone tone = AppToastTone.info,
    Duration? duration,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    final theme = _resolveTheme(context);
    final resolvedDuration = duration ?? _durationFor(tone);
    final palette = _paletteFor(tone, theme);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          elevation: 0,
          backgroundColor: Colors.transparent,
          padding: EdgeInsets.zero,
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          duration: resolvedDuration,
          // Keep the bar still; the only intentional close is tap or timeout.
          dismissDirection: DismissDirection.none,
          content: _AppToastCard(
            message: message,
            palette: palette,
            showSpinner: false,
            onTap: messenger.hideCurrentSnackBar,
          ),
        ),
      );
  }

  /// Convenience wrappers so call sites stay readable.
  static void info(BuildContext context, String message) =>
      show(context, message, tone: AppToastTone.info);

  static void success(BuildContext context, String message) =>
      show(context, message, tone: AppToastTone.success);

  static void error(BuildContext context, String message) =>
      show(context, message, tone: AppToastTone.error);

  /// Long-lived "please wait" toast. Call [hide] when the work finishes.
  static void loading(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    final theme = _resolveTheme(context);
    final palette = _paletteFor(AppToastTone.info, theme);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          elevation: 0,
          backgroundColor: Colors.transparent,
          padding: EdgeInsets.zero,
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          duration: _loadingDuration,
          dismissDirection: DismissDirection.none,
          content: _AppToastCard(
            message: message,
            palette: palette,
            showSpinner: true,
            onTap: null,
          ),
        ),
      );
  }

  static void hide(BuildContext context) {
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  }

  static Duration _durationFor(AppToastTone tone) {
    switch (tone) {
      case AppToastTone.info:
        return _infoDuration;
      case AppToastTone.success:
        return _successDuration;
      case AppToastTone.error:
        return _errorDuration;
    }
  }

  static ReaderThemeColors _resolveTheme(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    // Prefer the ambient Material brightness so shelf/settings and reader
    // toasts share the same soft surface language without each call site
    // threading a ReaderSettings object through.
    return AppTheme.getReaderTheme(
      ReaderThemeMode.system,
      systemBrightness: brightness,
    );
  }

  static _ToastPalette _paletteFor(
    AppToastTone tone,
    ReaderThemeColors theme,
  ) {
    final isDark = theme.background.computeLuminance() < 0.35;
    switch (tone) {
      case AppToastTone.info:
        return _ToastPalette(
          background: isDark
              ? const Color(0xFF2C2723)
              : const Color(0xFFFFFBF6),
          border: theme.border.withValues(alpha: isDark ? 0.9 : 1),
          foreground: theme.text,
          icon: Icons.info_outline_rounded,
          iconColor: theme.accent,
          shadow: Colors.black.withValues(alpha: isDark ? 0.34 : 0.10),
        );
      case AppToastTone.success:
        final green = isDark
            ? const Color(0xFF7FA88C)
            : AppTheme.success;
        return _ToastPalette(
          background: isDark
              ? const Color(0xFF243028)
              : const Color(0xFFEEF5F0),
          border: green.withValues(alpha: isDark ? 0.45 : 0.28),
          foreground: theme.text,
          icon: Icons.check_circle_outline_rounded,
          iconColor: green,
          shadow: Colors.black.withValues(alpha: isDark ? 0.34 : 0.08),
        );
      case AppToastTone.error:
        final red = isDark ? const Color(0xFFE08A8A) : AppTheme.error;
        return _ToastPalette(
          background: isDark
              ? const Color(0xFF322424)
              : const Color(0xFFFBF0F0),
          border: red.withValues(alpha: isDark ? 0.45 : 0.28),
          foreground: theme.text,
          icon: Icons.error_outline_rounded,
          iconColor: red,
          shadow: Colors.black.withValues(alpha: isDark ? 0.34 : 0.08),
        );
    }
  }
}

class _ToastPalette {
  final Color background;
  final Color border;
  final Color foreground;
  final IconData icon;
  final Color iconColor;
  final Color shadow;

  const _ToastPalette({
    required this.background,
    required this.border,
    required this.foreground,
    required this.icon,
    required this.iconColor,
    required this.shadow,
  });
}

class _AppToastCard extends StatelessWidget {
  final String message;
  final _ToastPalette palette;
  final bool showSpinner;
  final VoidCallback? onTap;

  const _AppToastCard({
    required this.message,
    required this.palette,
    required this.showSpinner,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final body = Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: palette.background,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: palette.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: palette.shadow,
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            if (showSpinner)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.iconColor,
                ),
              )
            else
              Icon(palette.icon, size: 20, color: palette.iconColor),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: palette.foreground,
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (onTap == null) return body;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: body,
    );
  }
}
