part of '../reader_screen.dart';

extension _ReaderScreenOverlayBars on _ReaderScreenState {
  void _toggleOverlay() {
    if (_pageDragOffset != 0) return;
    _discardPageTurnSnapshot();
    final expectedChapter = _chapterIndex;
    final controller = _scrollController;
    final controllerOffset = controller.hasClients ? controller.offset : 0.0;
    final snapshot = _currentScrollSnapshot();
    final progress = _recordCurrentChapterPosition(snapshot);
    _saveTimer?.cancel();
    _enqueueProgressSave(progress);
    final serial = ++_overlayToggleSerial;
    final willShow = !_showOverlay;
    // Measured before the bars slide in, so they arrive already fitted to the
    // page. Hiding keeps the current fit for the slide out.
    final textGaps = willShow ? _measureChromeTextGaps() : null;
    // Update _showOverlay first: _hideStatusBarForReader refuses to run while
    // the chrome is visible, so the state must already reflect the toggle.
    _setReaderState(() {
      _showOverlay = willShow;
      if (textGaps != null) {
        _headerTextGap = textGaps.header;
        _footerTextGap = textGaps.footer;
      }
    });
    if (willShow) {
      _refreshCurrentBookmarkState();
      _showStatusBar();
    } else {
      _hideStatusBarForReader();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          serial != _overlayToggleSerial ||
          expectedChapter != _chapterIndex ||
          !identical(controller, _scrollController) ||
          !controller.hasClients ||
          !controller.position.hasContentDimensions) {
        return;
      }
      final position = controller.position;
      final target =
          (_settings.readingMode == ReaderReadingMode.continuous
                  ? controllerOffset
                  : snapshot.offset)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      if ((controller.offset - target).abs() > 0.5) {
        controller.jumpTo(target);
      }
      if (_settings.readingMode != ReaderReadingMode.continuous) {
        final maxExtent = position.maxScrollExtent;
        _lastScrollSnapshot = ScrollSnapshot(
          offset: target,
          progress: maxExtent > 0 ? target / maxExtent : 0,
        );
      }
      _scheduleSimulationSnapshotWarmup();
    });
  }

  void _scheduleChromeAlignment() {
    if (_chromeAlignmentScheduled) return;
    _chromeAlignmentScheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _chromeAlignmentScheduled = false;
        _alignChromeToText();
      })
      ..ensureVisualUpdate();
  }

  void _alignChromeToText() {
    if (!mounted || !_showOverlay) return;
    final controller = _scrollController;
    // Bars that followed a moving page would jump line by line. The scroll
    // end notification measures again once the text comes to rest.
    if (controller.hasClients &&
        controller.positions.any(
          (position) => position.isScrollingNotifier.value,
        )) {
      return;
    }
    final gaps = _measureChromeTextGaps();
    if (gaps == null) return;
    if ((gaps.header - _headerTextGap).abs() < 0.5 &&
        (gaps.footer - _footerTextGap).abs() < 0.5) {
      return;
    }
    _setReaderState(() {
      _headerTextGap = gaps.header;
      _footerTextGap = gaps.footer;
    });
  }

  /// How far each bar must reach past its content so that its inner edge
  /// lands on a line boundary. Only lines the reader can currently see count.
  ({double header, double footer})? _measureChromeTextGaps() {
    final stack = _readerStackKey.currentContext?.findRenderObject();
    final surface = _readingSurfaceKey.currentContext?.findRenderObject();
    final headerRow = _headerRowKey.currentContext?.findRenderObject();
    final footerRow = _footerRowKey.currentContext?.findRenderObject();
    if (stack is! RenderBox ||
        surface is! RenderBox ||
        headerRow is! RenderBox ||
        footerRow is! RenderBox ||
        !stack.hasSize ||
        !surface.hasSize ||
        !headerRow.hasSize ||
        !footerRow.hasSize) {
      return null;
    }
    final headerEdge =
        _headerChromeInset + headerRow.size.height + _readerChromeBorder;
    final footerEdge =
        stack.size.height -
        _footerChromeInset -
        footerRow.size.height -
        _readerChromeBorder;
    var header = 0.0;
    var footer = 0.0;

    void visit(RenderObject node, Rect clip) {
      if (node is RenderOffstage && node.offstage) return;
      if (node is! RenderBox) {
        node.visitChildren((child) => visit(child, clip));
        return;
      }
      if (!node.hasSize) return;
      final bounds = MatrixUtils.transformRect(
        node.getTransformTo(stack),
        Offset.zero & node.size,
      );
      final visible = clip.intersect(bounds);
      // Pages parked beside the current one during a turn stay off screen.
      if (visible.width <= 0 || visible.height <= 0) return;
      if (node is RenderParagraph) {
        header = math.max(
          header,
          _lineOverhang(node, bounds.top, visible, headerEdge, below: true),
        );
        footer = math.max(
          footer,
          _lineOverhang(node, bounds.top, visible, footerEdge, below: false),
        );
        return;
      }
      final childClip = node is RenderAbstractViewport ? visible : clip;
      node.visitChildren((child) => visit(child, childClip));
    }

    visit(
      surface,
      MatrixUtils.transformRect(
        surface.getTransformTo(stack),
        Offset.zero & surface.size,
      ),
    );
    return (header: header, footer: footer);
  }

  /// The distance from [edge] to the far side of the line it cuts through,
  /// measured into the text the bar covers.
  double _lineOverhang(
    RenderParagraph paragraph,
    double top,
    Rect visible,
    double edge, {
    required bool below,
  }) {
    if (edge <= visible.top || edge >= visible.bottom) return 0;
    final position = paragraph.getPositionForOffset(Offset(0, edge - top));
    final length = paragraph.text
        .toPlainText(includeSemanticsLabels: false)
        .length;
    // Simulation pages force every line onto the strut; the spacing styles
    // would shrink those boxes to the glyphs and miss the leading.
    final boxHeightStyle = paragraph.strutStyle?.forceStrutHeight == true
        ? ui.BoxHeightStyle.strut
        : ui.BoxHeightStyle.includeLineSpacingMiddle;
    for (final start in [position.offset, position.offset - 1]) {
      if (start < 0 || start >= length) continue;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 1),
        boxHeightStyle: boxHeightStyle,
      );
      for (final box in boxes) {
        final lineTop = math.max(box.top + top, visible.top);
        final lineBottom = math.min(box.bottom + top, visible.bottom);
        if (lineTop < edge - 0.5 && edge + 0.5 < lineBottom) {
          return below ? lineBottom - edge : edge - lineTop;
        }
      }
    }
    return 0;
  }

  Widget _buildReaderHeaderBar({
    required ReaderThemeColors themeColors,
    required double stableTopInset,
    required EdgeInsets contentInsets,
  }) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_showOverlay,
        child: ExcludeSemantics(
          excluding: !_showOverlay,
          child: AnimatedSlide(
            offset: _showOverlay ? Offset.zero : const Offset(0, -1),
            duration: AppMotion.menu,
            curve: AppMotion.standard,
            child: AnimatedOpacity(
              opacity: _showOverlay ? 1.0 : 0.0,
              duration: AppMotion.menu,
              curve: AppMotion.gentle,
              child: AnimatedContainer(
                duration: AppMotion.normal,
                curve: AppMotion.standard,
                padding: EdgeInsets.only(
                  top: stableTopInset,
                  left: contentInsets.left,
                  right: contentInsets.right,
                ),
                decoration: BoxDecoration(
                  color: themeColors.headerBg,
                  border: Border(
                    bottom: BorderSide(
                      color: themeColors.border,
                      width: _readerChromeBorder,
                    ),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      key: _headerRowKey,
                      children: [
                        IconButton(
                          onPressed: _closeReader,
                          tooltip: '返回',
                          icon: Icon(
                            Icons.arrow_back_ios,
                            color: themeColors.secondary,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '当前章节 ${_chapterIndex + 1}/${_book.chapters.length}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: themeColors.secondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _epubLayout.formatChapterTitle(
                                  _currentChapter.title,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: themeColors.text,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                        // Same 48 dp the back button occupies, so the
                        // centered chapter title keeps its position.
                        IconButton(
                          onPressed: _toggleBookmark,
                          tooltip: _currentPositionBookmarked
                              ? '删除此处书签'
                              : '在此处添加书签',
                          icon: Icon(
                            _currentPositionBookmarked
                                ? Icons.bookmark_rounded
                                : Icons.bookmark_border_rounded,
                            color: _currentPositionBookmarked
                                ? themeColors.accent
                                : themeColors.secondary,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: _headerTextGap),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReaderBottomBar({
    required ReaderThemeColors themeColors,
    required EdgeInsets viewPadding,
    required EdgeInsets contentInsets,
  }) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_showOverlay,
        child: ExcludeSemantics(
          excluding: !_showOverlay,
          child: AnimatedSlide(
            offset: _showOverlay ? Offset.zero : const Offset(0, 1),
            duration: AppMotion.menu,
            curve: AppMotion.standard,
            child: AnimatedOpacity(
              opacity: _showOverlay ? 1.0 : 0.0,
              duration: AppMotion.menu,
              curve: AppMotion.gentle,
              child: AnimatedContainer(
                duration: AppMotion.normal,
                curve: AppMotion.standard,
                padding: EdgeInsets.only(
                  bottom: viewPadding.bottom,
                  top: AppSpacing.sm,
                  left: AppSpacing.xl + contentInsets.left,
                  right: AppSpacing.xl + contentInsets.right,
                ),
                decoration: BoxDecoration(
                  color: themeColors.headerBg,
                  border: Border(
                    top: BorderSide(
                      color: themeColors.border,
                      width: _readerChromeBorder,
                    ),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: _footerTextGap),
                    Row(
                      key: _footerRowKey,
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _bottomBarButton(
                          icon: Icons.list,
                          label: '目录',
                          subtitle:
                              '${_chapterIndex + 1}/${_book.chapters.length}',
                          onTap: _showChapterList,
                          color: themeColors.secondary,
                        ),
                        _bottomBarButton(
                          icon: Icons.search_rounded,
                          label: '搜索',
                          subtitle: '全文',
                          onTap: _showSearch,
                          color: themeColors.secondary,
                        ),
                        _bottomBarButton(
                          icon: Icons.bookmarks_outlined,
                          label: '书签',
                          subtitle: _bookmarks.isEmpty
                              ? '未添加'
                              : '${_bookmarks.length}',
                          onTap: _showBookmarks,
                          color: themeColors.secondary,
                        ),
                        if (_settings.readingMode == ReaderReadingMode.chapter)
                          _bottomBarButton(
                            icon: Icons.edit_note_rounded,
                            label: '编辑',
                            subtitle: '当前章',
                            onTap: _showChapterEditor,
                            color: themeColors.secondary,
                          ),
                        _bottomBarButton(
                          icon: Icons.text_fields,
                          label: '设置',
                          subtitle: '${_settings.fontSize.toInt()}pt',
                          onTap: _showSettings,
                          color: themeColors.secondary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBarButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
    required Color color,
  }) {
    return Semantics(
      button: true,
      label: '$label $subtitle',
      onTap: onTap,
      child: PressableScale(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 2,
              horizontal: AppSpacing.md,
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.7),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
