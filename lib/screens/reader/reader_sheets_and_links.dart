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
            minChildSize: 0.38,
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

  void _rebuildNotesIndex(List<ReaderNote> notes) {
    final map = <int, Map<int, List<ReaderNote>>>{};
    for (final note in notes) {
      if (note.isPdf || note.paragraphIndex < 0) continue;
      final byPara = map.putIfAbsent(
        note.chapterIndex,
        () => <int, List<ReaderNote>>{},
      );
      byPara.putIfAbsent(note.paragraphIndex, () => <ReaderNote>[]).add(note);
    }
    _notesByChapterParagraph = map;
  }

  List<ReaderNoteHighlightSpan> _noteSpansForParagraph(
    int chapterIndex,
    int paragraphIndex,
  ) {
    final notes = _notesByChapterParagraph[chapterIndex]?[paragraphIndex];
    if (notes == null || notes.isEmpty) {
      return const <ReaderNoteHighlightSpan>[];
    }
    return <ReaderNoteHighlightSpan>[
      for (final note in notes)
        ReaderNoteHighlightSpan(
          note: note,
          startOffset: note.startOffset,
          endOffset: note.endOffset,
        ),
    ];
  }

  List<int?>? _epubParagraphIndexByBlock(Chapter chapter) {
    if (!chapter.hasRichEpubContent) return null;
    final blocks = chapter.epubBlocks;
    final result = List<int?>.filled(blocks.length, null, growable: false);
    var p = 0;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block.isText && block.text.trim().isNotEmpty) {
        result[i] = p++;
      }
    }
    return result;
  }

  void _commitNotes(List<ReaderNote> updated) {
    final sorted = sortedReaderNotes(updated);
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    _setReaderState(() {
      _notes = sorted;
      _rebuildNotesIndex(sorted);
    });
    _scheduleSimulationSnapshotWarmup();
    unawaited(
      _storage.saveNotes(_book.id, sorted).catchError((
        Object error,
        StackTrace stack,
      ) {
        debugPrint('Failed to save reader notes: $error');
        debugPrintStack(stackTrace: stack);
      }),
    );
  }

  ({
    int chapterIndex,
    int paragraphIndex,
    int startOffset,
    int endOffset,
    String quote,
  })?
  _resolveSelectionSpan(ReaderSelectionPayload payload) {
    if (_book.chapters.isEmpty) return null;
    final cleanQuote = clampNoteText(payload.selectedText, maxReaderNoteQuote);
    if (cleanQuote.isEmpty) return null;

    final snapshot = _currentScrollSnapshot();
    var approxOffset = snapshot.offset;
    final surfaceObj = _readingSurfaceKey.currentContext?.findRenderObject();
    if (payload.startGlobalDy != null &&
        surfaceObj is RenderBox &&
        surfaceObj.attached &&
        surfaceObj.hasSize) {
      final localDy =
          payload.startGlobalDy! - surfaceObj.localToGlobal(Offset.zero).dy;
      if (localDy.isFinite) {
        approxOffset = math.max(0.0, snapshot.offset + localDy);
      }
    }
    final hintAnchor = _captureReadingTextAnchor(
      ScrollSnapshot(offset: approxOffset, progress: snapshot.progress),
    );
    final candidateChapters = <int>[
      if (hintAnchor != null) hintAnchor.chapterIndex else _chapterIndex,
      if (_settings.readingMode == ReaderReadingMode.continuous) ...[
        if (_chapterIndex + 1 < _book.chapters.length) _chapterIndex + 1,
        if (_chapterIndex - 1 >= 0) _chapterIndex - 1,
      ],
    ];
    final lines = payload.selectedText
        .split(RegExp(r'\n+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final needle = lines.isNotEmpty ? lines.first : cleanQuote;

    for (final cIdx in candidateChapters.toSet()) {
      if (cIdx < 0 || cIdx >= _book.chapters.length) continue;
      final paragraphs = _paragraphsFor(_book.chapters[cIdx]);
      if (paragraphs.isEmpty) continue;
      final center =
          (hintAnchor != null && hintAnchor.chapterIndex == cIdx)
          ? hintAnchor.paragraphIndex.clamp(0, paragraphs.length - 1)
          : 0;
      final order = <int>[center];
      for (var d = 1; d < paragraphs.length; d++) {
        if (center + d < paragraphs.length) order.add(center + d);
        if (center - d >= 0) order.add(center - d);
      }
      for (final pIdx in order) {
        final text = paragraphs[pIdx];
        final hit = _bestMatchOffset(
          text,
          needle,
          nearOffset: (hintAnchor != null &&
                  hintAnchor.chapterIndex == cIdx &&
                  hintAnchor.paragraphIndex == pIdx)
              ? hintAnchor.characterOffset
              : 0,
        );
        if (hit != null) {
          return (
            chapterIndex: cIdx,
            paragraphIndex: pIdx,
            startOffset: hit.$1,
            endOffset: hit.$2,
            quote: cleanQuote,
          );
        }
      }
    }

    final fallback = hintAnchor ?? _bookmarkAnchor();
    if (fallback == null) return null;
    final pLen = _paragraphsFor(_book.chapters[fallback.chapterIndex])
        .elementAtOrNull(fallback.paragraphIndex)
        ?.length ??
        0;
    final start = fallback.characterOffset.clamp(0, pLen);
    return (
      chapterIndex: fallback.chapterIndex,
      paragraphIndex: fallback.paragraphIndex,
      startOffset: start,
      endOffset: math.min(pLen, start + needle.length),
      quote: cleanQuote,
    );
  }

  static (int, int)? _bestMatchOffset(
    String haystack,
    String needle, {
    required int nearOffset,
  }) {
    if (needle.isEmpty || haystack.isEmpty) return null;
    var index = haystack.indexOf(needle);
    if (index >= 0) {
      var bestStart = index;
      var bestDist = (index - nearOffset).abs();
      while (true) {
        index = haystack.indexOf(needle, index + 1);
        if (index < 0) break;
        final dist = (index - nearOffset).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestStart = index;
        }
      }
      return (bestStart, math.min(haystack.length, bestStart + needle.length));
    }
    final probeLen = math.min(18, needle.length);
    if (probeLen >= 3) {
      final prefixHit = haystack.indexOf(needle.substring(0, probeLen));
      if (prefixHit >= 0) {
        return (
          prefixHit,
          math.min(haystack.length, prefixHit + needle.length),
        );
      }
    }
    return null;
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
      _showReaderMessage('已删除书签', icon: Icons.bookmark_remove_outlined);
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
    _showReaderMessage(
      '已添加书签',
      tone: AppToastTone.success,
      icon: Icons.bookmark_rounded,
    );
  }

  Future<void> _quickHighlightSelection(
    ReaderSelectionPayload payload,
    NoteColor color,
    NoteStyle style,
  ) async {
    if (!mounted) return;
    if (_notes.length >= maxReaderNotesPerBook) {
      _showReaderMessage('这本书的笔记已达 $maxReaderNotesPerBook 条上限');
      return;
    }
    final span = _resolveSelectionSpan(payload);
    if (span == null) {
      _showReaderMessage('正文还没有排版完成，请稍后再试');
      return;
    }
    final now = DateTime.now();
    final chapter = _book.chapters[span.chapterIndex];
    final created = ReaderNote(
      id: '${_book.id}:${span.chapterIndex}:${span.paragraphIndex}:${now.microsecondsSinceEpoch}',
      bookId: _book.id,
      chapterIndex: span.chapterIndex,
      chapterTitle: clampNoteText(chapter.title, 120),
      paragraphIndex: span.paragraphIndex,
      startOffset: span.startOffset,
      endOffset: span.endOffset,
      quote: span.quote,
      color: color,
      style: style,
      category: NoteCategory.highlight,
      chapterProgress: _lastScrollSnapshot.progress.clamp(0.0, 1.0),
      isPdf: false,
      createdAt: now,
      updatedAt: now,
    );
    _commitNotes(<ReaderNote>[..._notes, created]);
    final isDark = _readerThemeColors.background.computeLuminance() < 0.35;
    _showReaderMessage(
      '已添加${color.label}${style.label}',
      swatchColor: color.swatchColor(isDark),
    );
  }

  /// Entry point for the selection toolbar. Opens the rich composer anchored
  /// onto the exact selected span.
  Future<void> _addNoteForSelection(
    ReaderSelectionPayload payload, {
    NoteStyle? style,
  }) async {
    if (!mounted || _readerModalOpen) return;
    if (_notes.length >= maxReaderNotesPerBook) {
      _showReaderMessage('这本书的笔记已达 $maxReaderNotesPerBook 条上限');
      return;
    }
    final span = _resolveSelectionSpan(payload);
    if (span == null) {
      _showReaderMessage('正文还没有排版完成，请稍后再试');
      return;
    }
    final chapter = _book.chapters[span.chapterIndex];
    final chapterTitle = _epubLayout.formatChapterTitle(chapter.title);
    final colors = _readerThemeColors;
    _beginReaderModal();
    ReaderNoteDraft? draft;
    try {
      draft = await showReaderNoteComposerSheet(
        context: context,
        colors: colors,
        title: '写阅读笔记',
        locationLabel: chapterTitle.isNotEmpty
            ? chapterTitle
            : '第 ${span.chapterIndex + 1} 章',
        initialQuote: span.quote,
        initialStyle: style ?? NoteStyle.highlight,
      );
    } finally {
      _endReaderModal();
    }
    if (draft == null || draft.deleted || !mounted) return;
    final now = DateTime.now();
    final note = ReaderNote(
      id: '${_book.id}:${span.chapterIndex}:${span.paragraphIndex}:${now.microsecondsSinceEpoch}',
      bookId: _book.id,
      chapterIndex: span.chapterIndex,
      chapterTitle: clampNoteText(chapter.title, 120),
      paragraphIndex: span.paragraphIndex,
      startOffset: span.startOffset,
      endOffset: span.endOffset,
      quote: draft.quote,
      content: draft.content,
      color: draft.color,
      style: draft.style,
      category: draft.category,
      tags: draft.tags,
      chapterProgress: _lastScrollSnapshot.progress.clamp(0.0, 1.0),
      isPdf: false,
      createdAt: now,
      updatedAt: now,
    );
    _commitNotes(<ReaderNote>[..._notes, note]);
    final isDark = _readerThemeColors.background.computeLuminance() < 0.35;
    _showReaderMessage(
      note.hasContent ? '已保存阅读笔记' : '已保存划线高亮',
      tone: AppToastTone.success,
      swatchColor: note.hasContent ? null : draft.color.swatchColor(isDark),
    );
  }

  Future<void> _shareQuoteCardForSelection(ReaderSelectionPayload payload) async {
    if (!mounted || _readerModalOpen) return;
    final span = _resolveSelectionSpan(payload);
    final chapterIndex = span?.chapterIndex ?? _chapterIndex;
    final chapterTitle = chapterIndex >= 0 && chapterIndex < _book.chapters.length
        ? _epubLayout.formatChapterTitle(_book.chapters[chapterIndex].title)
        : '';
    final now = DateTime.now();
    final previewNote = ReaderNote(
      id: 'preview:${now.microsecondsSinceEpoch}',
      bookId: _book.id,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      paragraphIndex: span?.paragraphIndex ?? 0,
      startOffset: span?.startOffset ?? 0,
      endOffset: span?.endOffset ?? 0,
      quote: span?.quote ?? payload.selectedText.trim(),
      color: NoteColor.terracotta,
      style: NoteStyle.highlight,
      category: NoteCategory.insight,
      chapterProgress: _lastScrollSnapshot.progress.clamp(0.0, 1.0),
      createdAt: now,
      updatedAt: now,
    );
    final colors = _readerThemeColors;
    _beginReaderModal();
    try {
      await showReaderQuoteCardSheet(
        context: context,
        colors: colors,
        bookTitle: _book.title,
        author: _book.author,
        note: previewNote,
      );
    } finally {
      _endReaderModal();
    }
  }

  Future<void> _showInlineNoteQuickSheet(ReaderNote note) async {
    if (!mounted || _readerModalOpen) return;
    var activeNote = note;
    final colors = _readerThemeColors;
    _beginReaderModal();
    QuickNoteAction? action;
    try {
      action = await showReaderNoteQuickSheet(
        context: context,
        note: note,
        colors: colors,
        onUpdateAppearance: (updated) {
          activeNote = updated;
          _commitNotes([
            for (final entry in _notes)
              if (entry.id == updated.id) updated else entry,
          ]);
        },
      );
    } finally {
      _endReaderModal();
    }
    if (!mounted || action == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    switch (action) {
      case QuickNoteAction.edit:
        await _editRichNote(activeNote);
      case QuickNoteAction.quoteCard:
        _beginReaderModal();
        try {
          await showReaderQuoteCardSheet(
            context: context,
            colors: colors,
            bookTitle: _book.title,
            author: _book.author,
            note: activeNote,
          );
        } finally {
          _endReaderModal();
        }
      case QuickNoteAction.delete:
        _deleteRichNote(activeNote);
        _showReaderMessage(
          '已删除划线与笔记',
          icon: Icons.delete_outline_rounded,
        );
    }
  }

  Future<void> _editRichNote(ReaderNote note) async {
    if (!mounted || _readerModalOpen) return;
    final colors = _readerThemeColors;
    _beginReaderModal();
    ReaderNoteDraft? draft;
    try {
      draft = await showReaderNoteComposerSheet(
        context: context,
        colors: colors,
        title: note.hasContent ? '编辑笔记' : '写笔记',
        locationLabel: note.chapterTitle.isNotEmpty
            ? note.chapterTitle
            : '第 ${note.chapterIndex + 1} 章',
        initialQuote: note.quote,
        initialContent: note.content,
        initialColor: note.color,
        initialStyle: note.style,
        initialCategory: note.category,
        initialTags: note.tags,
        allowDelete: true,
      );
    } finally {
      _endReaderModal();
    }
    if (draft == null || !mounted) return;
    if (draft.deleted) {
      _deleteRichNote(note);
      _showReaderMessage('已删除笔记', icon: Icons.delete_outline_rounded);
      return;
    }
    _commitNotes([
      for (final entry in _notes)
        if (entry.id == note.id)
          entry.copyWith(
            quote: draft.quote,
            content: draft.content,
            color: draft.color,
            style: draft.style,
            category: draft.category,
            tags: draft.tags,
            updatedAt: DateTime.now(),
          )
        else
          entry,
    ]);
    _showReaderMessage('笔记已更新', tone: AppToastTone.success);
  }

  void _deleteRichNote(ReaderNote note) {
    _commitNotes(_notes.where((entry) => entry.id != note.id).toList());
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
    ReaderBookmark? selectedBookmark;
    ReaderNote? selectedNote;
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
            initialChildSize: 0.78,
            maxChildSize: 0.95,
            minChildSize: 0.38,
            builder: (_, scrollController) => StatefulBuilder(
            builder: (_, setSheetState) => ReaderNotesHubSheet(
              bookTitle: _book.title,
              author: _book.author,
              notes: _notes,
              bookmarks: _bookmarks,
              colors: themeColors,
              scrollController: scrollController,
              onSelectNote: (note) {
                selectedNote = note;
                Navigator.of(sheetContext).pop();
              },
              onEditNote: (note) async {
                final draft = await showReaderNoteComposerSheet(
                  context: sheetContext,
                  colors: themeColors,
                  title: note.hasContent ? '编辑笔记' : '写笔记',
                  locationLabel: note.chapterTitle.isNotEmpty
                      ? note.chapterTitle
                      : '第 ${note.chapterIndex + 1} 章',
                  initialQuote: note.quote,
                  initialContent: note.content,
                  initialColor: note.color,
                  initialStyle: note.style,
                  initialCategory: note.category,
                  initialTags: note.tags,
                  allowDelete: true,
                );
                if (draft == null || !mounted) return;
                if (draft.deleted) {
                  _deleteRichNote(note);
                } else {
                  _commitNotes([
                    for (final entry in _notes)
                      if (entry.id == note.id)
                        entry.copyWith(
                          quote: draft.quote,
                          content: draft.content,
                          color: draft.color,
                          style: draft.style,
                          category: draft.category,
                          tags: draft.tags,
                          updatedAt: DateTime.now(),
                        )
                      else
                        entry,
                  ]);
                }
                setSheetState(() {});
              },
              onDeleteNote: (note) {
                _deleteRichNote(note);
                setSheetState(() {});
              },
              onSelectBookmark: (mark) {
                selectedBookmark = mark;
                Navigator.of(sheetContext).pop();
              },
              onDeleteBookmark: (mark) {
                _deleteBookmark(mark);
                setSheetState(() {});
              },
              onPromoteBookmarkToNote: (mark) async {
                final draft = await showReaderNoteComposerSheet(
                  context: sheetContext,
                  colors: themeColors,
                  title: '将书签转为笔记',
                  locationLabel: mark.chapterTitle.isNotEmpty
                      ? mark.chapterTitle
                      : '第 ${mark.chapterIndex + 1} 章',
                  initialQuote: mark.excerpt,
                );
                if (draft == null || draft.deleted || !mounted) return;
                var startOffset = math.max(0, mark.characterOffset);
                var endOffset = startOffset;
                if (mark.chapterIndex >= 0 &&
                    mark.chapterIndex < _book.chapters.length &&
                    draft.quote.trim().isNotEmpty) {
                  final paragraphs = _paragraphsFor(
                    _book.chapters[mark.chapterIndex],
                  );
                  if (mark.paragraphIndex >= 0 &&
                      mark.paragraphIndex < paragraphs.length) {
                    final hit = _bestMatchOffset(
                      paragraphs[mark.paragraphIndex],
                      draft.quote.trim(),
                      nearOffset: startOffset,
                    );
                    if (hit != null) {
                      startOffset = hit.$1;
                      endOffset = hit.$2;
                    }
                  }
                }
                final now = DateTime.now();
                final created = ReaderNote(
                  id: '${_book.id}:${mark.chapterIndex}:${mark.paragraphIndex}:${now.microsecondsSinceEpoch}',
                  bookId: _book.id,
                  chapterIndex: mark.chapterIndex,
                  chapterTitle: mark.chapterTitle,
                  paragraphIndex: mark.paragraphIndex,
                  startOffset: startOffset,
                  endOffset: endOffset,
                  quote: draft.quote,
                  content: draft.content,
                  color: draft.color,
                  style: draft.style,
                  category: draft.category,
                  tags: draft.tags,
                  chapterProgress: mark.chapterProgress,
                  createdAt: now,
                  updatedAt: now,
                );
                _commitNotes(<ReaderNote>[..._notes, created]);
                setSheetState(() {});
              },
            ),
          ),
        ),
        ),
      );
    } finally {
      _endReaderModal();
    }

    // Route and keyboard disposal complete before the reader builds a new
    // controller for the mark's anchor, matching the search-result path.
    final noteTarget = selectedNote;
    if (noteTarget != null && mounted) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _openNote(noteTarget);
      return;
    }
    final markTarget = selectedBookmark;
    if (markTarget == null || !mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _openBookmark(markTarget);
  }

  void _openNote(ReaderNote note) {
    if (note.chapterIndex < 0 || note.chapterIndex >= _book.chapters.length) {
      _showReaderMessage('这条笔记指向的章节已不存在');
      return;
    }
    _pinnedReadingAnchor = null;
    final anchor = ReadingTextAnchor(
      chapterIndex: note.chapterIndex,
      paragraphIndex: math.max(0, note.paragraphIndex),
      characterOffset: math.max(0, note.startOffset),
    );
    _beginReadingModeReload();
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _switchContinuousChapter(note.chapterIndex, startAtTop: true);
      _requestContinuousRestore(0, textAnchor: anchor);
    } else {
      _switchChapter(note.chapterIndex, startAtTop: true);
      _requestScrollRestore(
        offset: 0,
        progress: 0,
        preferProgress: false,
        textAnchor: anchor,
      );
    }
  }

  void _openBookmark(ReaderBookmark mark) {
    if (mark.chapterIndex < 0 || mark.chapterIndex >= _book.chapters.length) {
      _showReaderMessage('这条书签指向的章节已不存在');
      return;
    }
    _pinnedReadingAnchor = null;
    final anchor = ReadingTextAnchor(
      chapterIndex: mark.chapterIndex,
      paragraphIndex: mark.paragraphIndex,
      characterOffset: mark.characterOffset,
    );
    _beginReadingModeReload();
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

  Future<void> _openEpubLink(
    EpubLinkTarget target, {
    bool fromPointerUp = false,
  }) async {
    if (!mounted || _readerModalOpen) return;
    final now = DateTime.now();
    if (!fromPointerUp &&
        _lastEpubLinkOpenedAt != null &&
        now.difference(_lastEpubLinkOpenedAt!).inMilliseconds < 500) {
      return;
    }
    _lastEpubLinkOpenedAt = now;
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
    _pinnedReadingAnchor = null;
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
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _beginReadingModeReload();
      _switchContinuousChapter(target.chapterIndex, startAtTop: true);
      if (anchor != null) _requestContinuousRestore(0, textAnchor: anchor);
    } else {
      if (target.chapterIndex != _chapterIndex || anchor != null) {
        _beginReadingModeReload();
      }
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
    _pinnedReadingAnchor ??=
        _pendingScrollTextAnchor ??
        _pendingContinuousTextAnchor ??
        _captureReadingTextAnchor(_currentScrollSnapshot());
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
                  _showReaderMessage('字体已导入并应用', tone: AppToastTone.success);
                } catch (e) {
                  _showReaderMessage(
                    e is FormatException
                        ? e.message
                        : '字体导入失败，请选择 .ttf 或 .otf 文件',
                    tone: AppToastTone.error,
                  );
                }
              },
            );
          },
        ),
      );
    } finally {
      if (_settingsApplyTimer?.isActive == true &&
          _pendingSettingsApply != null) {
        _flushPendingSettingsApply();
      }
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
    _pinnedReadingAnchor = null;
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
    _beginReadingModeReload();
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
      _showReaderMessage('当前章节已保存', tone: AppToastTone.success);
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
    _pinnedReadingAnchor = null;

    _layoutCache.clear();
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController();
    final adjacentControllers = _adjacentScrollControllers.values.toSet();
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();
    _resetContinuousWindowAround(_chapterIndex, recreateView: true);
    _resetContinuousMetrics();
    _beginReadingModeReload();
    _setReaderState(() {
      _book = result.book;
      _scrollController = nextController;
      _warmAdjacentPages = false;
      _pageDragTargetIndex = null;
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

  void _showReaderMessage(
    String message, {
    AppToastTone tone = AppToastTone.info,
    IconData? icon,
    Color? swatchColor,
  }) {
    if (!mounted) return;
    AppToast.show(
      context,
      message,
      tone: tone,
      icon: icon,
      swatchColor: swatchColor,
      bottomOffset: _showOverlay ? 84.0 : 0.0,
      colors: AppTheme.getReaderTheme(
        _settings.theme,
        systemBrightness: MediaQuery.platformBrightnessOf(context),
      ),
    );
  }
}
