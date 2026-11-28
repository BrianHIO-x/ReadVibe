import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/reader_note.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'pressable_scale.dart';

/// Custom floating selection toolbar featuring instant multi-color highlights,
/// stroke style toggles, rich note entry, quote card creation, and utilities.
class ReaderSelectionToolbar extends StatelessWidget {
  const ReaderSelectionToolbar({
    super.key,
    required this.anchors,
    required this.colors,
    required this.activeStyle,
    required this.onStyleChanged,
    required this.onQuickHighlight,
    this.onAddNote,
    this.onQuoteCard,
    required this.onCopy,
    this.onShare,
    this.onSelectAll,
    required this.onTranslate,
    required this.onSearch,
  });

  final TextSelectionToolbarAnchors anchors;
  final ReaderThemeColors colors;
  final NoteStyle activeStyle;
  final ValueChanged<NoteStyle> onStyleChanged;
  final ValueChanged<NoteColor> onQuickHighlight;
  final VoidCallback? onAddNote;
  final VoidCallback? onQuoteCard;
  final VoidCallback onCopy;
  final VoidCallback? onShare;
  final VoidCallback? onSelectAll;
  final VoidCallback onTranslate;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final isDark = colors.background.computeLuminance() < 0.35;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final textScale = media.textScaler.scale(1.0).clamp(1.0, 2.0);
    final safeTop = media.padding.top + 8;
    final safeLeft = media.padding.left + 12.0;
    final safeRight = screen.width - media.padding.right - 12.0;
    final safeBottom =
        screen.height - math.max(media.padding.bottom, media.viewInsets.bottom) - 8;
    final availableWidth = math.max(120.0, safeRight - safeLeft);
    final toolbarWidth = math.min(availableWidth, 344.0);
    final estimatedHeight = 76.0 + 28.0 * textScale;
    final primary = anchors.primaryAnchor;
    final maxLeft = math.max(safeLeft, safeRight - toolbarWidth);
    final left = (primary.dx - toolbarWidth / 2)
        .clamp(safeLeft, maxLeft)
        .toDouble();
    var top = primary.dy - estimatedHeight - 10;
    if (top < safeTop) {
      final secondary = anchors.secondaryAnchor ?? primary;
      top = (secondary.dy + 26)
          .clamp(safeTop, math.max(safeTop, safeBottom - estimatedHeight))
          .toDouble();
    }

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: toolbarWidth,
          child: Material(
            color: colors.headerBg,
            elevation: 8,
            shadowColor: Colors.black.withValues(alpha: isDark ? 0.55 : 0.2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              side: BorderSide(color: colors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final color in NoteColor.values) ...[
                          GestureDetector(
                            onTap: () => onQuickHighlight(color),
                            child: Semantics(
                              button: true,
                              label: '使用${color.label}高亮',
                              child: Container(
                                width: 24,
                                height: 24,
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: color.swatchColor(isDark),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        Container(
                          width: 1,
                          height: 18,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          color: colors.border,
                        ),
                        for (final style in NoteStyle.values)
                          GestureDetector(
                            onTap: () => onStyleChanged(style),
                            child: AnimatedContainer(
                              duration: AppMotion.quick,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: activeStyle == style
                                    ? colors.accent.withValues(alpha: 0.16)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                              ),
                              child: Icon(
                                style.icon,
                                size: 17,
                                color: activeStyle == style
                                    ? colors.accent
                                    : colors.secondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Divider(height: 10, thickness: 0.8, color: colors.border),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        if (onAddNote != null)
                          _ToolbarAction(
                            icon: Icons.edit_note_rounded,
                            label: '写笔记',
                            color: colors.accent,
                            textColor: colors.text,
                            onTap: onAddNote!,
                          ),
                        _ToolbarAction(
                          icon: Icons.copy_rounded,
                          label: '复制',
                          color: colors.secondary,
                          textColor: colors.text,
                          onTap: onCopy,
                        ),
                        if (onQuoteCard != null)
                          _ToolbarAction(
                            icon: Icons.style_outlined,
                            label: '金句卡',
                            color: colors.secondary,
                            textColor: colors.text,
                            onTap: onQuoteCard!,
                          ),
                        _ToolbarAction(
                          icon: Icons.translate_rounded,
                          label: '翻译',
                          color: colors.secondary,
                          textColor: colors.text,
                          onTap: onTranslate,
                        ),
                        _ToolbarAction(
                          icon: Icons.search_rounded,
                          label: '搜索',
                          color: colors.secondary,
                          textColor: colors.text,
                          onTap: onSearch,
                        ),
                        if (onShare != null)
                          _ToolbarAction(
                            icon: Icons.share_outlined,
                            label: '分享',
                            color: colors.secondary,
                            textColor: colors.text,
                            onTap: onShare!,
                          ),
                        if (onSelectAll != null)
                          _ToolbarAction(
                            icon: Icons.select_all_rounded,
                            label: '全选',
                            color: colors.secondary,
                            textColor: colors.text,
                            onTap: onSelectAll!,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.textColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      pressedScale: 0.93,
      pressedOpacity: 0.8,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
