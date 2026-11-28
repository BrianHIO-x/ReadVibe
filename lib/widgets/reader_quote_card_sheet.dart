import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../models/reader_note.dart';
import '../services/book_export_service.dart';
import '../theme/app_button_styles.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_choice_pill.dart';
import 'app_sheet.dart';
import 'app_toast.dart';

enum QuoteCardTemplate {
  xuanPaper('宣纸书笺'),
  inkNight('墨韵深夜'),
  minimalWhite('素雅留白'),
  tintedGradient('典藏色卡');

  const QuoteCardTemplate(this.label);
  final String label;
}

/// Interactive quote-card studio that turns any excerpt/note into a visual
/// shareable PNG image saved through Android SAF.
Future<void> showReaderQuoteCardSheet({
  required BuildContext context,
  required ReaderThemeColors colors,
  required String bookTitle,
  String author = '',
  required ReaderNote note,
  Future<T> Function<T>(Future<T> Function() action)? runWithSystemDialog,
}) {
  return showAppSheet<void>(
    context: context,
    colors: colors,
    isScrollControlled: true,
    builder: (_) => _ReaderQuoteCardSheet(
      colors: colors,
      bookTitle: bookTitle,
      author: author,
      note: note,
      runWithSystemDialog: runWithSystemDialog,
    ),
  );
}

class _ReaderQuoteCardSheet extends StatefulWidget {
  const _ReaderQuoteCardSheet({
    required this.colors,
    required this.bookTitle,
    required this.author,
    required this.note,
    this.runWithSystemDialog,
  });

  final ReaderThemeColors colors;
  final String bookTitle;
  final String author;
  final ReaderNote note;
  final Future<T> Function<T>(Future<T> Function() action)? runWithSystemDialog;

  @override
  State<_ReaderQuoteCardSheet> createState() => _ReaderQuoteCardSheetState();
}

class _ReaderQuoteCardSheetState extends State<_ReaderQuoteCardSheet> {
  final GlobalKey _cardBoundaryKey = GlobalKey();
  final _exporter = BookExportService();

  QuoteCardTemplate _template = QuoteCardTemplate.xuanPaper;
  bool _includeNote = true;
  bool _includeChapter = true;
  bool _saving = false;

