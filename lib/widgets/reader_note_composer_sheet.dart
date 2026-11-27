import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/reader_note.dart';
import '../theme/app_button_styles.dart';
import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_choice_pill.dart';
import 'app_sheet.dart';
import 'pressable_scale.dart';

class ReaderNoteDraft {
  const ReaderNoteDraft({
    required this.quote,
    required this.content,
    required this.color,
    required this.style,
    required this.category,
    required this.tags,
    this.deleted = false,
  });

  final String quote;
  final String content;
  final NoteColor color;
  final NoteStyle style;
  final NoteCategory category;
  final List<String> tags;
  final bool deleted;
}

const _quickTagSuggestions = <String>['关键', '好句', '想法', '伏笔', '人物', '待查'];

/// Rich keyboard-aware composer sheet replacing the old plain text note dialog.
Future<ReaderNoteDraft?> showReaderNoteComposerSheet({
  required BuildContext context,
  required ReaderThemeColors colors,
  required String title,
  required String locationLabel,
  String initialQuote = '',
  String initialContent = '',
  NoteColor initialColor = NoteColor.amber,
  NoteStyle initialStyle = NoteStyle.highlight,
  NoteCategory initialCategory = NoteCategory.thought,
  List<String> initialTags = const <String>[],
  bool allowStyleSelection = true,
  bool allowEditQuote = false,
  bool allowDelete = false,
}) {
  return showAppSheet<ReaderNoteDraft>(
    context: context,
    colors: colors,
    isScrollControlled: true,
    builder: (_) => _ReaderNoteComposerSheet(
      colors: colors,
      title: title,
      locationLabel: locationLabel,
      initialQuote: initialQuote,
      initialContent: initialContent,
      initialColor: initialColor,
      initialStyle: initialStyle,
      initialCategory: initialCategory,
      initialTags: initialTags,
      allowStyleSelection: allowStyleSelection,
      allowEditQuote: allowEditQuote,
      allowDelete: allowDelete,
    ),
  );
}

class _ReaderNoteComposerSheet extends StatefulWidget {
  const _ReaderNoteComposerSheet({
    required this.colors,
    required this.title,
    required this.locationLabel,
    required this.initialQuote,
    required this.initialContent,
    required this.initialColor,
    required this.initialStyle,
    required this.initialCategory,
    required this.initialTags,
    required this.allowStyleSelection,
    required this.allowEditQuote,
    required this.allowDelete,
  });

  final ReaderThemeColors colors;
  final String title;
  final String locationLabel;
  final String initialQuote;
  final String initialContent;
  final NoteColor initialColor;
  final NoteStyle initialStyle;
  final NoteCategory initialCategory;
  final List<String> initialTags;
  final bool allowStyleSelection;
  final bool allowEditQuote;
  final bool allowDelete;

  @override
  State<_ReaderNoteComposerSheet> createState() =>
      _ReaderNoteComposerSheetState();
}

class _ReaderNoteComposerSheetState extends State<_ReaderNoteComposerSheet> {
  late final TextEditingController _quoteController;
  late final TextEditingController _contentController;
  late final TextEditingController _tagInputController;
  late NoteColor _color;
  late NoteStyle _style;
  late NoteCategory _category;
  late List<String> _tags;
  bool _showQuoteEditor = false;
  bool _addingTag = false;

