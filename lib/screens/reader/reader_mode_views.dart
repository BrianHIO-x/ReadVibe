part of '../reader_screen.dart';

extension _ReaderScreenModeViews on _ReaderScreenState {
  Widget _buildReadingModeView({
    required double width,
    required double height,
    required ReaderThemeColors themeColors,
    required String? fontFamily,
    required EdgeInsets viewPadding,
    required double horizontalPadding,
  }) {
    return switch (_settings.readingMode) {
      ReaderReadingMode.chapter => _buildChapterModeView(
        width: width,
        themeColors: themeColors,
        fontFamily: fontFamily,
        viewPadding: viewPadding,
        horizontalPadding: horizontalPadding,
      ),
      ReaderReadingMode.continuous => _buildContinuousModeView(
        themeColors: themeColors,
        fontFamily: fontFamily,
        viewPadding: viewPadding,
        horizontalPadding: horizontalPadding,
      ),
      ReaderReadingMode.simulation => _buildSimulationModeView(
        width: width,
        height: height,
        themeColors: themeColors,
        fontFamily: fontFamily,
        viewPadding: viewPadding,
        horizontalPadding: horizontalPadding,
      ),
    };
  }

  Widget _buildChapterModeView({
    required double width,
    required ReaderThemeColors themeColors,
    required String? fontFamily,
    required EdgeInsets viewPadding,
    required double horizontalPadding,
  }) {
    final currentPage = _buildChapterPage(
      chapter: _currentChapter,
      themeColors: themeColors,
      fontFamily: fontFamily,
      viewPadding: viewPadding,
      horizontalPadding: horizontalPadding,
      controller: _scrollController,
      repaintBoundaryKey: _currentPageBoundaryKey,
    );
    final shouldBuildPrevious =
        _chapterIndex > 0 &&
        (_warmAdjacentPages || _pageDragTargetIndex == _chapterIndex - 1);
    final shouldBuildNext =
        _chapterIndex < _book.chapters.length - 1 &&
        (_warmAdjacentPages || _pageDragTargetIndex == _chapterIndex + 1);
    final previousPage = shouldBuildPrevious
        ? _buildChapterPage(
            chapter: _book.chapters[_chapterIndex - 1],
            themeColors: themeColors,
            fontFamily: fontFamily,
            viewPadding: viewPadding,
            horizontalPadding: horizontalPadding,
            controller: _controllerForAdjacentChapter(_chapterIndex - 1),
          )
        : null;
    final nextPage = shouldBuildNext
        ? _buildChapterPage(
            chapter: _book.chapters[_chapterIndex + 1],
            themeColors: themeColors,
            fontFamily: fontFamily,
            viewPadding: viewPadding,
            horizontalPadding: horizontalPadding,
            controller: _controllerForAdjacentChapter(_chapterIndex + 1),
          )
        : null;

    if (width <= 0) return currentPage;

    return ValueListenableBuilder<double>(
      valueListenable: _pageDragOffsetNotifier,
      builder: (context, offset, _) {
        return SmoothTurnPages(
          width: width,
          dragOffset: offset,
          currentPage: currentPage,
          previousPage: previousPage,
          nextPage: nextPage,
        );
      },
    );
  }

