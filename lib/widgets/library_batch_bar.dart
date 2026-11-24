import 'package:flutter/material.dart';

import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// Compact bottom bar shown during multi-select shelf management.
class LibraryBatchBar extends StatelessWidget {
  const LibraryBatchBar({
    super.key,
    required this.colors,
    required this.selectedCount,
    required this.privateMode,
    required this.onAssignGroups,
    required this.onTogglePrivate,
    required this.onDelete,
  });

  final ReaderThemeColors colors;
  final int selectedCount;
  final bool privateMode;
  final VoidCallback onAssignGroups;
  final VoidCallback onTogglePrivate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final enabled = selectedCount > 0;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final isDark = colors.background.computeLuminance() < 0.28;
    final dangerColor = AppOverlayTheme.danger(colors);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.headerBg,
        border: Border(top: BorderSide(color: colors.border)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm + bottomInset,
        ),
        child: Row(
          children: [
            Expanded(
              child: _BatchActionButton(
                icon: Icons.label_outline_rounded,
                label: '分组',
                color: colors.text,
                enabled: enabled,
                onTap: onAssignGroups,
              ),
            ),
            Expanded(
              child: _BatchActionButton(
                icon: privateMode
                    ? Icons.lock_open_rounded
                    : Icons.lock_outline_rounded,
                label: privateMode ? '移出隐私' : '移入隐私',
                color: colors.text,
                enabled: enabled,
                onTap: onTogglePrivate,
              ),
            ),
            Expanded(
              child: _BatchActionButton(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                color: dangerColor,
                enabled: enabled,
                onTap: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchActionButton extends StatelessWidget {
  const _BatchActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? color : color.withValues(alpha: 0.35);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: effectiveColor),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: effectiveColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
