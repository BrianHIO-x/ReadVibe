import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../models/reader_note.dart';
import '../repositories/reader_repositories.dart';
import '../services/chinese_text.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import '../widgets/app_choice_pill.dart';
import '../widgets/app_toast.dart';
import '../widgets/reader_note_card.dart';
import '../widgets/reader_note_composer_sheet.dart';
import '../widgets/reader_quote_card_sheet.dart';

/// Cross-book notebook showing every highlight and thought inside either the
/// normal shelf or the unlocked private shelf, strictly isolated by mode.
class LibraryNotesScreen extends StatefulWidget {
  const LibraryNotesScreen({
    super.key,
    required this.storage,
    required this.books,
    required this.colors,
    required this.privateMode,
    required this.onOpenNote,
    this.runWithSystemDialog,
  });

  final LibraryRepository storage;
  final List<Book> books;
  final ReaderThemeColors colors;
  final bool privateMode;
  final Future<void> Function(Book book, ReaderNote note) onOpenNote;
  final Future<T> Function<T>(Future<T> Function() action)? runWithSystemDialog;

  @override
  State<LibraryNotesScreen> createState() => _LibraryNotesScreenState();
}

class _LibraryNotesScreenState extends State<LibraryNotesScreen> {
  final _searchController = TextEditingController();

  bool _loading = true;
  late Map<String, Book> _booksById;
  List<ReaderNote> _allNotes = const <ReaderNote>[];
  String? _selectedBookId;
  NoteColor? _selectedColor;
  NoteCategory? _selectedCategory;
  String? _selectedTag;

  @override
  void initState() {
    super.initState();
    _booksById = <String, Book>{
      for (final book in widget.books)
        if (book.isPrivate == widget.privateMode) book.id: book,
    };
    unawaited(_loadNotes());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    setState(() => _loading = true);
    final scopedBooks = _booksById.values.toList(growable: false);
    final perBook = await Future.wait(
      scopedBooks.map(
        (book) => widget.storage.getNotes(
          book.id,
          isPdf: book.isPdf,
          pdfPageCount: book.pageCount,
        ),
      ),
    );
    final combined = <ReaderNote>[
      for (final list in perBook) ...list,
    ];
    if (!mounted) return;
    setState(() {
      _allNotes = sortedReaderNotes(combined, byTime: true);
      _loading = false;
    });
  }

  List<ReaderNote> get _filteredNotes {
    final query = foldFullWidth(_searchController.text).trim().toLowerCase();
    return _allNotes
        .where((note) {
          if (_selectedBookId != null && note.bookId != _selectedBookId) {
            return false;
          }
          if (_selectedColor != null && note.color != _selectedColor) {
            return false;
          }
          if (_selectedCategory != null && note.category != _selectedCategory) {
            return false;
          }
          if (_selectedTag != null && !note.tags.contains(_selectedTag)) {
            return false;
          }
          if (query.isEmpty) return true;
          final book = _booksById[note.bookId];
          final title = book?.title ?? '';
          return foldFullWidth(note.quote).toLowerCase().contains(query) ||
              foldFullWidth(note.content).toLowerCase().contains(query) ||
              foldFullWidth(note.chapterTitle).toLowerCase().contains(query) ||
              foldFullWidth(title).toLowerCase().contains(query) ||
              note.tags.any((t) => foldFullWidth(t).toLowerCase().contains(query));
        })
        .toList(growable: false);
  }

  Future<void> _editNote(ReaderNote note) async {
    final book = _booksById[note.bookId];
    if (book == null) return;
    final draft = await showReaderNoteComposerSheet(
      context: context,
      colors: widget.colors,
      title: '编辑笔记',
      locationLabel: '《${book.title}》 · ${note.chapterTitle}',
      initialQuote: note.quote,
      initialContent: note.content,
      initialColor: note.color,
      initialStyle: note.style,
      initialCategory: note.category,
      initialTags: note.tags,
      allowStyleSelection: !note.isPdf,
      allowEditQuote: note.isPdf,
      allowDelete: true,
    );
    if (draft == null || !mounted) return;
    final bookNotes = _allNotes
        .where((item) => item.bookId == note.bookId)
        .toList();
    if (draft.deleted) {
      bookNotes.removeWhere((item) => item.id == note.id);
    } else {
      final index = bookNotes.indexWhere((item) => item.id == note.id);
      if (index >= 0) {
        bookNotes[index] = bookNotes[index].copyWith(
          quote: draft.quote,
          content: draft.content,
          color: draft.color,
          style: draft.style,
          category: draft.category,
          tags: draft.tags,
          updatedAt: DateTime.now(),
        );
      }
    }
    await widget.storage.saveNotes(note.bookId, bookNotes);
    await _loadNotes();
  }

