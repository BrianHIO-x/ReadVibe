part of '../reader_screen.dart';

// A publisher's footnote marker points at a note that is usually a short
// block, either later in the same document or in a shared notes file.
// Showing that block in place keeps the reading position; anything longer is
// a real cross-reference and navigates.

/// Longest target still treated as a footnote rather than a destination.
const _footnotePreviewLimit = 600;

extension _ReaderScreenSheetsAndLinks on _ReaderScreenState {
  void _showChapterList() => unawaited(_presentChapterList());

  Future<void> _presentChapterList() async {
    if (!mounted || _readerModalOpen) return;
    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    _beginReaderModal();
    try {
      await showAppSheet<void>(
        context: context,
        colors: themeColors,
        sheetAnimationStyle: AnimationStyle(
          duration: AppMotion.sheet,
          reverseDuration: AppMotion.normal,
        ),
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: DraggableScrollableSheet(
            initialChildSize: 0.95,
            maxChildSize: 0.95,
            minChildSize: 0.3,
            builder: (_, scrollController) => ChapterListSheet(
              chapters: _book.chapters,
              currentChapter: _chapterIndex,
              scrollController: scrollController,
              colors: themeColors,
              wordCountListenable: _wordCountController.wordCount,
              chapterWordCountsListenable:
                  _wordCountController.chapterWordCounts,
              collapsedGroupIds: _collapsedTocGroupIds,
              onGroupExpansionChanged: _handleTocGroupExpansionChanged,
              onSelect: _openChapter,
            ),
          ),
        ),
      );
    } finally {
      _endReaderModal();
    }
  }

  void _handleTocGroupExpansionChanged(String groupId, bool expanded) {
    if (expanded) {
      _collapsedTocGroupIds.remove(groupId);
    } else {
      _collapsedTocGroupIds.add(groupId);
    }
    unawaited(
      _storage
          .saveCollapsedTocGroups(_book.id, _collapsedTocGroupIds)
          .catchError((Object error, StackTrace stack) {
            debugPrint('Failed to save directory expansion state: $error');
            debugPrintStack(stackTrace: stack);
          }),
    );
  }

  // ── Bookmarks and notes ─────────────────────────────
  //
  // A mark stores the same (chapter, paragraph, character) anchor the reader
  // uses to restore a position, so it survives font, margin and reading-mode
  // changes. Jumping reuses the search-result path for exactly that reason.

  ReaderThemeColors get _readerThemeColors => AppTheme.getReaderTheme(
    _settings.theme,
    systemBrightness: MediaQuery.platformBrightnessOf(context),
  );

  /// Body text around [anchor], used as the bookmark list preview.
  String _excerptForAnchor(ReadingTextAnchor anchor) {
    if (anchor.chapterIndex < 0 ||
        anchor.chapterIndex >= _book.chapters.length) {
      return '';
    }
    final paragraphs = _paragraphsFor(_book.chapters[anchor.chapterIndex]);
    if (anchor.paragraphIndex < 0 ||
        anchor.paragraphIndex >= paragraphs.length) {
      return '';
    }
    final paragraph = paragraphs[anchor.paragraphIndex];
    final start = anchor.characterOffset.clamp(0, paragraph.length);
    return clampBookmarkText(
      paragraph.substring(start),
      maxReaderBookmarkExcerpt,
    );
  }

  ReaderBookmark? _bookmarkForAnchor(ReadingTextAnchor anchor) {
    for (final mark in _bookmarks) {
      if (mark.chapterIndex == anchor.chapterIndex &&
          mark.paragraphIndex == anchor.paragraphIndex) {
        return mark;
      }
    }
    return null;
  }

  ReaderBookmark _buildBookmark(ReadingTextAnchor anchor, {String note = ''}) {
    final chapter = _book.chapters[anchor.chapterIndex];
    return ReaderBookmark(
      id:
          '${anchor.chapterIndex}:${anchor.paragraphIndex}:'
          '${DateTime.now().microsecondsSinceEpoch}',
      chapterIndex: anchor.chapterIndex,
      chapterTitle: clampBookmarkText(chapter.title, 120),
      paragraphIndex: anchor.paragraphIndex,
      characterOffset: anchor.characterOffset,
      excerpt: _excerptForAnchor(anchor),
      note: clampBookmarkText(note, maxReaderBookmarkNote),
      chapterProgress: _lastScrollSnapshot.progress.clamp(0.0, 1.0),
      createdAt: DateTime.now(),
    );
  }

  void _commitBookmarks(List<ReaderBookmark> updated, {bool? currentMarked}) {
    final sorted = sortedReaderBookmarks(updated);
    _setReaderState(() {
      _bookmarks = sorted;
      if (currentMarked != null) _currentPositionBookmarked = currentMarked;
    });
    unawaited(
      _storage.saveBookmarks(_book.id, sorted).catchError((
        Object error,
        StackTrace stack,
      ) {
        debugPrint('Failed to save reader bookmarks: $error');
        debugPrintStack(stackTrace: stack);
      }),
    );
  }

  /// The anchor a bookmark action should use. The reader clips its first line,
  /// so the probe is nudged half a line down and lands on the first line that
  /// is actually whole on screen — the same rule the chapter editor uses.
  ReadingTextAnchor? _bookmarkAnchor() {
    if (_book.chapters.isEmpty) return null;
    final lineExtent = _resolvedSimulationOrNaturalLineExtent(
      _settings,
      _settings.readingMode,
    );
    return _captureReadingTextAnchor(
      _currentScrollSnapshot(),
      topBias: lineExtent / 2,
    );
  }

  void _toggleBookmark() {
    final anchor = _bookmarkAnchor();
    if (anchor == null) {
      _showReaderMessage('正文还没有排版完成，请稍后再试');
      return;
    }
    final existing = _bookmarkForAnchor(anchor);
    if (existing != null) {
      _commitBookmarks(
        _bookmarks.where((mark) => mark.id != existing.id).toList(),
        currentMarked: false,
      );
      _showReaderMessage(existing.hasNote ? '已删除书签和笔记' : '已删除书签');
      return;
    }
    if (_bookmarks.length >= maxReaderBookmarksPerBook) {
      _showReaderMessage('这本书的书签已达 $maxReaderBookmarksPerBook 条上限');
      return;
    }
    _commitBookmarks([
      ..._bookmarks,
      _buildBookmark(anchor),
    ], currentMarked: true);
    _showReaderMessage('已添加书签');
  }

  /// Entry point for the selection toolbar. The selected text becomes the
  /// excerpt so the note reads back against the sentence it was written for.
  Future<void> _addNoteForSelection(String selectedText) async {
    if (!mounted || _readerModalOpen) return;
    final anchor = _bookmarkAnchor();
    if (anchor == null) {
      _showReaderMessage('正文还没有排版完成，请稍后再试');
      return;
    }
    if (_bookmarks.length >= maxReaderBookmarksPerBook) {
      _showReaderMessage('这本书的书签已达 $maxReaderBookmarksPerBook 条上限');
      return;
    }
    final excerpt = clampBookmarkText(selectedText, maxReaderBookmarkExcerpt);
    final colors = _readerThemeColors;
    _beginReaderModal();
    String? note;
    try {
      note = await showReaderNoteDialog(
        context: context,
        colors: colors,
        title: '添加笔记',
        excerpt: excerpt,
      );
    } finally {
      _endReaderModal();
    }
    if (note == null || !mounted) return;
    final mark = _buildBookmark(anchor, note: note);
    _commitBookmarks([
      ..._bookmarks,
      excerpt.isEmpty ? mark : mark.copyWith(excerpt: excerpt),
    ], currentMarked: true);
    _showReaderMessage(note.trim().isEmpty ? '已添加书签' : '已保存笔记');
  }

  Future<void> _editBookmarkNote(ReaderBookmark mark) async {
    if (!mounted) return;
    final colors = _readerThemeColors;
    final note = await showReaderNoteDialog(
      context: context,
      colors: colors,
      title: mark.hasNote ? '编辑笔记' : '添加笔记',
      excerpt: mark.excerpt,
      initialNote: mark.note,
    );
    if (note == null || !mounted) return;
    _commitBookmarks([
      for (final entry in _bookmarks)
        if (entry.id == mark.id) entry.copyWith(note: note.trim()) else entry,
    ]);
  }

  void _deleteBookmark(ReaderBookmark mark) {
    _commitBookmarks(_bookmarks.where((entry) => entry.id != mark.id).toList());
    _refreshCurrentBookmarkState();
  }

  /// Recomputes the toggle icon's state. The empty-list short circuit keeps the
  /// common case free of any text layout.
  void _refreshCurrentBookmarkState() {
    var marked = false;
    if (_bookmarks.isNotEmpty) {
      final anchor = _bookmarkAnchor();
      marked = anchor != null && _bookmarkForAnchor(anchor) != null;
    }
    if (marked == _currentPositionBookmarked || !mounted) return;
    _setReaderState(() => _currentPositionBookmarked = marked);
  }

  void _showBookmarks() => unawaited(_presentBookmarks());

  Future<void> _presentBookmarks() async {
    if (!mounted || _readerModalOpen) return;
    final themeColors = _readerThemeColors;
    _beginReaderModal();
    ReaderBookmark? selected;
    try {
      await showAppSheet<void>(
        context: context,
        colors: themeColors,
        sheetAnimationStyle: AnimationStyle(
          duration: AppMotion.sheet,
          reverseDuration: AppMotion.normal,
        ),
        builder: (sheetContext) => DraggableScrollableSheet(
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          minChildSize: 0.3,
          builder: (_, scrollController) => StatefulBuilder(
            builder: (_, setSheetState) => ReaderBookmarkSheet(
              bookmarks: _bookmarks,
              colors: themeColors,
              scrollController: scrollController,
              onSelect: (mark) {
                selected = mark;
                Navigator.of(sheetContext).pop();
              },
              onEditNote: (mark) async {
                await _editBookmarkNote(mark);
                setSheetState(() {});
              },
              onDelete: (mark) {
                _deleteBookmark(mark);
                setSheetState(() {});
              },
            ),
          ),
        ),
      );
    } finally {
      _endReaderModal();
    }

    // Route and keyboard disposal complete before the reader builds a new
    // controller for the mark's anchor, matching the search-result path.
    final target = selected;
    if (target == null || !mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _openBookmark(target);
  }

  void _openBookmark(ReaderBookmark mark) {
    if (mark.chapterIndex < 0 || mark.chapterIndex >= _book.chapters.length) {
      _showReaderMessage('这条书签指向的章节已不存在');
      return;
    }
    final anchor = ReadingTextAnchor(
      chapterIndex: mark.chapterIndex,
      paragraphIndex: mark.paragraphIndex,
      characterOffset: mark.characterOffset,
    );
    if (!_readingModeReloading) {
      _setReaderState(() => _readingModeReloading = true);
    }
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _switchContinuousChapter(mark.chapterIndex, startAtTop: true);
      _requestContinuousRestore(0, textAnchor: anchor);
    } else {
      _switchChapter(mark.chapterIndex, startAtTop: true);
      _requestScrollRestore(
        offset: 0,
        progress: 0,
        preferProgress: false,
        textAnchor: anchor,
      );
    }
  }

  // ── EPUB internal links ─────────────────────────────
  //
  // A publisher's footnote marker points at a note that is usually a short
  // block, either later in the same document or in a shared notes file.
  // Showing that block in place keeps the reading position; anything longer is
  // a real cross-reference and navigates.

  void _handleEpubLink(EpubLinkTarget target) =>
      unawaited(_openEpubLink(target));

  Future<void> _openEpubLink(EpubLinkTarget target) async {
    if (!mounted || _readerModalOpen) return;
    if (target.chapterIndex < 0 ||
        target.chapterIndex >= _book.chapters.length) {
      _showReaderMessage('这个链接指向的位置不在本书内');
      return;
    }
    // A directory row is a destination, not an annotation reference: jump
    // without showing its short target in a note sheet.
    final note = target.hasBlock && !target.needDirectJump
        ? _epubLinkPreview(target)
        : null;
    if (note == null) {
      _jumpToEpubLink(target);
      return;
    }
    var jump = false;
    final themeColors = _readerThemeColors;
    _beginReaderModal();
    try {
      await showAppSheet<void>(
        context: context,
        colors: themeColors,
        builder: (sheetContext) => AppSheetSurface(
          colors: themeColors,
          child: SafeArea(
            top: false,
            bottom: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom:
                    AppSpacing.lg + MediaQuery.paddingOf(sheetContext).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppSheetHeader(
                    title: '注释',
                    subtitle: _book.chapters[target.chapterIndex].title,
                  ),
                  Divider(height: 1, color: themeColors.border),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Text(
                      note,
                      style: TextStyle(
                        color: themeColors.text,
                        fontSize: 15,
                        height: 1.7,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () {
                          jump = true;
                          Navigator.of(sheetContext).pop();
                        },
                        icon: const Icon(Icons.north_east_rounded, size: 18),
                        label: const Text('跳转到该位置'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      _endReaderModal();
    }
    if (!jump || !mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _jumpToEpubLink(target);
  }

  /// Text of a link target short enough to read without leaving the page.
  /// Returns null when the target is missing, empty or long enough to be a
  /// destination in its own right.
  String? _epubLinkPreview(EpubLinkTarget target) {
    final List<EpubContentBlock> blocks;
    try {
      blocks = _book.chapters[target.chapterIndex].epubBlocks;
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to read an EPUB link target: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
    if (target.blockIndex < 0 || target.blockIndex >= blocks.length) {
      return null;
    }
    final block = blocks[target.blockIndex];
    if (!block.isText) return null;
    // A chapter or section heading is a destination even when its target was
    // recorded without the directory flag; old books keep working this way.
    if (block.isHeading) return null;
    final text = block.text.trim();
    if (text.isEmpty || text.length > _footnotePreviewLimit) return null;
    return text;
  }

  void _jumpToEpubLink(EpubLinkTarget target) {
    final anchor = target.hasBlock
        ? ReadingTextAnchor(
            chapterIndex: target.chapterIndex,
            paragraphIndex: _readingParagraphForBlock(
              target.chapterIndex,
              target.blockIndex,
            ),
            characterOffset: 0,
          )
        : null;
    if (!_readingModeReloading) {
      _setReaderState(() => _readingModeReloading = true);
    }
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _switchContinuousChapter(target.chapterIndex, startAtTop: true);
      if (anchor != null) _requestContinuousRestore(0, textAnchor: anchor);
    } else {
      _switchChapter(target.chapterIndex, startAtTop: true);
      if (anchor != null) {
        _requestScrollRestore(
          offset: 0,
          progress: 0,
          preferProgress: false,
          textAnchor: anchor,
        );
      }
    }
  }

  /// Maps a rich block index onto the reading-paragraph index the anchor
  /// system uses. Empty and image blocks are not visible paragraphs, so the
  /// two sequences drift apart inside an illustrated chapter.
  int _readingParagraphForBlock(int chapterIndex, int blockIndex) {
    final List<EpubContentBlock> blocks;
    try {
      blocks = _book.chapters[chapterIndex].epubBlocks;
    } on Object {
      return 0;
    }
    var paragraph = 0;
    for (var index = 0; index < blocks.length && index < blockIndex; index++) {
      final block = blocks[index];
      if (block.isText && block.text.trim().isNotEmpty) paragraph++;
    }
    return paragraph;
  }

  void _showSettings() => unawaited(_presentSettings());

  Future<void> _presentSettings() async {
    if (!mounted || _readerModalOpen) return;
    var sheetSettings = _settings;
    _beginReaderModal();
    try {
      await showAppSheet<void>(
        context: context,
        colors: AppTheme.getReaderTheme(
          sheetSettings.theme,
          systemBrightness: MediaQuery.platformBrightnessOf(context),
        ),
        sheetAnimationStyle: AnimationStyle(
          duration: AppMotion.settingsSheet,
          reverseDuration: AppMotion.settingsSheetClose,
        ),
        builder: (_) => StatefulBuilder(
          builder: (context, setSheetState) {
            final themeColors = AppTheme.getReaderTheme(
              sheetSettings.theme,
              systemBrightness: MediaQuery.platformBrightnessOf(context),
            );
            return ReaderSettingsSheet(
              settings: sheetSettings,
              colors: themeColors,
              powerSaveMode: MotionService.powerSaveMode,
              onChange: (newSettings) {
                setSheetState(() => sheetSettings = newSettings);
                _queueSettingsApply(newSettings);
                _persistSettings(newSettings);
              },
              onImportFont: () async {
                try {
                  final newSettings = await _fontService.pickAndInstallFont(
                    sheetSettings,
                  );
                  if (newSettings == null) return;
                  if (!context.mounted || !mounted) return;
                  setSheetState(() => sheetSettings = newSettings);
                  _queueSettingsApply(newSettings);
                  await _storage.saveSettings(newSettings);
                  _showReaderMessage('字体已导入并应用');
                } catch (e) {
                  _showReaderMessage(
                    e is FormatException
                        ? e.message
                        : '字体导入失败，请选择 .ttf 或 .otf 文件',
                  );
                }
              },
            );
          },
        ),
      );
    } finally {
      _endReaderModal();
    }
  }

  void _showSearch() {
    unawaited(_presentSearch());
  }

  Future<void> _presentSearch() async {
    if (!mounted || _readerModalOpen) return;
    final searchSession = _searchController.begin(_book);
    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    _beginReaderModal();
    BookSearchResult? selectedResult;
    try {
      selectedResult = await showAppSheet<BookSearchResult>(
        context: context,
        colors: themeColors,
        builder: (sheetContext) => AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.88,
            child: BookSearchSheet<BookSearchResult>(
              colors: themeColors,
              onSearch: searchSession.search,
              onSelect: (result) =>
                  Navigator.of(sheetContext).pop<BookSearchResult>(result),
            ),
          ),
        ),
      );
    } finally {
      _searchController.end(searchSession);
      _endReaderModal();
    }

    // Route and keyboard disposal complete before the reader creates a new
    // controller for the matched text anchor.  This avoids positioning a
    // simulated page during the bottom-sheet reverse animation.
    if (selectedResult == null || !mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _openSearchResult(selectedResult);
  }

  void _openSearchResult(BookSearchResult result) {
    if (result.chapterIndex < 0 ||
        result.chapterIndex >= _book.chapters.length) {
      return;
    }
    final anchor = ReadingTextAnchor(
      chapterIndex: result.chapterIndex,
      paragraphIndex: result.paragraphIndex,
      characterOffset:
          result.characterOffset +
          _paragraphPrefixLength(
            _book.chapters[result.chapterIndex],
            result.paragraphIndex,
          ),
    );
    if (!_readingModeReloading) {
      _setReaderState(() => _readingModeReloading = true);
    }
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _switchContinuousChapter(result.chapterIndex, startAtTop: true);
      _requestContinuousRestore(0, textAnchor: anchor);
    } else {
      _switchChapter(result.chapterIndex, startAtTop: true);
      _requestScrollRestore(
        offset: 0,
        progress: 0,
        preferProgress: false,
        textAnchor: anchor,
      );
    }
  }

  void _showChapterEditor() => unawaited(_presentChapterEditor());

  /// Character offset in [chapter] that the editor should open on. The reader
  /// usually shows a sliced line at the very top, so the probe is nudged half a
  /// line down and lands on the first line the reader can actually read.
  int? _editorAnchorOffset(Chapter chapter, ScrollSnapshot snapshot) {
    final lineExtent = _resolvedSimulationOrNaturalLineExtent(
      _settings,
      _settings.readingMode,
    );
    final anchor = _captureReadingTextAnchor(snapshot, topBias: lineExtent / 2);
    if (anchor == null || anchor.chapterIndex != _chapterIndex) return null;
    final prefix = _paragraphPrefixLength(chapter, anchor.paragraphIndex);
    return contentOffsetForReadingParagraph(
      chapter,
      anchor.paragraphIndex,
      math.max(0, anchor.characterOffset - prefix),
    );
  }

  Future<void> _presentChapterEditor() async {
    if (!mounted || _readerModalOpen) return;
    if (_settings.readingMode != ReaderReadingMode.chapter) {
      _showReaderMessage('编辑器仅在分章滑动模式中可用');
      return;
    }
    final chapter = _currentChapter;
    final snapshot = _currentScrollSnapshot();
    final textAnchor = _captureReadingTextAnchor(snapshot);
    final editorAnchorOffset = _editorAnchorOffset(chapter, snapshot);
    final progress = _recordCurrentChapterPosition(snapshot);
    _enqueueProgressSave(progress);
    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    var saved = false;
    _beginReaderModal();
    _showStatusBar();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ChapterEditorSheet(
            initialTitle: chapter.title,
            initialContent: chapter.content,
            hasRichContent: chapter.hasRichEpubContent,
            colors: themeColors,
            initialAnchorOffset: editorAnchorOffset,
            onSave: (title, content) async {
              await _applyChapterEdit(
                title: title,
                content: content,
                snapshot: snapshot,
                textAnchor: textAnchor,
              );
              saved = true;
            },
          ),
        ),
      );
    } finally {
      _endReaderModal();
      if (mounted) {
        if (_showOverlay) {
          _showStatusBar();
        } else {
          _hideStatusBarForReader();
        }
      }
    }
    if (saved && mounted) {
      _showReaderMessage('当前章节已保存');
    }
  }

  Future<void> _applyChapterEdit({
    required String title,
    required String content,
    required ScrollSnapshot snapshot,
    required ReadingTextAnchor? textAnchor,
  }) async {
    if (_settings.readingMode != ReaderReadingMode.chapter) {
      throw StateError('编辑器仅在分章滑动模式中可用');
    }
    // Invalidate any whole-book count that started before this edit. Its
    // completion must not write stale counts against the new chapter payload.
    _wordCountController.invalidate();
    final result = await _chapterEditingController.save(
      sourceBook: _book,
      chapterIndex: _chapterIndex,
      title: title,
      content: content,
      existingChapterWordCounts: _wordCountController.chapterWordCounts.value,
    );
    if (!mounted) return;

    _layoutCache.clear();
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController();
    final adjacentControllers = _adjacentScrollControllers.values.toSet();
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();
    _resetContinuousMetrics();
    _setReaderState(() {
      _book = result.book;
      _scrollController = nextController;
      _warmAdjacentPages = false;
      _pageDragTargetIndex = null;
      _readingModeReloading = true;
      _showOverlay = false;
    });
    _wordCountController.apply(
      chapterCounts: result.chapterWordCounts,
      total: result.wordCount,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
      for (final controller in adjacentControllers) {
        controller.dispose();
      }
    });
    _scheduleAdjacentWarmup();
    _requestScrollRestore(
      offset: snapshot.offset,
      progress: snapshot.progress,
      preferProgress: false,
      textAnchor: textAnchor,
    );
    if (result.chapterWordCounts == null) {
      unawaited(_wordCountController.ensure(_book));
    }
  }

  void _showReaderMessage(String message) {
    if (!mounted) return;
    AppToast.info(
      context,
      message,
      colors: AppTheme.getReaderTheme(
        _settings.theme,
        systemBrightness: MediaQuery.platformBrightnessOf(context),
      ),
    );
  }
}
