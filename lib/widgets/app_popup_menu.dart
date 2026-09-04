import 'package:flutter/material.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

class AppMenuEntry<T> {
  const AppMenuEntry({
    required this.value,
    required this.label,
    this.icon,
    this.selected = false,
  });
  final T value;
  final String label;
  final IconData? icon;
  final bool selected;
}

class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.colors,
    required this.tooltip,
    required this.icon,
    required this.entries,
    required this.onSelected,
    this.enabled = true,
  });
  final ReaderThemeColors colors;
  final String tooltip;
  final Widget icon;
  final List<AppMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => AppOverlayTheme(
    colors: colors,
    child: PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled,
      position: PopupMenuPosition.under,
      onOpened: () => FocusManager.instance.primaryFocus?.unfocus(),
      onSelected: onSelected,
      icon: icon,
      color: colors.headerBg,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      constraints: const BoxConstraints(minWidth: 176, maxWidth: 280),
      menuPadding: const EdgeInsets.all(6),
      clipBehavior: Clip.antiAlias,
      shape: AppOverlayTheme.shape(colors, AppRadius.lg),
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
      itemBuilder: (_) => [
        for (final entry in entries)
          PopupMenuItem<T>(
            value: entry.value,
            padding: EdgeInsets.zero,
            height: 48,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: entry.selected
                    ? colors.accent.withValues(alpha: 0.10)
                    : null,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: entry.selected
                        ? Icon(
                            Icons.check_rounded,
                            size: 20,
                            color: colors.accent,
                          )
                        : entry.icon != null
                        ? Icon(entry.icon, size: 20, color: colors.secondary)
                        : null,
                  ),
                  Flexible(
                    child: Text(
                      entry.label,
                      style: TextStyle(
                        color: entry.selected ? colors.accent : colors.text,
                        fontSize: 14,
                        height: 1.5,
                        fontWeight: entry.selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