  @override
  void initState() {
    super.initState();
    _quoteController = TextEditingController(text: widget.initialQuote);
    _contentController = TextEditingController(text: widget.initialContent);
    _tagInputController = TextEditingController();
    _color = widget.initialColor;
    _style = widget.initialStyle;
    _category = widget.initialCategory;
    _tags = List<String>.of(widget.initialTags);
    _showQuoteEditor =
        widget.allowEditQuote && widget.initialQuote.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _quoteController.dispose();
    _contentController.dispose();
    _tagInputController.dispose();
    super.dispose();
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_tags.contains(tag)) {
        _tags.remove(tag);
      } else if (_tags.length < maxReaderNoteTags) {
        _tags = normalizeNoteTags(<String>[..._tags, tag]).toList();
      }
    });
  }

  void _commitCustomTag() {
    final raw = _tagInputController.text.trim();
    _tagInputController.clear();
    if (raw.isNotEmpty && _tags.length < maxReaderNoteTags) {
      setState(() {
        _tags = normalizeNoteTags(<String>[..._tags, raw]).toList();
        _addingTag = false;
      });
    } else {
      setState(() => _addingTag = false);
    }
  }

  void _submit() {
    final quote = _quoteController.text.trim();
    final content = _contentController.text.trim();
    if (quote.isEmpty && content.isEmpty) {
      return;
    }
    Navigator.of(context).pop(
      ReaderNoteDraft(
        quote: quote,
        content: content,
        color: _color,
        style: _style,
        category: content.isEmpty && _category == NoteCategory.thought
            ? NoteCategory.highlight
            : _category,
        tags: List<String>.unmodifiable(_tags),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isDark = colors.background.computeLuminance() < 0.35;
    final accentColor = _color.swatchColor(isDark);
    final danger = AppOverlayTheme.danger(colors);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final hasAnyBody =
        _quoteController.text.trim().isNotEmpty ||
        _contentController.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: AppSheetSurface(
          colors: colors,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSheetHeader(
                title: widget.title,
                subtitle: widget.locationLabel,
                trailing: widget.allowDelete
                    ? TextButton.icon(
                        onPressed: () => Navigator.of(context).pop(
                          ReaderNoteDraft(
                            quote: '',
                            content: '',
                            color: _color,
                            style: _style,
                            category: _category,
                            tags: _tags,
                            deleted: true,
                          ),
                        ),
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: danger,
                        ),
                        label: Text('删除', style: TextStyle(color: danger)),
                      )
                    : null,
              ),
              Divider(height: 1, color: colors.border),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    AppSpacing.md,
                    AppSpacing.xl,
                    AppSpacing.md + (bottomInset > 0 ? 0 : bottomPadding),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_quoteController.text.trim().isNotEmpty &&
                          !_showQuoteEditor)
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          decoration: BoxDecoration(
                            color: _color.cardTint(isDark),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            border: Border(
                              left: BorderSide(color: accentColor, width: 3.5),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  _quoteController.text.trim(),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.text,
                                    fontSize: 13.5,
                                    height: 1.55,
                                  ),
                                ),
                              ),
                              if (widget.allowEditQuote)
                                IconButton(
                                  onPressed: () =>
                                      setState(() => _showQuoteEditor = true),
                                  tooltip: '编辑摘录',
                                  icon: Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: colors.secondary,
                                  ),
                                ),
                            ],
                          ),
                        )
                      else if (widget.allowEditQuote) ...[
                        if (_showQuoteEditor)
                          TextField(
                            controller: _quoteController,
                            maxLines: 3,
                            minLines: 2,
                            maxLength: maxReaderNoteQuote,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: '摘录原文（可选）',
                              hintText: '粘贴或摘抄该页关键语句',
                              counterText: '',
                            ),
                          )
                        else
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () =>
                                  setState(() => _showQuoteEditor = true),
                              icon: const Icon(
                                Icons.format_quote_rounded,
                                size: 18,
                              ),
                              label: const Text('补充页内摘录原文（可选）'),
                              style: AppButtonStyles.textOverride(
                                colors,
                                foregroundColor: colors.accent,
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 36),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      _buildColorAndStyleStrip(colors, isDark),
                      const SizedBox(height: AppSpacing.md),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final cat in NoteCategory.values) ...[
                              _CategoryPill(
                                category: cat,
                                selected: _category == cat,
                                accentColor: accentColor,
                                colors: colors,
                                onTap: () => setState(() => _category = cat),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          color: colors.background.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: colors.border),
                        ),
                        child: TextField(
                          controller: _contentController,
                          autofocus:
                              widget.initialContent.isEmpty ||
                              widget.initialQuote.isEmpty,
                          minLines: 4,
                          maxLines: 8,
                          maxLength: maxReaderNoteContent,
                          onChanged: (_) => setState(() {}),
                          textInputAction: TextInputAction.newline,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 15,
                            height: 1.6,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: _quoteController.text.trim().isEmpty
                                ? '写下这一页的阅读批注与思考…'
                                : '写下你的思考（也可留空，仅保存划线高亮）…',
                            hintStyle: TextStyle(
                              color: colors.secondary.withValues(alpha: 0.75),
                              fontSize: 14,
                            ),
                            counterStyle: TextStyle(
                              color: colors.secondary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _buildTagSection(colors, accentColor),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            flex: 2,
                            child: FilledButton.icon(
                              onPressed: hasAnyBody ? _submit : null,
                              style: AppButtonStyles.filledOverride(
                                colors,
                                backgroundColor: accentColor,
                                foregroundColor: Colors.white,
                              ),
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('保存笔记'),
                            ),
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
    );
  }

  Widget _buildColorAndStyleStrip(ReaderThemeColors colors, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '色标',
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              for (final color in NoteColor.values) ...[
                _PaletteDot(
                  color: color.swatchColor(isDark),
                  label: color.label,
                  selected: _color == color,
                  onTap: () => setState(() => _color = color),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
            ],
          ),
          if (widget.allowStyleSelection) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Text(
                  '样式',
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final style in NoteStyle.values)
                        _StyleChoiceChip(
                          style: style,
                          selected: _style == style,
                          accentColor: _color.swatchColor(isDark),
                          highlightFill: _color.highlightFill(isDark),
                          colors: colors,
                          onTap: () => setState(() => _style = style),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTagSection(ReaderThemeColors colors, Color accentColor) {
    final displayTags = <String>{..._tags, ..._quickTagSuggestions};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tag in displayTags)
              AppChoicePill(
                label: '#$tag',
                selected: _tags.contains(tag),
                compact: true,
                accentColor: accentColor,
                colors: colors,
                onTap: () => _toggleTag(tag),
              ),
            if (!_addingTag && _tags.length < maxReaderNoteTags)
              AppChoicePill(
                icon: Icons.add_rounded,
                label: '自定义',
                selected: false,
                compact: true,
                accentColor: accentColor,
                colors: colors,
                onTap: () => setState(() => _addingTag = true),
              ),
          ],
        ),
        if (_addingTag) ...[
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tagInputController,
                  autofocus: true,
                  maxLength: maxReaderNoteTagLength,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _commitCustomTag(),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '输入标签名，例如：结构、隐喻',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              TextButton(onPressed: _commitCustomTag, child: const Text('添加')),
            ],
          ),
        ],
      ],
    );
  }
}

