import 'package:flutter/material.dart';

import '../models/reader_note.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'pressable_scale.dart';

/// Shared visual card presenting a quote highlight, thought note, category pill,
/// inline marker style badge, tags, and quick actions.
class ReaderNoteCard extends StatelessWidget {
  const ReaderNoteCard({
    super.key,
    required this.note,
    required this.colors,
    this.bookTitle,
    required this.onTap,
    required this.onEdit,
    required this.onQuoteCard,
    required this.onCopy,
    required this.onDelete,
  });

  final ReaderNote note;
  final ReaderThemeColors colors;
  final String? bookTitle;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onQuoteCard;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isDark = colors.background.computeLuminance() < 0.35;
    final swatch = note.color.swatchColor(isDark);
    final location = note.chapterTitle.isNotEmpty
        ? note.chapterTitle
        : (note.isPdf ? '第 ${note.chapterIndex + 1} 页' : '第 ${note.chapterIndex + 1} 章');
    final percentText = note.isPdf
        ? '第 ${note.chapterIndex + 1} 页'
        : '章内 ${(note.chapterProgress * 100).clamp(0, 100).round()}%';

    return PressableScale(
      pressedScale: 0.985,
      child: Material(
        color: colors.background.withValues(alpha: isDark ? 0.55 : 0.88),
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: colors.border),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  color: swatch,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 10, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: swatch.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(AppRadius.pill),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(note.category.icon, size: 12, color: swatch),
                                  const SizedBox(width: 4),
                                  Text(
                                    note.category.label,
                                    style: TextStyle(
                                      color: swatch,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!note.isPdf) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: colors.headerBg,
                                  borderRadius: BorderRadius.circular(AppRadius.sm),
                                  border: Border.all(color: colors.border),
                                ),
                                child: Text(
                                  note.style.label,
                                  style: TextStyle(
                                    color: colors.secondary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                            const Spacer(),
                            Text(
                              _formatDate(note.updatedAt),
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 11,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                        if (bookTitle != null && bookTitle!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '《$bookTitle》 · $location',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 6),
                          Text(
                            '$location · $percentText',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        if (note.hasQuote) ...[
                          const SizedBox(height: 7),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
                            decoration: BoxDecoration(
                              color: note.color.cardTint(isDark),
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Text(
                              '“${note.quote}”',
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.text.withValues(alpha: 0.9),
                                fontSize: 13.5,
                                height: 1.55,
                              ),
                            ),
                          ),
                        ],
                        if (note.hasContent) ...[
                          const SizedBox(height: 7),
                          Text(
                            note.content,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 14,
                              height: 1.55,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                        if (note.tags.isNotEmpty) ...[
                          const SizedBox(height: 7),
                          Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            children: [
                              for (final tag in note.tags)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: swatch.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(AppRadius.pill),
                                  ),
                                  child: Text(
                                    '#$tag',
                                    style: TextStyle(
                                      color: swatch,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _ActionIcon(
                              icon: Icons.near_me_outlined,
                              tooltip: '跳转原文',
                              color: swatch,
                              onPressed: onTap,
                            ),
                            _ActionIcon(
                              icon: Icons.style_outlined,
                              tooltip: '生成金句卡',
                              color: colors.secondary,
                              onPressed: onQuoteCard,
                            ),
                            _ActionIcon(
                              icon: Icons.edit_outlined,
                              tooltip: '编辑',
                              color: colors.secondary,
                              onPressed: onEdit,
                            ),
                            _ActionIcon(
                              icon: Icons.copy_rounded,
                              tooltip: '复制',
                              color: colors.secondary,
                              onPressed: onCopy,
                            ),
                            _ActionIcon(
                              icon: Icons.delete_outline_rounded,
                              tooltip: '删除',
                              color: colors.secondary,
                              onPressed: onDelete,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(icon, size: 17, color: color),
    );
  }
}
