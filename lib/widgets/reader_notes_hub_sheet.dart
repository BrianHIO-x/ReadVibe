import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/reader_bookmark.dart';
import '../models/reader_note.dart';
import '../services/book_export_service.dart';
import '../services/chinese_text.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_popup_menu.dart';
import 'app_segmented_control.dart';
import 'app_sheet.dart';
import 'app_toast.dart';
import 'pressable_scale.dart';
import 'reader_note_card.dart';
import 'reader_quote_card_sheet.dart';

enum _HubTab { allNotes, writtenNotes, bookmarks }

/// Visual bookmarks and notes hub replacing the legacy bookmark list sheet.
class ReaderNotesHubSheet extends StatefulWidget {
  const ReaderNotesHubSheet({
    super.key,
    required this.bookTitle,
    this.author = '',
    this.isPdf = false,
    required this.notes,
    required this.bookmarks,
    required this.colors,
    required this.scrollController,
    required this.onSelectNote,
    required this.onEditNote,
    required this.onDeleteNote,
    required this.onSelectBookmark,
    required this.onDeleteBookmark,
    this.onPromoteBookmarkToNote,
    this.onAddNoteFromHub,
    this.runWithSystemDialog,
  });

  final String bookTitle;
  final String author;
  final bool isPdf;
  final List<ReaderNote> notes;
  final List<ReaderBookmark> bookmarks;
  final ReaderThemeColors colors;
  final ScrollController scrollController;
  final ValueChanged<ReaderNote> onSelectNote;
  final Future<void> Function(ReaderNote note) onEditNote;
  final ValueChanged<ReaderNote> onDeleteNote;
  final ValueChanged<ReaderBookmark> onSelectBookmark;
  final ValueChanged<ReaderBookmark> onDeleteBookmark;
  final Future<void> Function(ReaderBookmark bookmark)? onPromoteBookmarkToNote;
  final Future<void> Function()? onAddNoteFromHub;
  final Future<T> Function<T>(Future<T> Function() action)? runWithSystemDialog;

  @override
  State<ReaderNotesHubSheet> createState() => _ReaderNotesHubSheetState();
}

class _ReaderNotesHubSheetState extends State<ReaderNotesHubSheet> {
  final _searchController = TextEditingController();
  final _exporter = BookExportService();

  _HubTab _tab = _HubTab.allNotes;
  bool _searchVisible = false;
  bool _sortByTime = false;
  NoteColor? _colorFilter;
  NoteCategory? _categoryFilter;
  String? _tagFilter;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ReaderNote> get _filteredNotes {
    final query = foldFullWidth(_searchController.text).trim().toLowerCase();
    final filtered = widget.notes.where((note) {
      if (_tab == _HubTab.writtenNotes && !note.hasContent) return false;
      if (_colorFilter != null && note.color != _colorFilter) return false;
      if (_categoryFilter != null && note.category != _categoryFilter) {
        return false;
      }
      if (_tagFilter != null && !note.tags.contains(_tagFilter)) return false;
      if (query.isEmpty) return true;
      return foldFullWidth(note.quote).toLowerCase().contains(query) ||
          foldFullWidth(note.content).toLowerCase().contains(query) ||
          foldFullWidth(note.chapterTitle).toLowerCase().contains(query) ||
          note.tags.any((t) => foldFullWidth(t).toLowerCase().contains(query));
    });
    return sortedReaderNotes(filtered, byTime: _sortByTime);
  }

  Set<String> get _allTags => <String>{
    for (final note in widget.notes) ...note.tags,
  };

  Future<void> _exportMarkdown({required bool saveFile}) async {
    if (widget.notes.isEmpty) {
      AppToast.info(context, '还没有可导出的笔记', colors: widget.colors);
      return;
    }
    final markdown = formatNotesAsMarkdown(
      bookTitle: widget.bookTitle,
      author: widget.author,
      notes: widget.notes,
    );
    if (!saveFile) {
      await Clipboard.setData(ClipboardData(text: markdown));
      if (mounted) AppToast.success(context, '全部笔记已复制为 Markdown', colors: widget.colors);
      return;
    }
    try {
      final bytes = utf8.encode(markdown);
      final fileName = '${widget.bookTitle}-读书笔记.md';
      final runner = widget.runWithSystemDialog;
      final saved = runner != null
          ? await runner(
              () => _exporter.exportBytes(
                bytes: bytes,
                fileName: fileName,
                mimeType: 'text/markdown',
              ),
            )
          : await _exporter.exportBytes(
              bytes: bytes,
              fileName: fileName,
              mimeType: 'text/markdown',
            );
      if (!mounted) return;
      if (saved) {
        AppToast.success(context, '笔记已导出为 Markdown 文件', colors: widget.colors);
      } else {
        AppToast.show(context, '已取消导出', colors: widget.colors);
      }
    } on Object {
      if (mounted) {
        AppToast.error(context, '导出失败，请重试', colors: widget.colors);
      }
    }
  }

