import 'dart:math' as math;

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

class AppPopupMenuButton<T> extends StatefulWidget {
  const AppPopupMenuButton({
    super.key,
    required this.colors,
    required this.tooltip,
    required this.icon,
    required this.entries,
    required this.onSelected,
    this.enabled = true,
    this.menuRightInset,
  });
  final ReaderThemeColors colors;
  final String tooltip;
  final Widget icon;
  final List<AppMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final bool enabled;

  /// Distance from the screen's right edge to the menu's right edge. Leave it
  /// null to trail the button. Setting it lines the menu up with the content
  /// column underneath instead of with the icon that opened it.
  final double? menuRightInset;

  @override
  State<AppPopupMenuButton<T>> createState() => _AppPopupMenuButtonState<T>();
}

class _AppPopupMenuButtonState<T> extends State<AppPopupMenuButton<T>> {
  Future<void> _openMenu() async {
    final button = context.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (button is! RenderBox || overlay is! RenderBox) return;
    if (!button.attached || !overlay.attached) return;
    FocusManager.instance.primaryFocus?.unfocus();

    final colors = widget.colors;
    final overlaySize = overlay.size;
    final anchorTopLeft = button.localToGlobal(
      Offset(0, button.size.height),
      ancestor: overlay,
    );
    final anchorBottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final right =
        widget.menuRightInset ?? overlaySize.width - anchorBottomRight.dx;
    // The menu route right-aligns itself only while left is past right, so keep
    // the anchor's left edge beyond it even for a button that sits far right.
    final left = math.max(anchorTopLeft.dx, right + 1);

    final selected = await showMenu<T>(
      context: context,
      position: RelativeRect.fromLTRB(
        left,
        anchorTopLeft.dy,
        right,
        overlaySize.height - anchorBottomRight.dy,
      ),
      color: colors.headerBg,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      constraints: const BoxConstraints(minWidth: 176, maxWidth: 280),
      menuPadding: const EdgeInsets.all(6),
      clipBehavior: Clip.antiAlias,
      shape: AppOverlayTheme.shape(colors, AppRadius.lg),
      items: [
        for (final entry in widget.entries) _buildItem(entry, colors),
      ],
    );
    if (!mounted || selected == null) return;
    widget.onSelected(selected);
  }

  PopupMenuItem<T> _buildItem(AppMenuEntry<T> entry, ReaderThemeColors colors) {
    return PopupMenuItem<T>(
      value: entry.value,
      padding: EdgeInsets.zero,
      height: 48,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: entry.selected ? colors.accent.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: entry.selected
                  ? Icon(Icons.check_rounded, size: 20, color: colors.accent)
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
    );
  }

  @override
  Widget build(BuildContext context) => AppOverlayTheme(
    colors: widget.colors,
    child: IconButton(
      tooltip: widget.tooltip,
      onPressed: widget.enabled && widget.entries.isNotEmpty ? _openMenu : null,
      icon: widget.icon,
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
  );
}
