import 'package:flutter/material.dart';

import '../models/reader_bookmark.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'app_sheet.dart';

/// Full-screen list of the current book's bookmarks and notes.
///
/// The sheet owns no persistence. It reports edits through callbacks so the
/// reader stays the single writer of the mark list, exactly as the chapter and
/// search panels leave navigation to the reader.
class ReaderBookmarkSheet extends StatelessWidget {
  const ReaderBookmarkSheet({
    super.key,
    required this.bookmarks,
    required this.colors,
    required this.scrollController,
    required this.onSelect,
    required this.onEditNote,
    required this.onDelete,
  });

  final List<ReaderBookmark> bookmarks;
  final ReaderThemeColors colors;
  final ScrollController scrollController;
  final ValueChanged<ReaderBookmark> onSelect;
  final ValueChanged<ReaderBookmark> onEditNote;
  final ValueChanged<ReaderBookmark> onDelete;

  @override
  Widget build(BuildContext context) {
    final noteCount = bookmarks.where((mark) => mark.hasNote).length;
    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            AppSheetHeader(
              title: '书签与笔记',
              subtitle: bookmarks.isEmpty
                  ? '阅读时点击顶栏的书签按钮即可记下当前位置'
                  : '共 ${bookmarks.length} 处，其中 $noteCount 处带笔记',
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: bookmarks.isEmpty
                  ? _EmptyBookmarks(colors: colors)
                  : ListView.separated(
                      controller: scrollController,
                      padding: EdgeInsets.fromLTRB(
                        0,
                        AppSpacing.sm,
                        0,
                        AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: bookmarks.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        indent: 20,
                        endIndent: 20,
                        color: colors.border,
                      ),
                      itemBuilder: (context, index) => _BookmarkTile(
                        bookmark: bookmarks[index],
                        colors: colors,
                        onSelect: onSelect,
                        onEditNote: onEditNote,
                        onDelete: onDelete,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyBookmarks extends StatelessWidget {
  const _EmptyBookmarks({required this.colors});
  final ReaderThemeColors colors;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bookmark_border_rounded,
            size: 44,
            color: colors.secondary.withValues(alpha: 0.6),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '这本书还没有书签',
            style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '顶栏的书签按钮记下当前位置，长按正文选中一段可以直接写笔记。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    ),
  );
}

class _BookmarkTile extends StatelessWidget {
  const _BookmarkTile({
    required this.bookmark,
    required this.colors,
    required this.onSelect,
    required this.onEditNote,
    required this.onDelete,
  });

  final ReaderBookmark bookmark;
  final ReaderThemeColors colors;
  final ValueChanged<ReaderBookmark> onSelect;
  final ValueChanged<ReaderBookmark> onEditNote;
  final ValueChanged<ReaderBookmark> onDelete;

  @override
  Widget build(BuildContext context) {
    final percent = (bookmark.chapterProgress * 100).clamp(0, 100).round();
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
      leading: Icon(
        bookmark.hasNote
            ? Icons.sticky_note_2_outlined
            : Icons.bookmark_rounded,
        color: colors.accent,
      ),
      title: Text(
        bookmark.chapterTitle.isEmpty
            ? '第 ${bookmark.chapterIndex + 1} 章'
            : bookmark.chapterTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          if (bookmark.excerpt.isNotEmpty)
            Text(
              bookmark.excerpt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.secondary, height: 1.4),
            ),
          if (bookmark.hasNote) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                bookmark.note,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '章内 $percent% · ${_formatDate(bookmark.createdAt)}',
            style: TextStyle(color: colors.secondary, fontSize: 11),
          ),
        ],
      ),
      trailing: PopupMenuButton<_BookmarkAction>(
        tooltip: '书签操作',
        icon: Icon(Icons.more_vert_rounded, color: colors.secondary),
        onSelected: (action) => switch (action) {
          _BookmarkAction.editNote => onEditNote(bookmark),
          _BookmarkAction.delete => onDelete(bookmark),
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _BookmarkAction.editNote,
            child: Text(bookmark.hasNote ? '编辑笔记' : '添加笔记'),
          ),
          const PopupMenuItem(value: _BookmarkAction.delete, child: Text('删除')),
        ],
      ),
      onTap: () => onSelect(bookmark),
    );
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }
}

enum _BookmarkAction { editNote, delete }

/// Collects note text for a new or existing mark. Returns null when the user
/// dismisses the dialog, and the trimmed text otherwise; an empty result means
/// the note was cleared and the mark stays a plain bookmark.
Future<String?> showReaderNoteDialog({
  required BuildContext context,
  required ReaderThemeColors colors,
  required String title,
  required String excerpt,
  String initialNote = '',
}) async {
  final controller = TextEditingController(text: initialNote);
  try {
    return await showAppDialog<String>(
      context: context,
      colors: colors,
      builder: (dialogContext) => AppDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (excerpt.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: colors.border.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  excerpt,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 5,
              minLines: 3,
              maxLength: maxReaderBookmarkNote,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '写下你的想法，留空即只保留书签',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}
