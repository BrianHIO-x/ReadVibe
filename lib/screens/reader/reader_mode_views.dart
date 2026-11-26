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
    _scheduleContinuousMetricsUpdate();
    final isDarkTheme = themeColors.background.computeLuminance() < 0.35;
    final slivers = <Widget>[];
    for (
      var chapterIndex = 0;
      chapterIndex < _book.chapters.length;
      chapterIndex++
    ) {
      final chapter = _book.chapters[chapterIndex];
      final hasNotes = _notesByChapterParagraph[chapterIndex]?.isNotEmpty == true;
      final epubParagraphs = chapter.hasRichEpubContent && hasNotes
          ? _epubParagraphIndexByBlock(chapter)
          : null;
      final hasEmbeddedHeading = _epubLayout.hasEmbeddedHeading(
        chapter,
        avoidLazyLoad: true,
      );
      final chapterTop = chapterIndex == _continuousAnchorChapterIndex
          ? viewPadding.top + AppSpacing.lg
          : AppSpacing.xxl;
      slivers.add(
        SliverMainAxisGroup(
          key: _continuousChapterKeys[chapterIndex],
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
              sliver: SliverList.builder(
                itemCount: chapter.hasRichEpubContent
                    ? (chapter.hasKnownEpubBlockCount
                          ? chapter.epubBlockCount
                          : 1)
                    : 1,
                itemBuilder: (context, itemIndex) => ReaderSelectableBlock(
                  child: Builder(
                    builder: (context) {
                      if (chapter.hasRichEpubContent) {
                        final contentWidth = math.max(
                          1.0,
                          _readerViewportWidth - horizontalPadding * 2,
                        );
                        if (!chapter.hasKnownEpubBlockCount) {
                          final blocks = chapter.epubBlocks;
                          final resolvedMap = hasNotes
                              ? _epubParagraphIndexByBlock(chapter)
                              : null;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var b = 0; b < blocks.length; b++)
                                _epubLayout.buildBlock(
                                  settings: _settings,
                                  block: blocks[b],
                                  themeColors: themeColors,
                                  width: contentWidth,
                                  simulationPage: false,
                                  noteSpans:
                                      resolvedMap != null &&
                                          b < resolvedMap.length &&
                                          resolvedMap[b] != null
                                      ? _noteSpansForParagraph(
                                          chapterIndex,
                                          resolvedMap[b]!,
                                        )
                                      : const <ReaderNoteHighlightSpan>[],
                                  noteHighlightRegistry: _noteHighlightRegistry,
                                ),
                            ],
                          );
                        }
                        final mappedParagraph =
                            epubParagraphs != null &&
                                itemIndex < epubParagraphs.length
                            ? epubParagraphs[itemIndex]
                            : null;
                        return _epubLayout.buildBlock(
                          settings: _settings,
                          block: chapter.epubBlocks[itemIndex],
                          themeColors: themeColors,
                          width: contentWidth,
                          simulationPage: false,
                          noteSpans: mappedParagraph != null
                              ? _noteSpansForParagraph(
                                  chapterIndex,
                                  mappedParagraph,
                                )
                              : const <ReaderNoteHighlightSpan>[],
                          noteHighlightRegistry: _noteHighlightRegistry,
                        );
                      }
                      final separator =
                          _settings.paragraphSpacing ==
                              ReaderParagraphSpacing.blankLine
                          ? '\n\n'
                          : '\n';
                      final paragraphs = _paragraphsFor(chapter);
                      final justified = ReaderJustifiedText(
                        TextSpan(text: paragraphs.join(separator)),
                        style: TextStyle(
                          fontFamily: fontFamily,
                          fontSize: _settings.fontSize,
                          fontWeight: _settings.effectiveFontWeight,
                          shadows: _settings.effectiveFontShadows(
                            themeColors.text,
                          ),
                          height: _settings.lineHeight,
                          color: themeColors.text,
                          letterSpacing: 0.2,
                        ),
                        nearby: (chapterIndex - _chapterIndex).abs() <= 1,
                      );
                      if (!hasNotes) return justified;
                      final spans = _continuousChapterNoteSpans(
                        chapterIndex,
                        paragraphs,
                        separator,
                      );
                      if (spans.isEmpty) return justified;
                      return ReaderAnnotatedParagraph(
                        spans: spans,
                        isDarkTheme: isDarkTheme,
                        registry: _noteHighlightRegistry,
                        child: justified,
                      );
                    },
                  ),
                ),
              ),
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
            key: ValueKey(
              'continuous-$_continuousAnchorChapterIndex-${_settings.fontSize}-${_settings.lineHeight}',
            ),
            controller: _scrollController,
            primary: false,
            center: _continuousChapterKeys[_continuousAnchorChapterIndex],
            scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
            slivers: slivers,
          ),
        ),
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
    Widget? previousBoundaryPage;
    Widget? nextBoundaryPage;
    if (_chapterIndex > 0) {
      previousBoundaryPage = _buildChapterPage(
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
      );
    }
    if (_chapterIndex < _book.chapters.length - 1) {
      nextBoundaryPage = _buildChapterPage(
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
      );
    }

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
  }) => _simulationChapterExtents(
    chapter: chapter,
    paragraphs: paragraphs,
    richBlocks: richBlocks,
    contentWidth: contentWidth,
  ).total;

  ChapterItemExtents _simulationChapterExtents({
    required Chapter chapter,
    required List<String> paragraphs,
    required List<EpubContentBlock> richBlocks,
    required double contentWidth,
  }) {
    return _layoutCache.chapterExtents(
      chapter,
      SimulationLayoutSignature(
        contentWidth: contentWidth,
        settings: _settings,
      ),
      () => _measureSimulationChapterExtents(
        chapter: chapter,
        paragraphs: paragraphs,
        richBlocks: richBlocks,
        contentWidth: contentWidth,
      ),
    );
  }

  /// The page-mode list's items as [_buildChapterPage] lays them out: the
  /// standalone title, each body block with the gap below it, and the empty
  /// closing item.
  ChapterItemExtents _measureSimulationChapterExtents({
    required Chapter chapter,
    required List<String> paragraphs,
    required List<EpubContentBlock> richBlocks,
    required double contentWidth,
  }) {
    final titleExtent = _bodyStartOffset(
      chapter,
      settings: _settings,
      mode: ReaderReadingMode.simulation,
      width: contentWidth,
    );
    final items = <double>[
      if (!_epubLayout.hasEmbeddedHeading(chapter)) titleExtent,
    ];
    var bodyExtent = 0.0;
    if (chapter.hasRichEpubContent) {
      // One painter for the whole body: a fresh one per paragraph spent most
      // of the measurement in setup, and page mode cannot draw its first page
      // until every item is known.
      final extents = _epubLayout.blockExtents(
        richBlocks,
        settings: _settings,
        mode: ReaderReadingMode.simulation,
        width: contentWidth,
      );
      for (final extent in extents) {
        items.add(extent);
        bodyExtent += extent;
      }
    } else {
      final lineExtent = _resolvedSimulationLineExtent(_settings);
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
        strutStyle: StrutStyle(
          fontFamily: _settings.effectiveFontFamily,
          fontSize: _settings.fontSize,
          height: _settings.lineHeight,
          fontWeight: _settings.effectiveFontWeight,
          forceStrutHeight: true,
        ),
      );
      try {
        for (var index = 0; index < paragraphs.length; index++) {
          painter.text = TextSpan(text: paragraphs[index], style: bodyStyle);
          painter.layout(maxWidth: contentWidth);
          var extent = painter.computeLineMetrics().length * lineExtent;
          if (index < paragraphs.length - 1) extent += paragraphGap;
          items.add(extent);
          bodyExtent += extent;
        }
      } finally {
        painter.dispose();
      }
    }
    items.add(0);
    return ChapterItemExtents(items: items, total: titleExtent + bodyExtent);
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
    // Page mode measures its items before building them. The body builder can
    // reuse those heights, so a visible paragraph is not laid out once to size
    // its slot and again to draw itself.
    final simulationExtents = simulationPage
        ? _simulationChapterExtents(
            chapter: chapter,
            paragraphs: paragraphs,
            richBlocks: richBlocks,
            contentWidth: contentWidth,
          )
        : null;
    final itemExtents =
        simulationExtents != null && simulationExtents.items.length == itemCount
        ? simulationExtents.items
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
          style: simulationPage ? titleStyle : null,
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
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            style: titleStyle,
            child: titleText,
          ),
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
          itemExtent: itemExtents?[index],
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
        style: simulationPage ? bodyStyle : null,
        strutStyle: simulationPage
            ? StrutStyle(
                fontFamily: fontFamily,
                fontSize: _settings.fontSize,
                height: _settings.lineHeight,
                fontWeight: _settings.effectiveFontWeight,
                forceStrutHeight: true,
              )
            : null,
        settledStyle: simulationPage ? null : bodyStyle,
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
        child: simulationPage
            ? decoratedBody
            : AnimatedDefaultTextStyle(
                duration: AppMotion.normal,
                curve: AppMotion.standard,
                style: bodyStyle,
                child: decoratedBody,
              ),
      );
    }

    final Widget scrollView;
    if (simulationPage) {
      final extents = simulationExtents!;
      scrollView = ListView.custom(
        key: scrollViewKey,
        controller: controller,
        primary: false,
        physics: physics,
        scrollCacheExtent: const ScrollCacheExtent.pixels(0),
        padding: scrollViewPadding,
        semanticChildCount: itemCount,
        // Every item's height is measured already, so a list born at a page
        // deep in the chapter lays out only the items on that page.
        itemExtentBuilder: itemExtents == null
            ? null
            : (index, _) =>
                  index < itemExtents.length ? itemExtents[index] : null,
        childrenDelegate: ExactScrollExtentSliverChildBuilderDelegate(
          (context, index) => ReaderSelectableBlock(
            retainSelection: false,
            child: buildItem(context, index),
          ),
          childCount: itemCount,
          exactScrollExtent: extents.total,
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
          final desiredBodyLineCount =
              ((safePageHeight - lineExtent * 2) / lineExtent).floor();
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
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                top: viewPadding.top + effectiveReserve,
                bottom: viewPadding.bottom + effectiveReserve,
                child: selectableContent,
              ),
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