  Future<void> _saveImage() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _cardBoundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw const FormatException('无法截取卡片画面');
      }
      final image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? byteData;
      try {
        byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      if (byteData == null) {
        throw const FormatException('图片编码失败');
      }
      final bytes = byteData.buffer.asUint8List();
      final now = DateTime.now();
      final stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}-'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}';
      final fileName = 'ReadVibe-${widget.bookTitle}-金句-$stamp.png';
      final runner = widget.runWithSystemDialog;
      final saved = runner != null
          ? await runner(
              () => _exporter.exportBytes(
                bytes: bytes,
                fileName: fileName,
                mimeType: 'image/png',
              ),
            )
          : await _exporter.exportBytes(
              bytes: bytes,
              fileName: fileName,
              mimeType: 'image/png',
            );
      if (!mounted) return;
      if (saved) {
        AppToast.success(context, '金句卡片已保存', colors: widget.colors);
      } else {
        AppToast.show(context, '已取消保存', colors: widget.colors);
      }
    } on Object catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error is FormatException ? error.message : '保存卡片失败，请稍后重试',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyText() async {
    final buffer = StringBuffer();
    if (widget.note.hasQuote) {
      buffer.writeln('「${widget.note.quote}」');
    }
    if (_includeNote && widget.note.hasContent) {
      buffer.writeln('\n${widget.note.content}');
    }
    buffer.write('\n——《${widget.bookTitle}》');
    if (widget.author.trim().isNotEmpty) {
      buffer.write(' · ${widget.author.trim()}');
    }
    if (_includeChapter && widget.note.chapterTitle.isNotEmpty) {
      buffer.write('（${widget.note.chapterTitle}）');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    AppToast.success(context, '金句文字已复制', colors: widget.colors);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      child: AppSheetSurface(
        colors: colors,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppSheetHeader(
                title: '生成金句卡片',
                subtitle: '选择版式后导出高清长图或复制文本',
              ),
              Divider(height: 1, color: colors.border),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    AppSpacing.md,
                    AppSpacing.xl,
                    AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: RepaintBoundary(
                            key: _cardBoundaryKey,
                            child: AnimatedSwitcher(
                              duration: AppMotion.tabSwitch,
                              switchInCurve: AppMotion.controlCurve,
                              switchOutCurve: Curves.easeInCubic,
                              child: KeyedSubtree(
                                key: ValueKey<String>(
                                  '${_template.name}_${_includeNote}_$_includeChapter',
                                ),
                                child: _QuoteCardCanvas(
                                  template: _template,
                                  bookTitle: widget.bookTitle,
                                  author: widget.author,
                                  note: widget.note,
                                  includeNote:
                                      _includeNote && widget.note.hasContent,
                                  includeChapter: _includeChapter,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (final tmpl in QuoteCardTemplate.values)
                            AppChoicePill(
                              label: tmpl.label,
                              selected: _template == tmpl,
                              colors: colors,
                              onTap: () => setState(() => _template = tmpl),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.sm,
                        children: [
                          if (widget.note.hasContent)
                            AppChoicePill(
                              label: '包含想法批注',
                              selected: _includeNote,
                              showCheckmark: true,
                              compact: true,
                              colors: colors,
                              onTap: () =>
                                  setState(() => _includeNote = !_includeNote),
                            ),
                          AppChoicePill(
                            label: widget.note.isPdf ? '显示页码' : '显示章节',
                            selected: _includeChapter,
                            showCheckmark: true,
                            compact: true,
                            colors: colors,
                            onTap: () => setState(
                              () => _includeChapter = !_includeChapter,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: OutlinedButton.icon(
                              onPressed: _saving ? null : _copyText,
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: const Text(
                                '复制文本',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              style: AppButtonStyles.outlinedOverride(
                                colors,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            flex: 4,
                            child: FilledButton.icon(
                              onPressed: _saving ? null : _saveImage,
                              icon: _saving
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: colors.accent.computeLuminance() >
                                                0.35
                                            ? colors.background
                                            : Colors.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.download_rounded,
                                      size: 18,
                                    ),
                              label: Text(
                                _saving ? '正在生成…' : '保存图片 (.png)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
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
}

class _QuoteCardCanvas extends StatelessWidget {
  const _QuoteCardCanvas({
    required this.template,
    required this.bookTitle,
    required this.author,
    required this.note,
    required this.includeNote,
    required this.includeChapter,
  });

  final QuoteCardTemplate template;
  final String bookTitle;
  final String author;
  final ReaderNote note;
  final bool includeNote;
  final bool includeChapter;

  @override
  Widget build(BuildContext context) {
    final palette = _cardPalette();
    final mainQuote = note.hasQuote ? note.quote : note.content;
    final showSeparateNote = includeNote && note.hasQuote && note.hasContent;

    return AnimatedContainer(
      duration: AppMotion.normal,
      decoration: BoxDecoration(
        color: palette.bg,
        gradient: palette.gradient,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: palette.border, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(22),
      child: Container(
        padding: template == QuoteCardTemplate.xuanPaper
            ? const EdgeInsets.all(14)
            : EdgeInsets.zero,
        decoration: template == QuoteCardTemplate.xuanPaper
            ? BoxDecoration(
                border: Border.all(color: palette.border, width: 0.7),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '“',
                  style: TextStyle(
                    fontSize: 38,
                    height: 0.7,
                    fontWeight: FontWeight.w700,
                    color: palette.accent,
                    fontFamily: 'SourceHanSerifSC',
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    note.category.label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: palette.accent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: template == QuoteCardTemplate.minimalWhite
                  ? const EdgeInsets.only(left: 12)
                  : EdgeInsets.zero,
              decoration: template == QuoteCardTemplate.minimalWhite
                  ? BoxDecoration(
                      border: Border(
                        left: BorderSide(color: palette.accent, width: 3),
                      ),
                    )
                  : null,
              child: Text(
                mainQuote,
                style: TextStyle(
                  fontFamily: 'SourceHanSerifSC',
                  color: palette.text,
                  fontSize: 16,
                  height: 1.75,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            if (showSeparateNote) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.noteBg,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  note.content,
                  style: TextStyle(
                    color: palette.text.withValues(alpha: 0.9),
                    fontSize: 13.5,
                    height: 1.6,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Divider(height: 1, color: palette.border),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '《$bookTitle》',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (author.trim().isNotEmpty ||
                          (includeChapter && note.chapterTitle.isNotEmpty)) ...[
                        const SizedBox(height: 3),
                        Text(
                          [
                            if (author.trim().isNotEmpty) author.trim(),
                            if (includeChapter && note.chapterTitle.isNotEmpty)
                              note.chapterTitle,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.secondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'ReadVibe',
                  style: TextStyle(
                    color: palette.accent.withValues(alpha: 0.78),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  ({
    Color bg,
    Gradient? gradient,
    Color text,
    Color secondary,
    Color accent,
    Color border,
    Color noteBg,
  })
  _cardPalette() {
    switch (template) {
      case QuoteCardTemplate.xuanPaper:
        return (
          bg: const Color(0xFFFAF6EE),
          gradient: null,
          text: const Color(0xFF3A2E25),
          secondary: const Color(0xFF7D7064),
          accent: const Color(0xFFB3543A),
          border: const Color(0xFFE5DAC8),
          noteBg: const Color(0xFFF1E9DC),
        );
      case QuoteCardTemplate.inkNight:
        return (
          bg: const Color(0xFF1A1816),
          gradient: null,
          text: const Color(0xFFEBE3D8),
          secondary: const Color(0xFF9C9187),
          accent: const Color(0xFFE3A869),
          border: const Color(0xFF36302B),
          noteBg: const Color(0xFF25221F),
        );
      case QuoteCardTemplate.minimalWhite:
        return (
          bg: const Color(0xFFFFFFFF),
          gradient: null,
          text: const Color(0xFF24211E),
          secondary: const Color(0xFF7B736C),
          accent: const Color(0xFFB3543A),
          border: const Color(0xFFEAE5DE),
          noteBg: const Color(0xFFF6F3EF),
        );
      case QuoteCardTemplate.tintedGradient:
        final tint = note.color.swatchColor(false);
        return (
          bg: const Color(0xFFFDFBF8),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(Colors.white, tint, 0.14)!,
              Color.lerp(const Color(0xFFFAF6EE), tint, 0.06)!,
            ],
          ),
          text: const Color(0xFF2F261F),
          secondary: const Color(0xFF72655A),
          accent: tint,
          border: tint.withValues(alpha: 0.3),
          noteBg: Colors.white.withValues(alpha: 0.72),
        );
    }
  }
}
