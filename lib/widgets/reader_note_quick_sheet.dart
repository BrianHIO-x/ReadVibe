import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/reader_note.dart';
import '../theme/app_button_styles.dart';
import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_sheet.dart';
import 'app_toast.dart';

enum QuickNoteAction { edit, quoteCard, delete }

/// Compact bottom sheet displayed when the user taps an existing inline
/// highlight or underline inside the reading canvas.
Future<QuickNoteAction?> showReaderNoteQuickSheet({
  required BuildContext context,
  required ReaderNote note,
  required ReaderThemeColors colors,
  required ValueChanged<ReaderNote> onUpdateAppearance,
}) {
  return showAppSheet<QuickNoteAction>(
    context: context,
    colors: colors,
    builder: (_) => _ReaderNoteQuickSheet(
      initialNote: note,
      colors: colors,
      onUpdateAppearance: onUpdateAppearance,
    ),
  );
}

class _ReaderNoteQuickSheet extends StatefulWidget {
  const _ReaderNoteQuickSheet({
    required this.initialNote,
    required this.colors,
    required this.onUpdateAppearance,
  });

  final ReaderNote initialNote;
  final ReaderThemeColors colors;
  final ValueChanged<ReaderNote> onUpdateAppearance;

  @override
  State<_ReaderNoteQuickSheet> createState() => _ReaderNoteQuickSheetState();
}

class _ReaderNoteQuickSheetState extends State<_ReaderNoteQuickSheet> {
  late ReaderNote _note;

  @override
  void initState() {
    super.initState();
    _note = widget.initialNote;
  }

  void _update({NoteColor? color, NoteStyle? style}) {
    final next = _note.copyWith(
      color: color ?? _note.color,
      style: style ?? _note.style,
      updatedAt: DateTime.now(),
    );
    setState(() => _note = next);
    widget.onUpdateAppearance(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isDark = colors.background.computeLuminance() < 0.35;
    final accentColor = _note.color.swatchColor(isDark);
    final danger = AppOverlayTheme.danger(colors);

    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _note.category.icon,
                          size: 13,
                          color: accentColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _note.category.label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: accentColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _note.chapterTitle.isNotEmpty
                          ? _note.chapterTitle
                          : '第 ${_note.chapterIndex + 1} 章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.secondary, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        Navigator.of(context).pop(QuickNoteAction.delete),
                    tooltip: '删除划线与笔记',
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: danger,
                      size: 20,
                    ),
                  ),
                ],
              ),
              if (_note.hasQuote) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: BoxDecoration(
                    color: _note.color.cardTint(isDark),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border(
                      left: BorderSide(color: accentColor, width: 3.5),
                    ),
                  ),
                  child: Text(
                    _note.quote,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 13.5,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
              if (_note.hasContent) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.background.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: colors.border),
                  ),
                  child: Text(
                    _note.content,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 13.5,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
              if (_note.tags.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.xs,
                  children: [
                    for (final tag in _note.tags)
                      Text(
                        '#$tag',
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  for (final color in NoteColor.values) ...[
                    GestureDetector(
                      onTap: () => _update(color: color),
                      child: AnimatedContainer(
                        duration: AppMotion.quick,
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color.swatchColor(isDark),
                          border: _note.color == color
                              ? Border.all(color: Colors.white, width: 2)
                              : null,
                          boxShadow: _note.color == color
                              ? [
                                  BoxShadow(
                                    color: color
                                        .swatchColor(isDark)
                                        .withValues(alpha: 0.45),
                                    blurRadius: 5,
                                  ),
                                ]
                              : null,
                        ),
                        child: _note.color == color
                            ? const Icon(
                                Icons.check_rounded,
                                size: 13,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  const Spacer(),
                  for (final style in NoteStyle.values)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: style.label,
                      onPressed: () => _update(style: style),
                      icon: Icon(
                        style.icon,
                        size: 19,
                        color: _note.style == style
                            ? accentColor
                            : colors.secondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final text = _note.hasContent
                            ? '${_note.quote}\n\n批注：${_note.content}'.trim()
                            : _note.quote;
                        await Clipboard.setData(ClipboardData(text: text));
                        if (!context.mounted) return;
                        AppToast.success(context, '已复制原文内容', colors: colors);
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('复制'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          Navigator.of(context).pop(QuickNoteAction.quoteCard),
                      icon: const Icon(Icons.style_outlined, size: 16),
                      label: const Text('金句卡'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          Navigator.of(context).pop(QuickNoteAction.edit),
                      icon: const Icon(Icons.edit_note_rounded, size: 18),
                      label: Text(_note.hasContent ? '编辑' : '写笔记'),
                      style: AppButtonStyles.filledOverride(
                        colors,
                        backgroundColor: accentColor,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
