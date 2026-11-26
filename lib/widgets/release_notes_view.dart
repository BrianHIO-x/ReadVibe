import 'package:flutter/material.dart';

import '../models/release_notes_markdown.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// Renders parsed GitHub release notes cleanly inside themed dialogs and sheets.
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView({
    super.key,
    required this.blocks,
    required this.colors,
  });

  ReleaseNotesView.markdown({
    super.key,
    required String notes,
    required this.colors,
  }) : blocks = parseReleaseNotesMarkdown(notes);

  final List<ReleaseNotesBlock> blocks;
  final ReaderThemeColors colors;

  @override
  Widget build(BuildContext context) {
    if (blocks.isEmpty) return const SizedBox.shrink();
    final dark = AppOverlayTheme.isDark(colors);
    final palette = _ReleaseNotesPalette.fromColors(colors, dark: dark);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildBlockList(blocks, palette, compact: false),
    );
  }

  List<Widget> _buildBlockList(
    List<ReleaseNotesBlock> items,
    _ReleaseNotesPalette palette, {
    required bool compact,
  }) {
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final block = items[i];
      if (i > 0) {
        children.add(
          SizedBox(height: _gapBefore(items[i - 1], block, compact: compact)),
        );
      }
      children.add(_buildBlock(block, palette, compact: compact));
    }
    return children;
  }

  double _gapBefore(
    ReleaseNotesBlock prev,
    ReleaseNotesBlock current, {
    required bool compact,
  }) {
    if (current is ReleaseNotesHeadingBlock) {
      if (current.level <= 3) return compact ? AppSpacing.sm : AppSpacing.md;
      return AppSpacing.sm;
    }
    if (prev is ReleaseNotesHeadingBlock) return AppSpacing.xs;
    if (prev is ReleaseNotesListItemBlock &&
        current is ReleaseNotesListItemBlock) {
      return 5.0;
    }
    if (current is ReleaseNotesChecksumBlock) return AppSpacing.md;
    return compact ? 6.0 : AppSpacing.sm;
  }

  Widget _buildBlock(
    ReleaseNotesBlock block,
    _ReleaseNotesPalette palette, {
    required bool compact,
  }) {
    return switch (block) {
      ReleaseNotesHeadingBlock() => _buildHeading(block, palette),
      ReleaseNotesParagraphBlock() => _buildInlineText(
        block.runs,
        palette,
        compact ? palette.compactBodyStyle : palette.bodyStyle,
      ),
      ReleaseNotesListItemBlock() => _buildListItem(
        block,
        palette,
        compact: compact,
      ),
      ReleaseNotesQuoteBlock() => _buildQuote(block, palette),
      ReleaseNotesCodeBlock() => _buildCodeBlock(block, palette),
      ReleaseNotesTableBlock() => _buildTable(block, palette),
      ReleaseNotesDividerBlock() => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Divider(color: palette.colors.border, height: 1, thickness: 1),
      ),
      ReleaseNotesChecksumBlock() => _buildChecksum(block, palette),
    };
  }

  Widget _buildHeading(
    ReleaseNotesHeadingBlock block,
    _ReleaseNotesPalette palette,
  ) {
    final style = switch (block.level) {
      1 => TextStyle(
        fontSize: 15.5,
        height: 1.35,
        fontWeight: FontWeight.w700,
        color: palette.colors.text,
      ),
      2 => TextStyle(
        fontSize: 14.5,
        height: 1.35,
        fontWeight: FontWeight.w700,
        color: palette.colors.text,
      ),
      3 => TextStyle(
        fontSize: 13.5,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: palette.colors.text,
      ),
      _ => TextStyle(
        fontSize: 13.0,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: palette.colors.secondary,
      ),
    };
    final text = _buildInlineText(block.runs, palette, style);
    if (block.level == 3) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3.0),
            child: Container(
              width: 3,
              height: 13,
              decoration: BoxDecoration(
                color: palette.colors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(child: text),
        ],
      );
    }
    return text;
  }

  Widget _buildListItem(
    ReleaseNotesListItemBlock block,
    _ReleaseNotesPalette palette, {
    required bool compact,
  }) {
    final baseStyle = compact ? palette.compactBodyStyle : palette.bodyStyle;
    final Widget leading;
    if (block.checked != null) {
      final checked = block.checked!;
      leading = SizedBox(
        width: 18,
        child: Padding(
          padding: const EdgeInsets.only(top: 3.0),
          child: Icon(
            checked
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            size: 15,
            color: checked ? palette.colors.accent : palette.colors.secondary,
          ),
        ),
      );
    } else if (block.ordered) {
      leading = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 20),
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            block.marker ?? '1.',
            style: baseStyle.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: palette.colors.accent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
    } else {
      leading = SizedBox(
        width: 16,
        child: Padding(
          padding: const EdgeInsets.only(top: 7.5, left: 3),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              width: 4.5,
              height: 4.5,
              decoration: BoxDecoration(
                color: block.indent == 0
                    ? palette.colors.accent
                    : palette.colors.secondary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: block.indent * 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          Expanded(child: _buildInlineText(block.runs, palette, baseStyle)),
        ],
      ),
    );
  }

  Widget _buildQuote(
    ReleaseNotesQuoteBlock block,
    _ReleaseNotesPalette palette,
  ) {
    final content = <Widget>[
      if (block.alertLabel != null) ...[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 14,
              color: palette.colors.accent,
            ),
            const SizedBox(width: 4),
            Text(
              block.alertLabel!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.colors.accent,
              ),
            ),
          ],
        ),
        if (block.children.isNotEmpty) const SizedBox(height: 4),
      ],
      ..._buildBlockList(block.children, palette, compact: true),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: palette.quoteBg,
          border: Border(
            left: BorderSide(color: palette.colors.accent, width: 3),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: content,
        ),
      ),
    );
  }

  Widget _buildCodeBlock(
    ReleaseNotesCodeBlock block,
    _ReleaseNotesPalette palette,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.panelBg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: palette.colors.border),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (block.language != null && block.language!.isNotEmpty) ...[
            Text(
              block.language!,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: palette.colors.secondary,
              ),
            ),
            const SizedBox(height: 4),
          ],
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              block.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
                color: palette.colors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTable(
    ReleaseNotesTableBlock block,
    _ReleaseNotesPalette palette,
  ) {
    final headerStyle = palette.compactBodyStyle.copyWith(
      fontWeight: FontWeight.w600,
      color: palette.colors.text,
    );
    final cellBorder = BorderSide(
      color: palette.colors.border.withValues(alpha: 0.75),
    );

    Widget buildCell(
      List<ReleaseNotesInlineRun> runs,
      TextStyle style, {
      Color? bg,
    }) {
      return Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: _buildInlineText(runs, palette, style),
        ),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.colors.headerBg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: palette.colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: cellBorder,
            verticalInside: cellBorder,
          ),
          children: [
            TableRow(
              children: [
                for (final cell in block.headers)
                  buildCell(cell, headerStyle, bg: palette.panelBg),
              ],
            ),
            for (final row in block.rows)
              TableRow(
                children: [
                  for (final cell in row)
                    buildCell(cell, palette.compactBodyStyle),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChecksum(
    ReleaseNotesChecksumBlock block,
    _ReleaseNotesPalette palette,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.panelBg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: palette.colors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${block.label} 校验',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: palette.colors.secondary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            block.value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.35,
              color: palette.colors.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineText(
    List<ReleaseNotesInlineRun> runs,
    _ReleaseNotesPalette palette,
    TextStyle baseStyle,
  ) {
    if (runs.isEmpty) return const SizedBox.shrink();
    final spans = <InlineSpan>[
      for (final run in runs) _toTextSpan(run, palette, baseStyle),
    ];
    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      softWrap: true,
    );
  }

  TextSpan _toTextSpan(
    ReleaseNotesInlineRun run,
    _ReleaseNotesPalette palette,
    TextStyle baseStyle,
  ) {
    final decorations = <TextDecoration>[
      if (run.isLink) TextDecoration.underline,
      if (run.strikethrough) TextDecoration.lineThrough,
    ];
    final Color? textColor;
    if (run.isLink) {
      textColor = palette.colors.accent;
    } else if (run.code) {
      textColor = palette.colors.text;
    } else if (run.bold) {
      textColor = palette.colors.text;
    } else {
      textColor = null;
    }

    final fontSize = run.code
        ? ((baseStyle.fontSize ?? 13.5) - 1.3).clamp(11.0, 15.0)
        : null;

    return TextSpan(
      text: run.code ? '\u2009${run.text}\u2009' : run.text,
      style: TextStyle(
        color: textColor,
        fontWeight: run.bold ? FontWeight.w600 : null,
        fontStyle: run.italic ? FontStyle.italic : null,
        fontFamily: run.code ? 'monospace' : null,
        fontSize: fontSize,
        backgroundColor: run.code ? palette.codeBg : null,
        decoration: decorations.isEmpty
            ? null
            : TextDecoration.combine(decorations),
        decorationColor: run.isLink
            ? palette.colors.accent.withValues(alpha: 0.75)
            : palette.colors.secondary,
      ),
    );
  }
}

class _ReleaseNotesPalette {
  const _ReleaseNotesPalette({
    required this.colors,
    required this.codeBg,
    required this.panelBg,
    required this.quoteBg,
    required this.bodyStyle,
    required this.compactBodyStyle,
  });

  factory _ReleaseNotesPalette.fromColors(
    ReaderThemeColors colors, {
    required bool dark,
  }) {
    final bodyColor = colors.text.withValues(alpha: dark ? 0.88 : 0.86);
    return _ReleaseNotesPalette(
      colors: colors,
      codeBg: Color.alphaBlend(
        colors.text.withValues(alpha: dark ? 0.14 : 0.06),
        colors.headerBg,
      ),
      panelBg: Color.alphaBlend(
        colors.text.withValues(alpha: dark ? 0.06 : 0.03),
        colors.headerBg,
      ),
      quoteBg: Color.alphaBlend(
        colors.accent.withValues(alpha: dark ? 0.12 : 0.06),
        colors.headerBg,
      ),
      bodyStyle: TextStyle(
        fontSize: 13.5,
        height: 1.55,
        color: bodyColor,
      ),
      compactBodyStyle: TextStyle(
        fontSize: 13.0,
        height: 1.5,
        color: bodyColor,
      ),
    );
  }

  final ReaderThemeColors colors;
  final Color codeBg;
  final Color panelBg;
  final Color quoteBg;
  final TextStyle bodyStyle;
  final TextStyle compactBodyStyle;
}