  Future<void> _copySingleNote(ReaderNote note) async {
    final text = [
      if (note.hasQuote) '「${note.quote}」',
      if (note.hasContent) note.content,
    ].join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) AppToast.success(context, '已复制笔记内容', colors: widget.colors);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final writtenCount = widget.notes.where((n) => n.hasContent).length;
    final highlightCount = widget.notes.length - writtenCount;
    final isDark = colors.background.computeLuminance() < 0.35;

    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            AppSheetHeader(
              title: widget.isPdf ? 'PDF 笔记与书签' : '笔记与书签',
              subtitle:
                  '$writtenCount 条想法 · $highlightCount 处划线 · ${widget.bookmarks.length} 个书签',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onAddNoteFromHub != null)
                    IconButton(
                      tooltip: '记笔记',
                      onPressed: () async {
                        await widget.onAddNoteFromHub!();
                        if (mounted) setState(() {});
                      },
                      icon: Icon(Icons.add_comment_outlined, color: colors.accent),
                    ),
                  if (_tab != _HubTab.bookmarks && widget.notes.isNotEmpty)
                    IconButton(
                      tooltip: '搜索笔记',
                      onPressed: () =>
                          setState(() => _searchVisible = !_searchVisible),
                      icon: Icon(
                        _searchVisible ? Icons.search_off_rounded : Icons.search_rounded,
                        color: colors.secondary,
                      ),
                    ),
                  if (widget.notes.isNotEmpty)
                    AppPopupMenuButton<String>(
                      colors: colors,
                      tooltip: '导出笔记',
                      icon: Icon(Icons.ios_share_rounded, color: colors.secondary),
                      onSelected: (value) {
                        if (value == 'save') {
                          unawaited(_exportMarkdown(saveFile: true));
                        } else if (value == 'copy') {
                          unawaited(_exportMarkdown(saveFile: false));
                        }
                      },
                      entries: const [
                        AppMenuEntry(
                          value: 'save',
                          label: '导出 Markdown (.md)',
                          icon: Icons.description_outlined,
                        ),
                        AppMenuEntry(
                          value: 'copy',
                          label: '复制全部 Markdown',
                          icon: Icons.copy_all_rounded,
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: AppSegmentedControl<_HubTab>(
                options: [
                  AppSegmentOption(
                    value: _HubTab.allNotes,
                    label: '全部 (${widget.notes.length})',
                  ),
                  AppSegmentOption(
                    value: _HubTab.writtenNotes,
                    label: '批注 ($writtenCount)',
                  ),
                  AppSegmentOption(
                    value: _HubTab.bookmarks,
                    label: '书签 (${widget.bookmarks.length})',
                  ),
                ],
                value: _tab,
                colors: colors,
                onChanged: (sel) => setState(() => _tab = sel),
              ),
            ),
            if (_tab != _HubTab.bookmarks && (_searchVisible || _searchController.text.isNotEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: TextField(
                  controller: _searchController,
                  autofocus: _searchVisible,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded, size: 18),
                          )
                        : null,
                    hintText: '搜索摘录原文、批注想法、章节或 #标签',
                  ),
                ),
              ),
            if (_tab != _HubTab.bookmarks && widget.notes.isNotEmpty)
              _buildFilterStrip(colors, isDark),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: _tab == _HubTab.bookmarks
                  ? _buildBookmarksList(colors)
                  : _buildNotesList(colors),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterStrip(ReaderThemeColors colors, bool isDark) {
    final tags = _allTags;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          PressableScale(
            pressedScale: 0.95,
            child: ActionChip(
              avatar: Icon(
                _sortByTime
                    ? Icons.schedule_rounded
                    : Icons.format_list_numbered_rounded,
                size: 15,
                color: colors.accent,
              ),
              label: Text(
                _sortByTime ? '最新修改' : (widget.isPdf ? '页码顺序' : '章节顺序'),
                style: const TextStyle(fontSize: 12),
              ),
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: colors.border),
              onPressed: () => setState(() => _sortByTime = !_sortByTime),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          for (final color in NoteColor.values) ...[
            GestureDetector(
              onTap: () => setState(() {
                _colorFilter = _colorFilter == color ? null : color;
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 20,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.swatchColor(isDark),
                  border: _colorFilter == color
                      ? Border.all(color: colors.text, width: 2)
                      : null,
                ),
              ),
            ),
          ],
          const SizedBox(width: AppSpacing.sm),
          for (final cat in NoteCategory.values) ...[
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: PressableScale(
                pressedScale: 0.95,
                child: FilterChip(
                  label: Text(cat.label, style: const TextStyle(fontSize: 11.5)),
                  selected: _categoryFilter == cat,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() {
                    _categoryFilter = _categoryFilter == cat ? null : cat;
                  }),
                ),
              ),
            ),
          ],
          for (final tag in tags)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: PressableScale(
                pressedScale: 0.95,
                child: FilterChip(
                  label: Text('#$tag', style: const TextStyle(fontSize: 11.5)),
                  selected: _tagFilter == tag,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() {
                    _tagFilter = _tagFilter == tag ? null : tag;
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNotesList(ReaderThemeColors colors) {
    final notes = _filteredNotes;
    if (notes.isEmpty) {
      final hasFilter =
          _colorFilter != null ||
          _categoryFilter != null ||
          _tagFilter != null ||
          _searchController.text.trim().isNotEmpty;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sticky_note_2_outlined,
                size: 46,
                color: colors.secondary.withValues(alpha: 0.55),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                hasFilter ? '没有符合筛选条件的笔记' : '还没有笔记与划线',
                style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                hasFilter
                    ? '尝试调整颜色、分类或搜索关键词'
                    : (widget.isPdf
                          ? '点击工具栏「添加笔记」或在页面文字面板长按选句即可记下想法。'
                          : '阅读时长按正文选中一段文字，点击彩色高亮或「写笔记」即可记下想法。'),
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.secondary, fontSize: 12.5, height: 1.5),
              ),
              if (hasFilter) ...[
                const SizedBox(height: AppSpacing.md),
                OutlinedButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _colorFilter = null;
                      _categoryFilter = null;
                      _tagFilter = null;
                    });
                  },
                  child: const Text('清除全部筛选'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final note = notes[index];
        return ReaderNoteCard(
          note: note,
          colors: colors,
          onTap: () => widget.onSelectNote(note),
          onEdit: () async {
            await widget.onEditNote(note);
            if (mounted) setState(() {});
          },
          onQuoteCard: () => unawaited(
            showReaderQuoteCardSheet(
              context: context,
              colors: colors,
              bookTitle: widget.bookTitle,
              author: widget.author,
              note: note,
              runWithSystemDialog: widget.runWithSystemDialog,
            ),
          ),
          onCopy: () => unawaited(_copySingleNote(note)),
          onDelete: () {
            widget.onDeleteNote(note);
            setState(() {});
          },
        );
      },
    );
  }

  Widget _buildBookmarksList(ReaderThemeColors colors) {
    final bookmarks = widget.bookmarks;
    if (bookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bookmark_border_rounded,
                size: 46,
                color: colors.secondary.withValues(alpha: 0.55),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '这本书还没有书签',
                style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '阅读时点击顶栏的书签图标即可记下当前位置。',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.secondary, fontSize: 12.5, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: bookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final bookmark = bookmarks[index];
        final percent = (bookmark.chapterProgress * 100).clamp(0, 100).round();
        return PressableScale(
          pressedScale: 0.985,
          child: Material(
            color: colors.background.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.md),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => widget.onSelectBookmark(bookmark),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.bookmark_rounded, color: colors.accent),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bookmark.chapterTitle.isEmpty
                              ? '第 ${bookmark.chapterIndex + 1} 章'
                              : bookmark.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (bookmark.excerpt.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            bookmark.excerpt,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          widget.isPdf
                              ? '第 ${bookmark.chapterIndex + 1} 页'
                              : '章内 $percent% · ${_formatBookmarkDate(bookmark.createdAt)}',
                          style: TextStyle(color: colors.secondary, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onPromoteBookmarkToNote != null)
                    IconButton(
                      tooltip: '转为笔记',
                      icon: Icon(
                        Icons.edit_note_rounded,
                        color: colors.secondary,
                        size: 20,
                      ),
                      onPressed: () async {
                        await widget.onPromoteBookmarkToNote!(bookmark);
                        if (mounted) setState(() {});
                      },
                    ),
                  IconButton(
                    tooltip: '删除书签',
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: colors.secondary,
                      size: 20,
                    ),
                    onPressed: () {
                      widget.onDeleteBookmark(bookmark);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        );
      },
    );
  }

  static String _formatBookmarkDate(DateTime value) {
    final local = value.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
