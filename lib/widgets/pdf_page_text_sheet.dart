import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';

import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_sheet.dart';
import 'app_toast.dart';

/// Where a page's text came from. A born-digital PDF carries its own layer;
/// a scan only yields text after recognition.
enum PdfPageTextSource { textLayer, ocr }

extension PdfPageTextSourceInfo on PdfPageTextSource {
  String get label => switch (this) {
    PdfPageTextSource.textLayer => '来自 PDF 自带文字层',
    PdfPageTextSource.ocr => '来自本机文字识别，可能存在误差',
  };
}

/// Selectable view of one PDF page's text.
///
/// PDF pages render as bitmaps, so the page itself cannot carry a selection.
/// This sheet puts the same words into a normal text selection, bringing back
/// copy, share, system text actions, and one-tap note creation.
class PdfPageTextSheet extends StatefulWidget {
  const PdfPageTextSheet({
    super.key,
    required this.pageNumber,
    required this.text,
    required this.source,
    required this.colors,
    required this.scrollController,
    this.onAddNote,
  });

  final int pageNumber;
  final String text;
  final PdfPageTextSource source;
  final ReaderThemeColors colors;
  final ScrollController scrollController;
  final Future<void> Function(String selectedQuote)? onAddNote;

  @override
  State<PdfPageTextSheet> createState() => _PdfPageTextSheetState();
}

class _PdfPageTextSheetState extends State<PdfPageTextSheet> {
  final _selectionKey = GlobalKey<SelectionAreaState>();
  SelectedContent? _selected;

  Future<void> _addSelectedAsNote() async {
    final quote = _selected?.plainText.trim() ?? '';
    final handler = widget.onAddNote;
    ContextMenuController.removeAny();
    _selectionKey.currentState?.selectableRegion.clearSelection();
    if (handler == null || quote.isEmpty) return;
    Navigator.of(context).pop();
    await handler(quote);
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.text.trim();
    final colors = widget.colors;
    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            AppSheetHeader(
              title: '第 ${widget.pageNumber} 页文字',
              subtitle: body.isEmpty ? '这一页没有可提取的文字' : widget.source.label,
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: body.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.xl),
                        child: Text(
                          '这一页是纯图像，或者识别没有得到结果。\n'
                          '可以在工具菜单里对当前页再做一次文字识别。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.secondary,
                            height: 1.6,
                          ),
                        ),
                      ),
                    )
                  : SelectionArea(
                      key: _selectionKey,
                      onSelectionChanged: (content) => _selected = content,
                      contextMenuBuilder: (context, selectableRegionState) {
                        final defaults =
                            selectableRegionState.contextMenuButtonItems;
                        final quote = _selected?.plainText.trim() ?? '';
                        final items = <ContextMenuButtonItem>[
                          for (final item in defaults)
                            switch (item.type) {
                              ContextMenuButtonType.copy => item.copyWith(
                                label: '复制',
                              ),
                              ContextMenuButtonType.share => item.copyWith(
                                label: '分享',
                              ),
                              ContextMenuButtonType.selectAll => item.copyWith(
                                label: '全选',
                              ),
                              _ => item,
                            },
                          if (widget.onAddNote != null && quote.isNotEmpty)
                            ContextMenuButtonItem(
                              label: '写笔记',
                              onPressed: () => unawaited(_addSelectedAsNote()),
                            ),
                        ];
                        return AdaptiveTextSelectionToolbar.buttonItems(
                          anchors: selectableRegionState.contextMenuAnchors,
                          buttonItems: items,
                        );
                      },
                      child: ListView(
                        controller: widget.scrollController,
                        padding: EdgeInsets.fromLTRB(
                          20,
                          AppSpacing.md,
                          20,
                          AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                        ),
                        children: [
                          Text(
                            body,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 15,
                              height: 1.75,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            if (body.isNotEmpty) ...[
              Divider(height: 1, color: colors.border),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  AppSpacing.sm,
                  20,
                  AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.onAddNote != null
                            ? '长按选句可直接写笔记'
                            : '长按可以选择部分文字',
                        style: TextStyle(
                          color: colors.secondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: body));
                        if (!context.mounted) return;
                        AppToast.success(context, '本页文字已复制', colors: colors);
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('全部复制'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