class _PaletteDot extends StatelessWidget {
  const _PaletteDot({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$label色标',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.quick,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: selected
                ? Border.all(color: Colors.white, width: 2.2)
                : null,
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.45),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: selected
              ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

class _StyleChoiceChip extends StatelessWidget {
  const _StyleChoiceChip({
    required this.style,
    required this.selected,
    required this.accentColor,
    required this.highlightFill,
    required this.colors,
    required this.onTap,
  });

  final NoteStyle style;
  final bool selected;
  final Color accentColor;
  final Color highlightFill;
  final ReaderThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      pressedScale: 0.94,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: AnimatedContainer(
            duration: AppMotion.quick,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? accentColor.withValues(alpha: 0.14)
                  : colors.headerBg,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: selected ? accentColor : colors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 26,
                  height: 12,
                  child: CustomPaint(
                    painter: _MiniStylePainter(
                      style: style,
                      accentColor: accentColor,
                      highlightFill: highlightFill,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  style.label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? accentColor : colors.secondary,
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

class _MiniStylePainter extends CustomPainter {
  const _MiniStylePainter({
    required this.style,
    required this.accentColor,
    required this.highlightFill,
  });

  final NoteStyle style;
  final Color accentColor;
  final Color highlightFill;

  @override
  void paint(Canvas canvas, Size size) {
    if (style == NoteStyle.highlight) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 1, size.width, size.height - 2),
          const Radius.circular(3),
        ),
        Paint()..color = highlightFill,
      );
      return;
    }
    final paint = Paint()
      ..color = accentColor
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final y = size.height - 3;
    switch (style) {
      case NoteStyle.highlight:
        break;
      case NoteStyle.underline:
        canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), paint);
      case NoteStyle.dashed:
        for (double x = 1; x < size.width - 2; x += 6) {
          canvas.drawLine(
            Offset(x, y),
            Offset(math.min(x + 3.2, size.width - 1), y),
            paint,
          );
        }
      case NoteStyle.wavy:
        final path = Path()..moveTo(1, y);
        const step = 4.0;
        var up = true;
        for (double x = 1; x < size.width - step; x += step) {
          path.quadraticBezierTo(
            x + step / 2,
            y + (up ? -2.2 : 2.2),
            x + step,
            y,
          );
          up = !up;
        }
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniStylePainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.highlightFill != highlightFill;
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.category,
    required this.selected,
    required this.accentColor,
    required this.colors,
    required this.onTap,
  });

  final NoteCategory category;
  final bool selected;
  final Color accentColor;
  final ReaderThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      pressedScale: 0.95,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: AnimatedContainer(
            duration: AppMotion.quick,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? accentColor.withValues(alpha: 0.14)
                  : colors.background.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: selected ? accentColor : colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  category.icon,
                  size: 14,
                  color: selected ? accentColor : colors.secondary,
                ),
                const SizedBox(width: 4),
                Text(
                  category.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? accentColor : colors.secondary,
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