  Future<void> _deleteNote(ReaderNote note) async {
    final bookNotes = _allNotes
        .where((item) => item.bookId == note.bookId && item.id != note.id)
        .toList();
    await widget.storage.saveNotes(note.bookId, bookNotes);
    await _loadNotes();
    if (mounted) {
      AppToast.info(
        context,
        '已删除笔记',
        colors: widget.colors,
        icon: Icons.delete_outline_rounded,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isDark = colors.background.computeLuminance() < 0.35;
    final bookCount = <String>{for (final n in _allNotes) n.bookId}.length;
    final thoughtCount = _allNotes.where((n) => n.hasContent).length;
    final tags = <String>{for (final n in _allNotes) ...n.tags};
    final filtered = _filteredNotes;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemUiOverlayStyle(colors),
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          foregroundColor: colors.text,
          title: Text(widget.privateMode ? '隐私读书笔记' : '读书笔记'),
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: colors.accent))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.xs,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.lg,
                            vertical: AppSpacing.md,
                          ),
                          decoration: BoxDecoration(
                            color: colors.headerBg,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: colors.border),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _StatColumn(
                                value: '$bookCount',
                                label: '相关书籍',
                                colors: colors,
                              ),
                              _StatColumn(
                                value: '${_allNotes.length}',
                                label: '划线摘录',
                                colors: colors,
                              ),
                              _StatColumn(
                                value: '$thoughtCount',
                                label: '批注想法',
                                colors: colors,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextField(
                          controller: _searchController,
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
                            hintText: '搜索跨书摘录、想法、书名或 #标签',
                          ),
                        ),
                        if (_allNotes.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final color in NoteColor.values)
                                  GestureDetector(
                                    onTap: () => setState(() {
                                      _selectedColor =
                                          _selectedColor == color ? null : color;
                                    }),
                                    child: AnimatedScale(
                                      scale: _selectedColor == color
                                          ? 1.16
                                          : 1.0,
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      curve: Curves.easeOutBack,
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        width: 22,
                                        height: 22,
                                        margin: const EdgeInsets.only(right: 8),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: color.swatchColor(isDark),
                                          border: _selectedColor == color
                                              ? Border.all(
                                                  color: colors.text,
                                                  width: 2,
                                                )
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                                for (final bookId in <String>{
                                  for (final n in _allNotes) n.bookId,
                                })
                                  if (_booksById[bookId] != null)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: AppChoicePill(
                                        label: _booksById[bookId]!.title,
                                        selected: _selectedBookId == bookId,
                                        compact: true,
                                        maxLabelWidth: 140,
                                        colors: colors,
                                        onTap: () => setState(() {
                                          _selectedBookId =
                                              _selectedBookId == bookId
                                              ? null
                                              : bookId;
                                        }),
                                      ),
                                    ),
                                for (final cat in NoteCategory.values)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: AppChoicePill(
                                      label: cat.label,
                                      selected: _selectedCategory == cat,
                                      compact: true,
                                      colors: colors,
                                      onTap: () => setState(() {
                                        _selectedCategory =
                                            _selectedCategory == cat
                                            ? null
                                            : cat;
                                      }),
                                    ),
                                  ),
                                for (final tag in tags)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: AppChoicePill(
                                      label: '#$tag',
                                      selected: _selectedTag == tag,
                                      compact: true,
                                      colors: colors,
                                      onTap: () => setState(() {
                                        _selectedTag = _selectedTag == tag
                                            ? null
                                            : tag;
                                      }),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Divider(height: 1, color: colors.border),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              _allNotes.isEmpty
                                  ? '还没有记下任何阅读笔记'
                                  : '没有符合条件的笔记',
                              style: TextStyle(color: colors.secondary),
                            ),
                          )
                        : ListView.separated(
                            padding: EdgeInsets.fromLTRB(
                              AppSpacing.lg,
                              AppSpacing.md,
                              AppSpacing.lg,
                              AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                            ),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (context, index) {
                              final note = filtered[index];
                              final book = _booksById[note.bookId];
                              return ReaderNoteCard(
                                note: note,
                                colors: colors,
                                bookTitle: book?.title,
                                onTap: () async {
                                  if (book == null) return;
                                  Navigator.of(context).pop();
                                  await widget.onOpenNote(book, note);
                                },
                                onEdit: () => unawaited(_editNote(note)),
                                onQuoteCard: () {
                                  if (book == null) return;
                                  unawaited(
                                    showReaderQuoteCardSheet(
                                      context: context,
                                      colors: colors,
                                      bookTitle: book.title,
                                      author: book.author,
                                      note: note,
                                      runWithSystemDialog: widget.runWithSystemDialog,
                                    ),
                                  );
                                },
                                onCopy: () async {
                                  final text = [
                                    if (note.hasQuote) '「${note.quote}」',
                                    if (note.hasContent) note.content,
                                  ].join('\n\n');
                                  await Clipboard.setData(ClipboardData(text: text));
                                  if (!context.mounted) return;
                                  AppToast.success(context, '已复制笔记', colors: colors);
                                },
                                onDelete: () => unawaited(_deleteNote(note)),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({
    required this.value,
    required this.label,
    required this.colors,
  });

  final String value;
  final String label;
  final ReaderThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: colors.accent,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(color: colors.secondary, fontSize: 11.5),
        ),
      ],
    );
  }
}