  Widget _buildContinuousModeView({
    required ReaderThemeColors themeColors,
    required String? fontFamily,
    required EdgeInsets viewPadding,
    required double horizontalPadding,
  }) {
    final isDarkTheme = themeColors.background.computeLuminance() < 0.35;
    final contentWidth = math.max(
      1.0,
      _readerViewportWidth - horizontalPadding * 2,
    );
    final paragraphGap =
        _settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? _settings.fontSize * _settings.lineHeight
        : 0.0;
    final bodyStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: _settings.fontSize,
      fontWeight: _settings.effectiveFontWeight,
      shadows: _settings.effectiveFontShadows(themeColors.text),
      height: _settings.lineHeight,
      color: themeColors.text,
      letterSpacing: 0.2,
    );
    final slivers = <Widget>[];
    final windowStart = _book.chapters.isEmpty
        ? 0
        : _continuousWindowStart.clamp(0, _book.chapters.length - 1);
    final windowEnd = _book.chapters.isEmpty
        ? -1
        : _continuousWindowEnd.clamp(windowStart, _book.chapters.length - 1);
    for (
      var chapterIndex = windowStart;
      chapterIndex <= windowEnd;
      chapterIndex++
    ) {
      final chapter = _book.chapters[chapterIndex];
      final hasNotes = _notesByChapterParagraph[chapterIndex]?.isNotEmpty == true;
      final bool useCachedEpubBlocks =
          chapter.hasRichEpubContent &&
          (chapterIndex == _chapterIndex ||
              chapter is! LazyChapter ||
              chapter.store.isCached(chapterIndex));
      final epubBlocks = useCachedEpubBlocks
          ? chapter.epubBlocks
          : const <EpubContentBlock>[];
      final epubParagraphs = useCachedEpubBlocks && hasNotes
          ? _epubParagraphIndexByBlock(chapter)
          : null;
      final hasEmbeddedHeading = _epubLayout.hasEmbeddedHeading(
        chapter,
        avoidLazyLoad: !useCachedEpubBlocks,
      );
      final chapterTop = chapterIndex == _continuousAnchorChapterIndex
          ? viewPadding.top + AppSpacing.lg
          : AppSpacing.xxl;

      Widget buildChapterBodySliver() {
        if (chapter is LazyChapter &&
            chapterIndex != _chapterIndex &&
            !chapter.store.isCached(chapterIndex)) {
          _prefetchChapters([chapterIndex]);
          return SliverToBoxAdapter(
            child: SizedBox(
              height: math.max(360.0, _readerViewportHeight * 0.65),
            ),
          );
        }

        if (chapter.hasRichEpubContent) {
          final bodyExtents = epubBlocks.length <= 2500
              ? _continuousBodyExtents(
                  chapter: chapter,
                  paragraphs: const <String>[],
                  richBlocks: epubBlocks,
                  contentWidth: contentWidth,
                )
              : null;
          Widget buildEpubItem(BuildContext context, int itemIndex) {
            final mappedParagraph =
                epubParagraphs != null && itemIndex < epubParagraphs.length
                ? epubParagraphs[itemIndex]
                : null;
            return ReaderSelectableBlock(
              child: _epubLayout.buildBlock(
                settings: _settings,
                block: epubBlocks[itemIndex],
                themeColors: themeColors,
                width: contentWidth,
                simulationPage: false,
                noteSpans: mappedParagraph != null
                    ? _noteSpansForParagraph(chapterIndex, mappedParagraph)
                    : const <ReaderNoteHighlightSpan>[],
                noteHighlightRegistry: _noteHighlightRegistry,
              ),
            );
          }

          if (bodyExtents != null &&
              bodyExtents.length == epubBlocks.length &&
              epubBlocks.isNotEmpty) {
            return SliverVariedExtentList.builder(
              itemCount: epubBlocks.length,
              itemExtentBuilder: (index, _) => bodyExtents[index],
              itemBuilder: buildEpubItem,
            );
          }
          return SliverList.builder(
            itemCount: epubBlocks.length,
            itemBuilder: buildEpubItem,
          );
        }

        final paragraphs = _paragraphsFor(chapter);
        final bodyExtents = paragraphs.length <= 2500
            ? _continuousBodyExtents(
                chapter: chapter,
                paragraphs: paragraphs,
                richBlocks: const <EpubContentBlock>[],
                contentWidth: contentWidth,
              )
            : null;
        Widget buildPlainItem(BuildContext context, int pIdx) =>
            _buildContinuousPlainParagraph(
              chapterIndex: chapterIndex,
              paragraphIndex: pIdx,
              paragraphCount: paragraphs.length,
              text: paragraphs[pIdx],
              bodyStyle: bodyStyle,
              paragraphGap: paragraphGap,
              hasNotes: hasNotes,
              isDarkTheme: isDarkTheme,
            );
        if (bodyExtents != null &&
            bodyExtents.length == paragraphs.length &&
            paragraphs.isNotEmpty) {
          return SliverVariedExtentList.builder(
            itemCount: paragraphs.length,
            itemExtentBuilder: (index, _) => bodyExtents[index],
            itemBuilder: buildPlainItem,
          );
        }
        return SliverList.builder(
          itemCount: paragraphs.length,
          itemBuilder: buildPlainItem,
        );
      }

      slivers.add(
        SliverMainAxisGroup(
          key: _continuousKeyFor(chapterIndex),
          slivers: [
            if (!hasEmbeddedHeading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    chapterTop,
                    horizontalPadding,
                    AppSpacing.xl,
                  ),
                  child: Text(
                    _epubLayout.formatChapterTitle(chapter.title),
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: themeColors.text,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                hasEmbeddedHeading ? chapterTop : 0,
                horizontalPadding,
                0,
              ),
              sliver: buildChapterBodySliver(),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: chapterIndex == _book.chapters.length - 1
                    ? viewPadding.bottom + 80
                    : 0,
              ),
            ),
          ],
        ),
      );
    }

    return RepaintBoundary(
      child: ColoredBox(
        color: themeColors.background,
        child: ReaderSelectionArea(
          colors: themeColors,
          selectionBlocked: _selectionController.blocked,
          selectionActive: _selectionController.active,
          selectionDragging: _selectionController.dragging,
          onReaderModalOpened: _beginReaderModal,
          onReaderModalClosed: _endReaderModal,
          onQuickHighlight: _quickHighlightSelection,
          onAddNote: _addNoteForSelection,
          onShareQuoteCard: _shareQuoteCardForSelection,
          edgeScrollController: _scrollController,
          edgeScrollEnabled: !_readerModalOpen,
          child: CustomScrollView(
            key: ValueKey('continuous-$_continuousViewGeneration'),
            controller: _scrollController,
            primary: false,
            center: _book.chapters.isEmpty
                ? null
                : _continuousKeyFor(_continuousAnchorChapterIndex),
            scrollCacheExtent: const ScrollCacheExtent.pixels(600),
            slivers: slivers,
          ),
        ),
      ),
    );
  }

  Widget _buildContinuousPlainParagraph({
    required int chapterIndex,
    required int paragraphIndex,
    required int paragraphCount,
    required String text,
    required TextStyle bodyStyle,
    required double paragraphGap,
    required bool hasNotes,
    required bool isDarkTheme,
  }) {
    final justified = ReaderJustifiedText(
      TextSpan(text: text),
      style: bodyStyle,
      nearby: (chapterIndex - _chapterIndex).abs() <= 1,
    );
    final noteSpans = hasNotes
        ? _noteSpansForParagraph(chapterIndex, paragraphIndex)
        : const <ReaderNoteHighlightSpan>[];
    final decorated = noteSpans.isEmpty
        ? justified
        : ReaderAnnotatedParagraph(
            spans: noteSpans,
            isDarkTheme: isDarkTheme,
            registry: _noteHighlightRegistry,
            child: justified,
          );
    return ReaderSelectableBlock(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: paragraphIndex == paragraphCount - 1 ? 0 : paragraphGap,
        ),
        child: decorated,
      ),
    );
  }

  Widget _buildSimulationModeView({
    required double width,
    required double height,
    required ReaderThemeColors themeColors,
    required String? fontFamily,
    required EdgeInsets viewPadding,
    required double horizontalPadding,
  }) {
    final pagePhysics = const NeverScrollableScrollPhysics();
    final currentPage = _buildChapterPage(
      chapter: _currentChapter,
      themeColors: themeColors,
      fontFamily: fontFamily,
      viewPadding: viewPadding,
      horizontalPadding: horizontalPadding,
      controller: _scrollController,
      repaintBoundaryKey: _currentPageBoundaryKey,
      physics: pagePhysics,
      simulationPage: true,
    );
    if (width <= 0 || height <= 0) return currentPage;

    final target = _simulationPageTarget;
    final buildPrevious =
        _chapterIndex > 0 &&
        (_warmAdjacentPages || target?.chapterIndex == _chapterIndex - 1);
    final buildNext =
        _chapterIndex < _book.chapters.length - 1 &&
        (_warmAdjacentPages || target?.chapterIndex == _chapterIndex + 1);
    final previousBoundaryPage = buildPrevious
        ? _buildChapterPage(
            chapter: _book.chapters[_chapterIndex - 1],
            themeColors: themeColors,
            fontFamily: fontFamily,
            viewPadding: viewPadding,
            horizontalPadding: horizontalPadding,
            controller: _controllerForAdjacentChapter(
              _chapterIndex - 1,
              overrideProgress: 1,
            ),
            physics: pagePhysics,
            simulationPage: true,
          )
        : null;
    final nextBoundaryPage = buildNext
        ? _buildChapterPage(
            chapter: _book.chapters[_chapterIndex + 1],
            themeColors: themeColors,
            fontFamily: fontFamily,
            viewPadding: viewPadding,
            horizontalPadding: horizontalPadding,
            controller: _controllerForAdjacentChapter(
              _chapterIndex + 1,
              overrideProgress: 0,
            ),
            physics: pagePhysics,
            simulationPage: true,
          )
        : null;

    Widget? targetPage;
    if (target != null) {
      final controller = _simulationPreviewController;
      if (controller != null) {
        targetPage = _buildChapterPage(
          chapter: _book.chapters[target.chapterIndex],
          themeColors: themeColors,
          fontFamily: fontFamily,
          viewPadding: viewPadding,
          horizontalPadding: horizontalPadding,
          controller: controller,
          repaintBoundaryKey: _simulationPreviewBoundaryKey,
          physics: pagePhysics,
          simulationPage: true,
        );
      }
    }

    // Both boundary pages stay in the tree at all times (offstage or
    // offscreen when idle). Their scroll positions settle while invisible,
    // so a drag never reveals a page that is still jumping to its edge.
    final previousPage = target?.goingNext == false
        ? (targetPage ?? previousBoundaryPage)
        : previousBoundaryPage;
    final nextPage = target?.goingNext == true
        ? (targetPage ?? nextBoundaryPage)
        : nextBoundaryPage;
    Widget? paperBackPage;
    final paperBackController = _simulationPaperBackController;
    if (target != null && paperBackController != null) {
      final movingChapter = target.goingNext
          ? _currentChapter
          : _book.chapters[target.chapterIndex];
      paperBackPage = _buildChapterPage(
        chapter: movingChapter,
        themeColors: themeColors,
        fontFamily: fontFamily,
        viewPadding: viewPadding,
        horizontalPadding: horizontalPadding,
        controller: paperBackController,
        repaintBoundaryKey: target.goingNext ? null : _reversePageBoundaryKey,
        physics: pagePhysics,
        simulationPage: true,
      );
    }

    return ListenableBuilder(
      listenable: _pageTurnPose,
      builder: (context, _) {
        final offset = _pageDragOffsetNotifier.value;
        return switch (_pageTurnEffect) {
          SimulationPageTurnEffect.simulation => CurlBookTurnPages(
            width: width,
            height: height,
            dragOffset: offset,
            curlLift: _pageCurlLiftNotifier.value,
            curlCorner: _pageCurlCorner,
            currentPage: currentPage,
            previousPage: previousPage,
            nextPage: nextPage,
            keepAlivePreviousPage: previousBoundaryPage,
            keepAliveNextPage: nextBoundaryPage,
            paperBackPage: paperBackPage,
            themeColors: themeColors,
            pageTurnSnapshot: _pageTurnSnapshot,
            reversePageTurnSnapshot: _reversePageTurnSnapshot,
          ),
          SimulationPageTurnEffect.smooth => SmoothTurnPages(
            width: width,
            dragOffset: offset,
            currentPage: currentPage,
            previousPage: previousPage,
            nextPage: nextPage,
            keepAlivePreviousPage: previousBoundaryPage,
            keepAliveNextPage: nextBoundaryPage,
          ),
        };
      },
    );
  }

  double _simulationChapterContentExtent({
    required Chapter chapter,
    required List<String> paragraphs,
    required List<EpubContentBlock> richBlocks,
    required double contentWidth,
  }) => _chapterExtents(
    chapter: chapter,
    paragraphs: paragraphs,
    richBlocks: richBlocks,
    contentWidth: contentWidth,
    mode: ReaderReadingMode.simulation,
  ).total;

  List<double> _continuousBodyExtents({
    required Chapter chapter,
    required List<String> paragraphs,
    required List<EpubContentBlock> richBlocks,
    required double contentWidth,
  }) => _chapterExtents(
    chapter: chapter,
    paragraphs: paragraphs,
    richBlocks: richBlocks,
    contentWidth: contentWidth,
    mode: ReaderReadingMode.continuous,
  ).items;

  ChapterItemExtents _chapterExtents({
    required Chapter chapter,
    required List<String> paragraphs,
    required List<EpubContentBlock> richBlocks,
    required double contentWidth,
    required ReaderReadingMode mode,
  }) {
    return _layoutCache.chapterExtents(
      chapter,
      SimulationLayoutSignature(
        contentWidth: contentWidth,
        settings: _settings,
        mode: mode,
        locale: _readerLocale,
      ),
      () => _measureChapterExtents(
        chapter: chapter,
        paragraphs: paragraphs,
        richBlocks: richBlocks,
        contentWidth: contentWidth,
        mode: mode,
      ),
    );
  }

  /// Measures every item's extent for the target [mode].
  /// In [ReaderReadingMode.continuous], items represent body items only so the
  /// standalone title height can vary independently when anchored vs scrolled.
  ChapterItemExtents _measureChapterExtents({
    required Chapter chapter,
    required List<String> paragraphs,
    required List<EpubContentBlock> richBlocks,
    required double contentWidth,
    required ReaderReadingMode mode,
  }) {
    final simulation = mode == ReaderReadingMode.simulation;
    final continuous = mode == ReaderReadingMode.continuous;
    final items = <double>[];
    var titleTotal = 0.0;
    if (!continuous && !_epubLayout.hasEmbeddedHeading(chapter)) {
      if (simulation) {
        titleTotal = _bodyStartOffset(
          chapter,
          settings: _settings,
          mode: mode,
          width: contentWidth,
        );
        items.add(titleTotal);
      } else {
        final titlePainter = TextPainter(
          text: TextSpan(
            text: _epubLayout.formatChapterTitle(chapter.title),
            style: TextStyle(
              fontFamily: _settings.effectiveFontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          textDirection: TextDirection.ltr,
          textScaler: _readerTextScaler,
          locale: _readerLocale,
        )..layout(maxWidth: contentWidth);
        try {
          titleTotal = titlePainter.height + AppSpacing.xl;
          items.add(titleTotal);
        } finally {
          titlePainter.dispose();
        }
      }
    }
    var bodyExtent = 0.0;
    if (chapter.hasRichEpubContent) {
      final extents = _epubLayout.blockExtents(
        richBlocks,
        settings: _settings,
        mode: mode,
        width: contentWidth,
      );
      for (final extent in extents) {
        items.add(extent);
        bodyExtent += extent;
      }
    } else {
      final lineExtent = simulation
          ? _resolvedSimulationLineExtent(_settings)
          : _settings.fontSize * _settings.lineHeight;
      final paragraphGap =
          _settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
          ? lineExtent
          : 0.0;
      final bodyStyle = TextStyle(
        fontFamily: _settings.effectiveFontFamily,
        fontSize: _settings.fontSize,
        fontWeight: _settings.effectiveFontWeight,
        height: _settings.lineHeight,
        letterSpacing: 0.2,
      );
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: _readerTextScaler,
        locale: _readerLocale,
        strutStyle: simulation
            ? StrutStyle(
                fontFamily: _settings.effectiveFontFamily,
                fontSize: _settings.fontSize,
                height: _settings.lineHeight,
                fontWeight: _settings.effectiveFontWeight,
                forceStrutHeight: true,
              )
            : null,
      );
      try {
        for (var index = 0; index < paragraphs.length; index++) {
          painter.text = TextSpan(text: paragraphs[index], style: bodyStyle);
          painter.layout(maxWidth: contentWidth);
          var extent = simulation
              ? painter.computeLineMetrics().length * lineExtent
              : painter.height;
          if (index < paragraphs.length - 1) extent += paragraphGap;
          items.add(extent);
          bodyExtent += extent;
        }
      } finally {
        painter.dispose();
      }
    }
    if (!continuous) {
      final tailExtent = simulation ? 0.0 : AppSpacing.xxl;
      items.add(tailExtent);
      bodyExtent += tailExtent;
    }
    return ChapterItemExtents(items: items, total: titleTotal + bodyExtent);
  }

  Widget _buildChapterPage({
    required Chapter chapter,
    required ReaderThemeColors themeColors,
    required String? fontFamily,
    required EdgeInsets viewPadding,
    required double horizontalPadding,
    ScrollController? controller,
    Key? repaintBoundaryKey,
    ScrollPhysics? physics,
    bool simulationPage = false,
  }) {
    final paragraphs = _paragraphsFor(chapter);
    final richBlocks = chapter.hasRichEpubContent
        ? chapter.epubBlocks
        : const <EpubContentBlock>[];
    final contentWidth = math.max(
      1.0,
      _readerViewportWidth - horizontalPadding * 2,
    );
    final lineExtent = simulationPage
        ? _resolvedSimulationLineExtent(_settings)
        : _settings.fontSize * _settings.lineHeight;
    final paragraphGap =
        _settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? lineExtent
        : 0.0;
    final bodyItemCount = chapter.hasRichEpubContent
        ? richBlocks.length
        : paragraphs.length;
    final hasStandaloneTitle = !_epubLayout.hasEmbeddedHeading(chapter);
    final simulationTitleExtent = simulationPage && hasStandaloneTitle
        ? _bodyStartOffset(
            chapter,
            settings: _settings,
            mode: ReaderReadingMode.simulation,
            width: contentWidth,
          )
        : 0.0;
    final titleItemCount = hasStandaloneTitle ? 1 : 0;
    final itemCount = bodyItemCount + titleItemCount + 1;
    final scrollViewKey = ValueKey<String>(
      'chapter-${identityHashCode(chapter)}-controller-${identityHashCode(controller)}-${simulationPage ? 'simulation' : 'scroll'}',
    );
    final scrollViewPadding = EdgeInsets.fromLTRB(
      horizontalPadding,
      simulationPage ? 0 : viewPadding.top + AppSpacing.lg,
      horizontalPadding,
      simulationPage ? 0 : viewPadding.bottom + 80,
    );
    final measuredExtents = (simulationPage || bodyItemCount <= 2500)
        ? _chapterExtents(
            chapter: chapter,
            paragraphs: paragraphs,
            richBlocks: richBlocks,
            contentWidth: contentWidth,
            mode: simulationPage
                ? ReaderReadingMode.simulation
                : ReaderReadingMode.chapter,
          )
        : null;
    final itemExtents =
        measuredExtents != null && measuredExtents.items.length == itemCount
        ? measuredExtents.items
        : null;
    final isDarkTheme = themeColors.background.computeLuminance() < 0.35;
    final chapterHasNotes =
        _notesByChapterParagraph[chapter.index]?.isNotEmpty == true;
    final epubBlockParagraphs = chapter.hasRichEpubContent && chapterHasNotes
        ? _epubParagraphIndexByBlock(chapter)
        : null;
    Widget buildItem(BuildContext context, int index) {
      if (hasStandaloneTitle && index == 0) {
        final titleStyle = TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: themeColors.text,
          height: simulationPage ? lineExtent / 20 : 1.5,
        );
        final titleText = Text(
          _epubLayout.formatChapterTitle(chapter.title),
          style: titleStyle,
          strutStyle: simulationPage
              ? StrutStyle(
                  fontFamily: fontFamily,
                  fontSize: 20,
                  height: lineExtent / 20,
                  fontWeight: FontWeight.w600,
                  forceStrutHeight: true,
                )
              : null,
        );
        if (simulationPage) {
          // A fixed-height title item keeps the first body line on the same
          // measured grid as every later page. Do not animate typography in a
          // clipped paper viewport: the final metrics must be used immediately.
          return SizedBox(
            height: simulationTitleExtent,
            width: double.infinity,
            child: Align(alignment: Alignment.topLeft, child: titleText),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          child: titleText,
        );
      }
      if (index == itemCount - 1) {
        return simulationPage
            ? const SizedBox.shrink()
            : const SizedBox(height: AppSpacing.xxl);
      }

      final paragraphIndex = index - titleItemCount;
      if (chapter.hasRichEpubContent) {
        final mappedParagraph =
            epubBlockParagraphs != null &&
                paragraphIndex < epubBlockParagraphs.length
            ? epubBlockParagraphs[paragraphIndex]
            : null;
        return _epubLayout.buildBlock(
          settings: _settings,
          block: richBlocks[paragraphIndex],
          themeColors: themeColors,
          width: contentWidth,
          simulationPage: simulationPage,
          itemExtent: simulationPage && itemExtents != null
              ? itemExtents[index]
              : null,
          noteSpans: mappedParagraph != null
              ? _noteSpansForParagraph(chapter.index, mappedParagraph)
              : const <ReaderNoteHighlightSpan>[],
          noteHighlightRegistry: _noteHighlightRegistry,
        );
      }
      final bodyStyle = TextStyle(
        fontFamily: fontFamily,
        fontSize: _settings.fontSize,
        fontWeight: _settings.effectiveFontWeight,
        shadows: _settings.effectiveFontShadows(themeColors.text),
        height: _settings.lineHeight,
        color: themeColors.text,
        letterSpacing: 0.2,
      );
      final bodyText = ReaderJustifiedText(
        TextSpan(text: paragraphs[paragraphIndex]),
        style: bodyStyle,
        strutStyle: simulationPage
            ? StrutStyle(
                fontFamily: fontFamily,
                fontSize: _settings.fontSize,
                height: _settings.lineHeight,
                fontWeight: _settings.effectiveFontWeight,
                forceStrutHeight: true,
              )
            : null,
      );
      final noteSpans = chapterHasNotes
          ? _noteSpansForParagraph(chapter.index, paragraphIndex)
          : const <ReaderNoteHighlightSpan>[];
      final Widget decoratedBody = noteSpans.isEmpty
          ? bodyText
          : ReaderAnnotatedParagraph(
              spans: noteSpans,
              isDarkTheme: isDarkTheme,
              registry: _noteHighlightRegistry,
              child: bodyText,
            );
      return Padding(
        padding: EdgeInsets.only(
          bottom: paragraphIndex == paragraphs.length - 1 ? 0 : paragraphGap,
        ),
        child: decoratedBody,
      );
    }

    final Widget scrollView;
    if (measuredExtents != null) {
      scrollView = ListView.custom(
        key: scrollViewKey,
        controller: controller,
        primary: false,
        physics: physics,
        scrollCacheExtent: simulationPage
            ? const ScrollCacheExtent.pixels(0)
            : const ScrollCacheExtent.pixels(900),
        padding: scrollViewPadding,
        semanticChildCount: itemCount,
        // Every item's height is measured already, so a list jumping deep into
        // the chapter lays out only the visible page items on frame 1.
        itemExtentBuilder: itemExtents == null
            ? null
            : (index, _) =>
                  index < itemExtents.length ? itemExtents[index] : null,
        childrenDelegate: ExactScrollExtentSliverChildBuilderDelegate(
          (context, index) => ReaderSelectableBlock(
            retainSelection: !simulationPage,
            child: buildItem(context, index),
          ),
          childCount: itemCount,
          exactScrollExtent: measuredExtents.total,
        ),
      );
    } else {
      scrollView = ListView.builder(
        key: scrollViewKey,
        controller: controller,
        primary: false,
        physics: physics,
        scrollCacheExtent: const ScrollCacheExtent.pixels(900),
        padding: scrollViewPadding,
        itemCount: itemCount,
        itemBuilder: (context, index) =>
            ReaderSelectableBlock(child: buildItem(context, index)),
      );
    }

    Widget readingContent = ReaderSelectionArea(
      colors: themeColors,
      selectionBlocked: _selectionController.blocked,
      selectionActive: _selectionController.active,
      selectionDragging: _selectionController.dragging,
      onReaderModalOpened: _beginReaderModal,
      onReaderModalClosed: _endReaderModal,
      onQuickHighlight: _quickHighlightSelection,
      onAddNote: _addNoteForSelection,
      onShareQuoteCard: _shareQuoteCardForSelection,
      edgeScrollController:
          !simulationPage && identical(controller, _scrollController)
          ? controller
          : null,
      edgeScrollEnabled: !_readerModalOpen,
      child: scrollView,
    );
    if (simulationPage) {
      final headerFontSize = (_settings.fontSize * 0.58)
          .clamp(10.0, 13.0)
          .toDouble();
      final headerHeight = headerFontSize * 1.25;
      final minHeaderReserve = AppSpacing.sm + headerHeight + 6.0;
      final selectableContent = readingContent;
      readingContent = LayoutBuilder(
        builder: (context, constraints) {
          final safePageHeight = math.max(
            0.0,
            constraints.maxHeight - viewPadding.top - viewPadding.bottom,
          );
          final maxBodyLineCount = math.max(
            1,
            (safePageHeight / lineExtent).floor(),
          );
          final minimumBodyLineCount = maxBodyLineCount >= 2 ? 2 : 1;
          final availableWithHeader = math.max(
            0.0,
            safePageHeight - math.max(lineExtent * 2, minHeaderReserve * 2),
          );
          final desiredBodyLineCount = (availableWithHeader / lineExtent).floor();
          final bodyLineCount = desiredBodyLineCount.clamp(
            minimumBodyLineCount,
            maxBodyLineCount,
          );
          final bodyHeight = math.min(
            safePageHeight,
            bodyLineCount * lineExtent,
          );
          final effectiveReserve = math.max(
            0.0,
            (safePageHeight - bodyHeight) / 2,
          );
          final showHeader = effectiveReserve >= minHeaderReserve;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                top: viewPadding.top + effectiveReserve,
                bottom: viewPadding.bottom + effectiveReserve,
                child: selectableContent,
              ),
              if (showHeader)
                Positioned(
                  top: viewPadding.top + AppSpacing.sm,
                  left: horizontalPadding,
                  right: horizontalPadding,
                  child: IgnorePointer(
                    child: Text(
                      '章节 ${chapter.index + 1}/${_book.chapters.length} · ${_epubLayout.formatChapterTitle(chapter.title)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: headerFontSize,
                        fontWeight: FontWeight.w400,
                        height: 1.25,
                        letterSpacing: 0.2,
                        color: themeColors.secondary,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }

    return RepaintBoundary(
      key: repaintBoundaryKey,
      child: ColoredBox(
        color: themeColors.background,
        // Keep the reading subtree identical while menus open and close.
        // Reparenting this ListView used to detach its ScrollPosition and
        // recreate it at the controller's initial offset.
        child: readingContent,
      ),
    );
  }
}
