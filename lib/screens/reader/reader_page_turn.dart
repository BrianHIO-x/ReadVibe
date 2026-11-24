part of '../reader_screen.dart';

/// How quickly a released leaf closes on its resting place, in travels per
/// second. Critically damped at this rate it lands in about the time the
/// old fixed settle took.
const double _pageSettleRate = 28;

double _rubberBand(double travel, double width) {
  if (travel == 0 || width <= 0) return 0;
  final limit = width * 0.12;
  return travel.sign * limit * (1 - 1 / (travel.abs() * 0.2 / limit + 1));
}

extension _ReaderScreenPageTurn on _ReaderScreenState {
  void _holdPageMotion() {
    if (_pageDragOffsetNotifier.value == 0) {
      MotionService.release(_pageMotion);
    } else {
      MotionService.hold(_pageMotion);
    }
  }

  /// Battery saver swaps the curl for a slide, so the turn being drawn must
  /// start over in the new effect.
  void _handlePowerSaveModeChanged() {
    if (!mounted) return;
    if (_pageDragOffset != 0 ||
        _pageTurnController.isAnimating ||
        _simulationPageTarget != null) {
      _resetPageDrag();
    } else {
      _discardPageTurnSnapshot();
      _discardReversePageTurnSnapshot();
      _setReaderState(() {});
      _scheduleSimulationSnapshotWarmup();
    }
  }

  void _setPageDragOffset(double value) {
    // A page lying flat has no lifted corner.
    if (value == 0) _pageCurlLiftNotifier.value = 0;
    if (_pageDragOffset == value) return;
    _pageDragOffset = value;
    _pageDragOffsetNotifier.value = value;
  }

  Future<bool> _capturePageTurnSnapshot() {
    if (!mounted ||
        _readerModalOpen ||
        _selectionController.active.value ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _pageTurnEffect != SimulationPageTurnEffect.simulation) {
      return Future<bool>.value(false);
    }
    if (_pageTurnSnapshot != null) return Future<bool>.value(true);
    final existing = _pageTurnSnapshotCapture;
    if (existing != null) return existing;

    final serial = ++_pageTurnSnapshotSerial;
    final chapterIndex = _chapterIndex;
    late final Future<bool> operation;
    operation = _performPageTurnSnapshotCapture(serial, chapterIndex)
        .whenComplete(() {
          if (identical(_pageTurnSnapshotCapture, operation)) {
            _pageTurnSnapshotCapture = null;
          }
        });
    _pageTurnSnapshotCapture = operation;
    return operation;
  }

  Future<bool> _performPageTurnSnapshotCapture(
    int serial,
    int chapterIndex,
  ) async {
    try {
      final pixelRatio = math.min(MediaQuery.devicePixelRatioOf(context), 1.5);
      RenderRepaintBoundary? boundary;
      // A setting or menu rebuild may leave the repaint boundary dirty for one
      // frame. Wait for paint instead of permanently blocking every drag.
      for (var attempt = 0; attempt < 8; attempt++) {
        if (!mounted ||
            _readerModalOpen ||
            _selectionController.active.value ||
            serial != _pageTurnSnapshotSerial ||
            chapterIndex != _chapterIndex ||
            _settings.readingMode != ReaderReadingMode.simulation ||
            _pageTurnEffect != SimulationPageTurnEffect.simulation) {
          return false;
        }
        final renderObject = _currentPageBoundaryKey.currentContext
            ?.findRenderObject();
        if (renderObject is RenderRepaintBoundary &&
            !renderObject.debugNeedsPaint) {
          boundary = renderObject;
          break;
        }
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
      if (boundary == null) return false;

      final image = await boundary.toImage(pixelRatio: pixelRatio);
      if (!mounted ||
          _readerModalOpen ||
          _selectionController.active.value ||
          serial != _pageTurnSnapshotSerial ||
          chapterIndex != _chapterIndex ||
          _settings.readingMode != ReaderReadingMode.simulation ||
          _pageTurnEffect != SimulationPageTurnEffect.simulation) {
        image.dispose();
        return false;
      }

      final previousImage = _pageTurnSnapshot;
      _pageTurnSnapshot = image;
      previousImage?.dispose();
      // Rebuild at the same drag offset so the newly captured mirror appears
      // on the active simulated paper back without restarting the gesture.
      _setReaderState(() {});
      return true;
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to capture the visible page for book turn: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  void _discardPageTurnSnapshot() {
    _pageTurnSnapshotSerial++;
    _pageTurnSnapshotCapture = null;
    final image = _pageTurnSnapshot;
    _pageTurnSnapshot = null;
    image?.dispose();
  }

  void _scheduleReversePageTurnSnapshotCapture(SimulationPageTarget target) {
    if (_readerModalOpen ||
        _selectionController.active.value ||
        target.goingNext ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _pageTurnEffect != SimulationPageTurnEffect.simulation) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _readerModalOpen) return;
      final currentTarget = _simulationPageTarget;
      if (currentTarget == null ||
          currentTarget.goingNext ||
          !currentTarget.matches(target)) {
        return;
      }
      unawaited(_captureReversePageTurnSnapshot(target));
    });
  }

  Future<bool> _captureReversePageTurnSnapshot(SimulationPageTarget target) {
    if (!mounted ||
        _readerModalOpen ||
        _selectionController.active.value ||
        target.goingNext) {
      return Future<bool>.value(false);
    }
    final currentTarget = _simulationPageTarget;
    if (currentTarget == null || !currentTarget.matches(target)) {
      return Future<bool>.value(false);
    }
    if (_reversePageTurnSnapshot != null) return Future<bool>.value(true);
    final existing = _reversePageTurnSnapshotCapture;
    if (existing != null) return existing;

    final serial = ++_reversePageTurnSnapshotSerial;
    late final Future<bool> operation;
    operation = _performReversePageTurnSnapshotCapture(serial, target)
        .whenComplete(() {
          if (identical(_reversePageTurnSnapshotCapture, operation)) {
            _reversePageTurnSnapshotCapture = null;
          }
        });
    _reversePageTurnSnapshotCapture = operation;
    return operation;
  }

  Future<bool> _performReversePageTurnSnapshotCapture(
    int serial,
    SimulationPageTarget target,
  ) async {
    try {
      final pixelRatio = math.min(MediaQuery.devicePixelRatioOf(context), 1.5);
      RenderRepaintBoundary? boundary;
      for (var attempt = 0; attempt < 8; attempt++) {
        final currentTarget = _simulationPageTarget;
        if (!mounted ||
            _readerModalOpen ||
            _selectionController.active.value ||
            serial != _reversePageTurnSnapshotSerial ||
            currentTarget == null ||
            currentTarget.goingNext ||
            !currentTarget.matches(target)) {
          return false;
        }
        final renderObject = _reversePageBoundaryKey.currentContext
            ?.findRenderObject();
        if (renderObject is RenderRepaintBoundary &&
            !renderObject.debugNeedsPaint) {
          boundary = renderObject;
          break;
        }
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
      if (boundary == null) return false;

      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final currentTarget = _simulationPageTarget;
      if (!mounted ||
          _readerModalOpen ||
          _selectionController.active.value ||
          serial != _reversePageTurnSnapshotSerial ||
          currentTarget == null ||
          currentTarget.goingNext ||
          !currentTarget.matches(target)) {
        image.dispose();
        return false;
      }
      final previousImage = _reversePageTurnSnapshot;
      _reversePageTurnSnapshot = image;
      previousImage?.dispose();
      _setReaderState(() {});
      return true;
    } on Object catch (error, stackTrace) {
      debugPrint(
        'Failed to capture the previous page for reverse turn: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  void _discardReversePageTurnSnapshot() {
    _reversePageTurnSnapshotSerial++;
    _reversePageTurnSnapshotCapture = null;
    final image = _reversePageTurnSnapshot;
    _reversePageTurnSnapshot = null;
    image?.dispose();
  }

  void _scheduleSimulationSnapshotWarmup() {
    if (_readerModalOpen ||
        _selectionController.active.value ||
        !_settingsLoaded ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _pageTurnEffect != SimulationPageTurnEffect.simulation ||
        _pageTurnSnapshot != null ||
        _pageTurnSnapshotCapture != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _readerModalOpen ||
          _selectionController.active.value ||
          _settings.readingMode != ReaderReadingMode.simulation ||
          _pageTurnEffect != SimulationPageTurnEffect.simulation ||
          _pageDragOffset != 0 ||
          _pageTurnController.isAnimating ||
          _pageTurnSnapshot != null) {
        return;
      }
      unawaited(_capturePageTurnSnapshot());
    });
  }

  /// Drops the active simulation target and its preview controllers without
  /// touching gesture state. Controllers dispose after the frame so a build
  /// already in flight never hands a dead controller to a ListView.
  void _clearSimulationPageTurnState() {
    final simulationPreview = _simulationPreviewController;
    final simulationPaperBack = _simulationPaperBackController;
    _simulationPreviewController = null;
    _simulationPaperBackController = null;
    _simulationPageTarget = null;
    if (simulationPreview != null || simulationPaperBack != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        simulationPreview?.dispose();
        simulationPaperBack?.dispose();
      });
    }
  }

  void _resetPageDrag({bool rebuild = true}) {
    _clearSimulationTurnPointer();
    _setTextSelectionBlocked(false);
    _clearSimulationPageTurnState();
    _pageTurnController.stop();
    _pageTurnAnimation = null;
    _commitPageTurnWhenSettled = false;
    _pageTurnOriginChapterIndex = null;
    _pageTurnOriginSnapshot = null;
    _pageEdgeStretch = 0;
    _setPageDragOffset(0);
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    if (!mounted) return;
    if (rebuild) {
      _setReaderState(() => _pageDragTargetIndex = null);
    } else {
      _pageDragTargetIndex = null;
    }
    _scheduleSimulationSnapshotWarmup();
  }

  /// Freezes simulation pagination while a reader-owned modal is visible.
  ///
  /// The search route owns the keyboard inset.  Letting that inset reach the
  /// underlying simulation `LayoutBuilder` repaginates the current chapter
  /// while the user is typing, which looks like the page jumps underneath the
  /// sheet and can leave a stale paper-back snapshot behind.
  void _beginReaderModal() {
    if (_readerModalOpen) return;
    _readerModalOpen = true;
    _showStatusBar();
    _simulationViewportLock =
        _settings.readingMode == ReaderReadingMode.simulation &&
            _readerViewportHeight > 0
        ? _readerViewportHeight
        : null;
    _clearReadingTap();
    _clearSimulationTurnPointer();
    _pageTurnSerial++;
    if (_pageTurnController.isAnimating ||
        _pageDragOffset != 0 ||
        _pageDragTargetIndex != null ||
        _simulationPageTarget != null) {
      _resetPageDrag(rebuild: false);
    } else {
      _discardPageTurnSnapshot();
      _discardReversePageTurnSnapshot();
    }
    if (mounted) _setReaderState(() {});
  }

  void _endReaderModal() {
    if (!_readerModalOpen) return;
    _readerModalOpen = false;
    _simulationViewportLock = null;
    if (!mounted) return;
    _setReaderState(() {});
    if (!_showOverlay) _hideStatusBarForReader();
    _scheduleSimulationSnapshotWarmup();
  }

  void _scheduleAdjacentWarmup() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _warmAdjacentPages) return;
      _setReaderState(() => _warmAdjacentPages = true);
    });
  }

  void _queueSettingsApply(ReaderSettings newSettings) {
    widget.onSettingsChanged?.call(newSettings);
    _pendingSettingsApply = newSettings;
    _settingsApplyTimer?.cancel();
    _settingsApplyTimer = Timer(AppMotion.settingApplyDelay, () {
      if (!mounted) return;
      final pending = _pendingSettingsApply;
      _pendingSettingsApply = null;
      _settingsApplyTimer = null;
      if (pending == null) return;
      final snapshot = _currentScrollSnapshot();
      final previousMode = _settings.readingMode;
      final modeChanged = previousMode != pending.readingMode;
      final textLayoutChanged = _changesTextLayout(_settings, pending);
      final textAnchor = textLayoutChanged
          ? _captureReadingTextAnchor(snapshot)
          : null;
      final rebuildsContinuous =
          previousMode == ReaderReadingMode.continuous ||
          pending.readingMode == ReaderReadingMode.continuous;
      final rebuildsSimulation =
          textLayoutChanged &&
          (previousMode == ReaderReadingMode.simulation ||
              pending.readingMode == ReaderReadingMode.simulation);
      final rebuildsReadingController =
          rebuildsContinuous || rebuildsSimulation;
      final progress = _recordCurrentChapterPosition(snapshot);
      _enqueueProgressSave(progress);
      _resetPageDrag(rebuild: false);

      if (rebuildsReadingController) {
        final previousController = _scrollController;
        previousController.removeListener(_scheduleProgressSave);
        // Simulation owns a fixed page grid whose viewport is derived from
        // the current font metrics. Reusing its ScrollPosition across either
        // a mode switch or an in-place typography change makes Flutter
        // reinterpret old pixels against the new grid and can expose a frame
        // whose clipping window and glyph metrics disagree. Build a fresh
        // controller at zero so the new reading subtree starts directly at
        // the final metrics, then restore the captured text anchor after the
        // target layout reports its own dimensions.
        final nextController = _createScrollController(
          rebuildsSimulation ? 0 : snapshot.offset,
          pending.readingMode == ReaderReadingMode.simulation,
        );
        final adjacentControllers = _adjacentScrollControllers.values.toSet();
        _adjacentScrollControllers.clear();
        _adjacentScrollRestoreSerials.clear();
        _continuousAnchorChapterIndex = _chapterIndex;
        _resetContinuousMetrics();
        _setReaderState(() {
          _settings = pending;
          _scrollController = nextController;
          _warmAdjacentPages = false;
          _pageDragTargetIndex = null;
          _readingModeReloading = rebuildsReadingController;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          previousController.dispose();
          for (final controller in adjacentControllers) {
            controller.dispose();
          }
        });
      } else {
        if (modeChanged) {
          final adjacentControllers = _adjacentScrollControllers.values.toSet();
          _adjacentScrollControllers.clear();
          _adjacentScrollRestoreSerials.clear();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            for (final controller in adjacentControllers) {
              controller.dispose();
            }
          });
        }
        _setReaderState(() {
          _settings = pending;
          _warmAdjacentPages = false;
          _pageDragTargetIndex = null;
        });
      }

      if (pending.readingMode == ReaderReadingMode.continuous) {
        _requestContinuousRestore(
          snapshot.progress,
          offset: snapshot.offset,
          textAnchor: textAnchor,
        );
      } else {
        _scheduleAdjacentWarmup();
        _requestScrollRestore(
          offset: snapshot.offset,
          progress: snapshot.progress,
          preferProgress: false,
          textAnchor: textAnchor,
        );
        _scheduleSimulationSnapshotWarmup();
      }
    });
  }

  void _openChapter(int index) {
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _switchContinuousChapter(index, startAtTop: true);
    } else {
      _switchChapter(index, startAtTop: true);
    }
  }

  void _switchContinuousChapter(int index, {required bool startAtTop}) {
    if (index < 0 || index >= _book.chapters.length) return;
    final currentSnapshot = _currentScrollSnapshot();
    var progress = _recordCurrentChapterPosition(currentSnapshot);
    _enqueueProgressSave(progress);
    final targetProgress = startAtTop
        ? 0.0
        : progress.chapterProgress[index] ?? 0.0;
    final targetOffset = startAtTop
        ? 0.0
        : progress.chapterOffsets[index] ?? 0.0;
    progress = progress.recordPosition(
      index,
      targetOffset,
      progress: targetProgress,
    );
    _currentProgress = progress;
    _lastScrollSnapshot = ScrollSnapshot(
      offset: targetOffset,
      progress: targetProgress,
    );

    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController();
    _continuousAnchorChapterIndex = index;
    _resetContinuousMetrics();
    _setReaderState(() {
      _chapterIndex = index;
      _scrollController = nextController;
      _showOverlay = false;
    });
    _hideStatusBarForReader();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
    });
    _enqueueProgressSave(progress);
    _requestContinuousRestore(targetProgress, offset: targetOffset);
  }

  void _switchChapter(int index, {required bool startAtTop}) {
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _switchContinuousChapter(index, startAtTop: startAtTop);
      return;
    }
    if (index < 0 || index >= _book.chapters.length) {
      return;
    }
    if (index == _chapterIndex) {
      // A table-of-contents pick lands here when it names the current chapter.
      // The sheet is already popped; dismiss the reader chrome too so every
      // directory jump returns to the same immersive state as other modes.
      if (_showOverlay) {
        _setReaderState(() => _showOverlay = false);
        _hideStatusBarForReader();
      }
      if (startAtTop && _scrollController.hasClients) {
        _discardPageTurnSnapshot();
        _scrollController.jumpTo(0);
        final progress = _recordCurrentChapterPosition(
          const ScrollSnapshot(offset: 0, progress: 0),
        );
        _enqueueProgressSave(progress);
        _scheduleSimulationSnapshotWarmup();
      }
      return;
    }

    _discardPageTurnSnapshot();
    _saveTimer?.cancel();
    final currentSnapshot =
        _pageTurnOriginChapterIndex == _chapterIndex &&
            _pageTurnOriginSnapshot != null
        ? _pageTurnOriginSnapshot!
        : _currentScrollSnapshot();
    var progress = _recordCurrentChapterPosition(currentSnapshot);
    // Persist the departure chapter before changing any controller or active
    // chapter state. This write is queued ahead of the target-chapter write.
    _enqueueProgressSave(progress);
    _pageTurnOriginChapterIndex = null;
    _pageTurnOriginSnapshot = null;
    // The drag preview is already laid out at the page the user sees under
    // the settling animation. Inherit its exact pixel offset when committing
    // the turn so the page seen during the gesture is the same page that
    // remains after the animation.
    final previewSnapshot = startAtTop
        ? null
        : (_simulationPreviewSnapshot(index) ?? _adjacentScrollSnapshot(index));
    final targetOffset = startAtTop
        ? 0.0
        : previewSnapshot?.offset ?? progress.chapterOffsets[index] ?? 0.0;
    final hasSavedTargetProgress =
        !startAtTop && progress.chapterProgress.containsKey(index);
    final targetProgress =
        previewSnapshot?.progress ??
        (hasSavedTargetProgress ? progress.chapterProgress[index]! : 0.0);
    progress = progress.recordPosition(
      index,
      targetOffset,
      progress: targetProgress,
    );
    _currentProgress = progress;
    _lastScrollSnapshot = ScrollSnapshot(
      offset: targetOffset,
      progress: targetProgress,
    );

    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController(targetOffset);
    final previousAdjacentControllers = _adjacentScrollControllers.values
        .toSet();
    final previousSimulationPreview = _simulationPreviewController;
    final previousSimulationPaperBack = _simulationPaperBackController;
    final overlayWasVisible = _showOverlay;
    _simulationPreviewController = null;
    _simulationPaperBackController = null;
    _simulationPageTarget = null;
    _discardReversePageTurnSnapshot();
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();

    _setReaderState(() {
      _chapterIndex = index;
      _scrollController = nextController;
      _warmAdjacentPages = false;
      _pageDragTargetIndex = null;
      _pageTurnAnimation = null;
      _commitPageTurnWhenSettled = false;
      _simulationPageTarget = null;
      _showOverlay = false;
    });
    // Jumping chapters from the table of contents must return to the same
    // immersive reading state as a gesture-driven page turn.
    if (overlayWasVisible) _hideStatusBarForReader();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
      for (final controller in previousAdjacentControllers) {
        controller.dispose();
      }
      previousSimulationPreview?.dispose();
      previousSimulationPaperBack?.dispose();
    });
    _setPageDragOffset(0);
    _scheduleAdjacentWarmup();
    _enqueueProgressSave(progress);
    _requestScrollRestore(
      offset: targetOffset,
      progress: previewSnapshot == null && hasSavedTargetProgress
          ? targetProgress
          : null,
      preferProgress: previewSnapshot == null && hasSavedTargetProgress,
    );
    _scheduleSimulationSnapshotWarmup();
  }

  void _handleReadingPointerDown(PointerDownEvent event) {
    if (_readingTapPointer != null) return;
    MotionService.hold(_touchMotion);
    _readingTapPointer = event.pointer;
    _readingTapOrigin = event.position;
    _readingTapStartedAt = event.timeStamp;
    _readingTapMoved = false;
    if (_settings.readingMode == ReaderReadingMode.simulation) {
      _simulationTurnPointer = event.pointer;
      _simulationTurnOrigin = event.localPosition;
      _simulationTurnLastPosition = event.localPosition;
      _simulationTurnVelocityTracker = VelocityTracker.withKind(event.kind)
        ..addPosition(event.timeStamp, event.position);
      _simulationTurnActive = false;
      if (_pageTurnEffect == SimulationPageTurnEffect.simulation) {
        unawaited(_capturePageTurnSnapshot());
      }
    }
  }

  void _handleReadingPointerMove(
    PointerMoveEvent event,
    double width,
    double height,
  ) {
    if (_selectionController.active.value) {
      if (event.pointer == _readingTapPointer) _readingTapMoved = true;
      if (event.pointer == _simulationTurnPointer) {
        _clearSimulationTurnPointer();
      }
      return;
    }
    if (event.pointer == _simulationTurnPointer) {
      _simulationTurnVelocityTracker?.addPosition(
        event.timeStamp,
        event.position,
      );
      final origin = _simulationTurnOrigin;
      final lastPosition = _simulationTurnLastPosition;
      if (origin != null && lastPosition != null) {
        final travel = event.localPosition - origin;
        // A curl may be pulled diagonally off a corner. A slide turns only
        // on mostly horizontal drags.
        final steepness = _turnsWithPageCurl ? 0.5 : 1.15;
        if (!_simulationTurnActive &&
            travel.dx.abs() >= 9 &&
            travel.dx.abs() > travel.dy.abs() * steepness) {
          _simulationTurnActive = true;
          _readingTapMoved = true;
          _beginHorizontalPageTurn();
          // Drop the touch-slop dead zone from the first delta. Applying the
          // full travel would teleport the leaf past the slop distance while
          // the finger has effectively not moved yet.
          _simulationTurnAnchor = origin + Offset(9 * travel.dx.sign, 0);
          _pageCurlCorner = origin.dy * 3 < height
              ? PageCurlCorner.top
              : origin.dy * 3 > height * 2
              ? PageCurlCorner.bottom
              : PageCurlCorner.middle;
          if (_turnsWithPageCurl) {
            _updateSimulationCurl(event.localPosition, width, height);
          } else {
            _updateHorizontalPageTurn(
              deltaX: travel.dx - 9 * travel.dx.sign,
              width: width,
            );
          }
        } else if (_simulationTurnActive) {
          _readingTapMoved = true;
          if (_turnsWithPageCurl) {
            _updateSimulationCurl(event.localPosition, width, height);
          } else {
            _updateHorizontalPageTurn(
              deltaX: event.localPosition.dx - lastPosition.dx,
              width: width,
            );
          }
        }
      }
      _simulationTurnLastPosition = event.localPosition;
    }

    if (event.pointer != _readingTapPointer || _readingTapMoved) return;
    final origin = _readingTapOrigin;
    if (origin == null) return;
    if ((event.position - origin).distance >
        _ReaderScreenState._readingTapSlop) {
      _readingTapMoved = true;
    }
  }

  void _handleReadingPointerUp(PointerUpEvent event, double width) {
    if (event.pointer != _readingTapPointer) return;
    MotionService.release(_touchMotion);
    final simulationTurnWasActive =
        event.pointer == _simulationTurnPointer && _simulationTurnActive;
    var simulationVelocity = 0.0;
    if (event.pointer == _simulationTurnPointer) {
      _simulationTurnVelocityTracker?.addPosition(
        event.timeStamp,
        event.position,
      );
      simulationVelocity =
          _simulationTurnVelocityTracker?.getVelocity().pixelsPerSecond.dx ??
          0.0;
      _clearSimulationTurnPointer();
    }
    final startedAt = _readingTapStartedAt;
    final elapsed = startedAt == null
        ? _ReaderScreenState._readingTapTimeout +
              const Duration(milliseconds: 1)
        : event.timeStamp - startedAt;
    final shouldToggle =
        !_readingTapMoved && elapsed <= _ReaderScreenState._readingTapTimeout;
    _clearReadingTap();
    if (simulationTurnWasActive) {
      _endHorizontalPageTurn(simulationVelocity, width);
    } else if (shouldToggle) {
      _toggleOverlay();
    }
  }

  void _handleReadingPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _readingTapPointer) {
      MotionService.release(_touchMotion);
    }
    if (event.pointer == _simulationTurnPointer) {
      final simulationTurnWasActive = _simulationTurnActive;
      _clearSimulationTurnPointer();
      if (simulationTurnWasActive) _handleHorizontalDragCancel();
    }
    if (event.pointer == _readingTapPointer) _clearReadingTap();
  }

  void _clearSimulationTurnPointer() {
    _simulationTurnPointer = null;
    _simulationTurnOrigin = null;
    _simulationTurnAnchor = null;
    _simulationTurnLastPosition = null;
    _simulationTurnVelocityTracker = null;
    _simulationTurnActive = false;
  }

  void _clearReadingTap() {
    _readingTapPointer = null;
    _readingTapOrigin = null;
    _readingTapStartedAt = null;
    _readingTapMoved = false;
  }

  void _handleHorizontalDragStart(DragStartDetails _) {
    if (_selectionController.active.value) return;
    _beginHorizontalPageTurn();
  }

  void _beginHorizontalPageTurn() {
    if (_settings.readingMode == ReaderReadingMode.continuous) return;
    _setTextSelectionBlocked(true);
    if (_pageTurnController.isAnimating) {
      final targetIndex = _pageDragTargetIndex;
      final simulationTarget = _simulationPageTarget;
      final shouldFinish =
          _commitPageTurnWhenSettled &&
          (targetIndex != null || simulationTarget != null) &&
          _pageDragOffset.abs() > 1;
      _pageTurnSerial++;
      _pageTurnController.stop();
      _pageTurnAnimation = null;
      if (shouldFinish) {
        if (_settings.readingMode == ReaderReadingMode.simulation &&
            simulationTarget != null) {
          _finishSimulationPageTurn(simulationTarget);
        } else if (targetIndex != null) {
          _finishPageTurn(targetIndex);
        }
        return;
      }
      // A fresh gesture grabbed the page mid-settle without finishing it.
      // The stopped animation left _pageDragOffset partway through its
      // travel; accumulating the new drag on that leftover snaps the leaf.
      // Restart from the resting page instead. Pointer tracking belongs to
      // the new gesture and must survive this reset.
      _commitPageTurnWhenSettled = false;
      _pageDragTargetIndex = null;
      _clearSimulationPageTurnState();
      _setPageDragOffset(0);
    }
    _pageTurnController.stop();
    _pageTurnAnimation = null;
    _pageEdgeStretch = 0;
    if (_settings.readingMode == ReaderReadingMode.simulation &&
        _pageTurnEffect == SimulationPageTurnEffect.simulation &&
        _pageTurnSnapshot == null) {
      unawaited(_capturePageTurnSnapshot());
    }
    final snapshot = _currentScrollSnapshot();
    _pageTurnOriginChapterIndex = _chapterIndex;
    _pageTurnOriginSnapshot = snapshot;
    _saveTimer?.cancel();
    _enqueueProgressSave(_recordCurrentChapterPosition(snapshot));
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details, double width) {
    if (_selectionController.active.value) return;
    _updateHorizontalPageTurn(deltaX: details.delta.dx, width: width);
  }

  void _updateHorizontalPageTurn({
    required double deltaX,
    required double width,
  }) {
    if (width <= 0 || _settings.readingMode == ReaderReadingMode.continuous) {
      return;
    }
    if (_settings.readingMode == ReaderReadingMode.simulation &&
        _pageTurnEffect == SimulationPageTurnEffect.simulation &&
        _pageTurnSnapshot == null) {
      unawaited(_capturePageTurnSnapshot());
    }
    // Past the book's ends the leaf shows less than the finger has moved, so
    // the next step continues from the finger's own travel.
    final base = _pageEdgeStretch != 0 ? _pageEdgeStretch : _pageDragOffset;
    final proposed = (base + deltaX).clamp(-width, width);

    if (_settings.readingMode == ReaderReadingMode.simulation) {
      final offset = _resolveSimulationDrag(proposed, width);
      if (offset != null) _setPageDragOffset(offset);
      return;
    }

    final targetIndex = _pageDragTargetIndex ?? _targetIndexForOffset(proposed);
    if (targetIndex == null) {
      _stretchPastBookEdge(proposed, width);
      return;
    }
    _pageEdgeStretch = 0;

    final goingNext = targetIndex > _chapterIndex;
    if (_pageDragTargetIndex != targetIndex || _showOverlay) {
      _setReaderState(() {
        _showOverlay = false;
        _pageDragTargetIndex = targetIndex;
      });
      // When a horizontal swipe dismisses the overlay, restore the immersive
      // reading state immediately so the status bar doesn't linger open.
      _hideStatusBarForReader();
    }
    _setPageDragOffset(
      goingNext ? proposed.clamp(-width, 0.0) : proposed.clamp(0.0, width),
    );
  }

  bool get _turnsWithPageCurl =>
      _settings.readingMode == ReaderReadingMode.simulation &&
      _pageTurnEffect == SimulationPageTurnEffect.simulation;

  /// The turn effect actually drawn. Battery saver swaps the curl for a
  /// slide, which paints far less on every frame of a turn.
  SimulationPageTurnEffect get _pageTurnEffect =>
      MotionService.powerSaveMode.value
      ? SimulationPageTurnEffect.smooth
      : _settings.simulationPageTurnEffect;

  /// Picks the page a simulation drag of [proposed] reveals and returns the
  /// offset the leaf should take. Returns null at the book's ends, where the
  /// drag only rubber-bands.
  double? _resolveSimulationDrag(double proposed, double width) {
    final goingNext = proposed < 0;
    final target = proposed == 0
        ? null
        : _simulationTargetForDirection(goingNext: goingNext);
    if (target == null) {
      _replaceSimulationPageTarget(null);
      _stretchPastBookEdge(proposed, width);
      return null;
    }
    _pageEdgeStretch = 0;
    _replaceSimulationPageTarget(target, hideOverlay: true);
    return goingNext
        ? proposed.clamp(-width, 0.0).toDouble()
        : proposed.clamp(0.0, width).toDouble();
  }

  /// Shows a drag of [travel] past the book's first or last page.
  ///
  /// The leaf follows a fifth of the finger at first and stiffens the
  /// further it is pulled, closing on about an eighth of the page width, so
  /// the end of the book answers with resistance instead of a wall.
  void _stretchPastBookEdge(double travel, double width) {
    _pageEdgeStretch = travel;
    _setPageDragOffset(_rubberBand(travel, width));
  }

  /// Moves a curling leaf with the finger at [position], in the reading
  /// surface's coordinates.
  void _updateSimulationCurl(Offset position, double width, double height) {
    final anchor = _simulationTurnAnchor;
    if (anchor == null || width <= 0 || height <= 0) return;
    if (_pageTurnSnapshot == null) unawaited(_capturePageTurnSnapshot());
    final proposed = (position.dx - anchor.dx).clamp(-width, width).toDouble();
    final resolved = _resolveSimulationDrag(proposed, width);
    if (resolved == null || resolved >= 0) {
      // Backward turns bring the previous leaf back on an upright fold.
      _pageCurlLiftNotifier.value = 0;
      if (resolved != null) _setPageDragOffset(resolved);
      return;
    }
    final inset = _readerViewPadding.left;
    // The corner leaves its edge at twice the finger's pace. Once it has
    // caught up with the finger it stays under it.
    final offset = math
        .max(resolved, (position.dx - inset - width) / 2)
        .clamp(-width, 0.0)
        .toDouble();
    var lift = 0.0;
    final corner = _pageCurlCorner;
    if (corner != PageCurlCorner.middle) {
      final cornerY = corner == PageCurlCorner.top ? 0.0 : height;
      final gap = width - (anchor.dx - inset);
      // Vertical movement carries over from the start. The corner's height
      // converges on the finger as the corner closes the horizontal gap.
      final attached = gap <= 1
          ? 1.0
          : (-resolved / gap).clamp(0.0, 1.0).toDouble();
      lift = PageCurlGeometry.constrainLift(
        position.dy - anchor.dy + (anchor.dy - cornerY) * attached,
        corner: corner,
        travel: -2 * offset,
        size: Size(width, height),
      );
    }
    _pageCurlLiftNotifier.value = lift;
    _setPageDragOffset(offset);
  }

  int? _targetIndexForOffset(double offset) {
    if (offset < 0 && _chapterIndex < _book.chapters.length - 1) {
      return _chapterIndex + 1;
    }
    if (offset > 0 && _chapterIndex > 0) {
      return _chapterIndex - 1;
    }
    return null;
  }

  SimulationPageTarget? _simulationTargetForDirection({
    required bool goingNext,
  }) {
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return null;
    }
    final position = _scrollController.position;
    final maxExtent = position.maxScrollExtent;
    final currentOffset = _alignSimulationOffset(
      position.pixels.clamp(0.0, maxExtent).toDouble(),
      pageExtent: position.viewportDimension,
      maxExtent: maxExtent,
    );
    final pageExtent = math.max(1.0, position.viewportDimension);

    if (goingNext) {
      if (currentOffset < maxExtent - 1) {
        final targetOffset = _alignSimulationOffset(
          currentOffset + pageExtent,
          pageExtent: pageExtent,
          maxExtent: maxExtent,
        );
        if (targetOffset > currentOffset + 0.5) {
          return SimulationPageTarget(
            chapterIndex: _chapterIndex,
            offset: targetOffset,
            progress: maxExtent > 0 ? targetOffset / maxExtent : 0,
            goingNext: true,
          );
        }
      }
      if (_chapterIndex >= _book.chapters.length - 1) return null;
      final targetIndex = _chapterIndex + 1;
      final preview = _adjacentScrollSnapshot(targetIndex);
      return SimulationPageTarget(
        chapterIndex: targetIndex,
        offset: preview?.offset ?? 0,
        progress: preview?.progress ?? 0,
        goingNext: true,
      );
    }

    if (currentOffset > 1) {
      final targetOffset = _alignSimulationOffset(
        math.max(0.0, currentOffset - pageExtent),
        pageExtent: pageExtent,
        maxExtent: maxExtent,
      );
      return SimulationPageTarget(
        chapterIndex: _chapterIndex,
        offset: targetOffset,
        progress: maxExtent > 0 ? targetOffset / maxExtent : 0,
        goingNext: false,
      );
    }
    if (_chapterIndex <= 0) return null;
    final targetIndex = _chapterIndex - 1;
    final preview = _adjacentScrollSnapshot(targetIndex);
    final lastPage = _simulationLastPageSnapshot(
      targetIndex,
      pageExtent: pageExtent,
    );
    return SimulationPageTarget(
      chapterIndex: targetIndex,
      offset: preview?.offset ?? lastPage.offset,
      progress: preview?.progress ?? lastPage.progress,
      goingNext: false,
    );
  }

  ScrollSnapshot _simulationLastPageSnapshot(
    int chapterIndex, {
    required double pageExtent,
  }) {
    if (chapterIndex < 0 ||
        chapterIndex >= _book.chapters.length ||
        !pageExtent.isFinite ||
        pageExtent <= 0) {
      return const ScrollSnapshot(offset: 0, progress: 0);
    }
    final chapter = _book.chapters[chapterIndex];
    final horizontalPadding = _settings.pageMargin.horizontalPadding;
    final contentWidth = math.max(
      1.0,
      _readerViewportWidth - horizontalPadding * 2,
    );
    final contentExtent = _simulationChapterContentExtent(
      chapter: chapter,
      paragraphs: _paragraphsFor(chapter),
      richBlocks: chapter.hasRichEpubContent
          ? chapter.epubBlocks
          : const <EpubContentBlock>[],
      contentWidth: contentWidth,
    );
    final rawMaxExtent = math.max(0.0, contentExtent - pageExtent);
    final offset = fullViewportMaxScrollExtent(rawMaxExtent, pageExtent);
    return ScrollSnapshot(offset: offset, progress: offset > 0 ? 1 : 0);
  }

  void _replaceSimulationPageTarget(
    SimulationPageTarget? target, {
    bool hideOverlay = false,
  }) {
    final current = _simulationPageTarget;
    if (current == null && target == null) {
      // Rubber-banding at the book edges reaches this on every move event.
      // Without the early return each event discards the reverse snapshot
      // and rebuilds the whole reader for no visible change.
      return;
    }
    final sameTarget =
        current != null && target != null && current.matches(target);
    if (sameTarget && (!hideOverlay || !_showOverlay)) {
      return;
    }

    final previousController = _simulationPreviewController;
    final previousPaperBackController = _simulationPaperBackController;
    ScrollController? nextController;
    ScrollController? nextPaperBackController;
    if (target != null) {
      // Every target page gets a dedicated controller born at the target
      // offset. Sharing the adjacent warm-up controller made the revealed
      // page paint its saved reading position first and then jump to the
      // page edge once the scheduled restore landed mid-drag.
      nextController = FullViewportPagingScrollController(
        initialScrollOffset: target.offset,
      );
    }
    if (target != null &&
        _pageTurnEffect == SimulationPageTurnEffect.simulation) {
      final movingPageOffset = target.goingNext
          ? (_pageTurnOriginSnapshot ?? _currentScrollSnapshot()).offset
          : target.offset;
      nextPaperBackController = FullViewportPagingScrollController(
        initialScrollOffset: math.max(0.0, movingPageOffset),
      );
    }
    _discardReversePageTurnSnapshot();
    _simulationPreviewController = nextController;
    _simulationPaperBackController = nextPaperBackController;
    _setReaderState(() {
      _simulationPageTarget = target;
      if (hideOverlay) _showOverlay = false;
    });
    if (hideOverlay) _hideStatusBarForReader();
    if (target != null && !target.goingNext) {
      _scheduleReversePageTurnSnapshotCapture(target);
    }
    if (previousController != null || previousPaperBackController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousController?.dispose();
        previousPaperBackController?.dispose();
      });
    }
  }

  void _handleHorizontalDragEnd(DragEndDetails details, double width) {
    if (_selectionController.active.value) return;
    _endHorizontalPageTurn(details.primaryVelocity ?? 0, width);
  }

  void _endHorizontalPageTurn(double velocity, double width) {
    if (_settings.readingMode == ReaderReadingMode.continuous) return;
    final targetIndex = _pageDragTargetIndex;
    final simulationTarget = _simulationPageTarget;
    if ((targetIndex == null && simulationTarget == null) || width <= 0) {
      _animatePageDragTo(0, commit: false);
      return;
    }

    final progress = (_pageDragOffset.abs() / width).clamp(0.0, 1.0);
    final goingNext =
        simulationTarget?.goingNext ??
        (targetIndex != null && targetIndex > _chapterIndex);
    // Velocity decides first: a flick along the turn commits it from any
    // distance, and a flick back towards the page puts the leaf down even
    // past the distance threshold, since the reader has changed their mind.
    final towardsTurn = goingNext ? -velocity : velocity;
    final shouldCommit =
        towardsTurn > 260 || (towardsTurn >= -260 && progress > 0.16);
    final endOffset = shouldCommit ? (goingNext ? -width : width) : 0.0;
    _animatePageDragTo(endOffset, commit: shouldCommit, velocity: velocity);
  }

  void _handleHorizontalDragCancel() {
    if (_pageDragOffset == 0 &&
        _pageDragTargetIndex == null &&
        _simulationPageTarget == null) {
      return;
    }
    _animatePageDragTo(0, commit: false);
  }

  void _animatePageDragTo(
    double endOffset, {
    required bool commit,
    double velocity = 0,
  }) {
    final targetIndex = _pageDragTargetIndex;
    final simulationTarget = _simulationPageTarget;
    _pageTurnController.stop();
    _pageTurnController.reset();
    _commitPageTurnWhenSettled = commit;
    final serial = ++_pageTurnSerial;
    final travel = endOffset - _pageDragOffset;
    final spring = _pageSettleSpring(travel, velocity);
    final Animation<double> settle = spring == null
        ? CurvedAnimation(
            parent: _pageTurnController,
            curve: AppMotion.standard,
          )
        : _pageTurnController;
    _pageTurnAnimation = Tween<double>(
      begin: _pageDragOffset,
      end: endOffset,
    ).animate(settle);
    // The corner settles back onto its edge as the leaf lands on either side.
    final lift = _pageCurlLiftNotifier.value;
    _pageCurlLiftAnimation = lift == 0
        ? null
        : Tween<double>(begin: lift, end: 0).animate(settle);
    final landing = spring == null
        ? _pageTurnController.forward()
        : _pageTurnController.animateWith(spring);
    landing.then((_) {
      if (!mounted || serial != _pageTurnSerial) return;
      if (_commitPageTurnWhenSettled && simulationTarget != null) {
        _finishSimulationPageTurn(simulationTarget);
      } else if (_commitPageTurnWhenSettled && targetIndex != null) {
        _finishPageTurn(targetIndex);
      } else {
        _resetPageDrag();
      }
    });
  }

  /// A spring that carries the leaf from the finger's release [velocity] to
  /// the end of [travel], over the controller's 0 to 1.
  ///
  /// Critical damping never bounces, and a start no faster than the closing
  /// rate never overshoots, so the leaf can't swing past the page edge or
  /// back across its resting place. A release moving away from the target
  /// starts from rest. Null where the timed settle stays: a leaf already in
  /// place, and when the system asks for reduced motion, which shortens that
  /// settle further.
  Simulation? _pageSettleSpring(double travel, double velocity) {
    if (travel.abs() < 0.5 || MediaQuery.disableAnimationsOf(context)) {
      return null;
    }
    final distance = travel.abs();
    final start = (velocity * travel.sign / distance)
        .clamp(0.0, _pageSettleRate)
        .toDouble();
    return SpringSimulation(
      SpringDescription(
        mass: 1,
        stiffness: _pageSettleRate * _pageSettleRate,
        damping: 2 * _pageSettleRate,
      ),
      0,
      1,
      start,
      // Done once the leaf is within half a pixel and barely moving, so the
      // settle stops drawing frames as soon as nothing visibly changes.
      tolerance: Tolerance(distance: 0.5 / distance, velocity: 20 / distance),
    );
  }

  void _finishPageTurn(int targetIndex) {
    _setTextSelectionBlocked(false);
    _switchChapter(targetIndex, startAtTop: false);
  }

  void _finishSimulationPageTurn(SimulationPageTarget target) {
    _setTextSelectionBlocked(false);
    if (target.chapterIndex != _chapterIndex) {
      _switchChapter(target.chapterIndex, startAtTop: false);
      return;
    }
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      _resetPageDrag();
      return;
    }

    final position = _scrollController.position;
    final targetOffset = _alignSimulationOffset(
      target.offset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
      pageExtent: position.viewportDimension,
      maxExtent: position.maxScrollExtent,
    );
    final previousPreview = _simulationPreviewController;
    final previousPaperBack = _simulationPaperBackController;
    // Commit the active controller to the exact preview offset while the
    // preview sheet still covers the screen. Clearing the drag first exposes
    // the old page for a frame and makes the ListView appear to reload.
    if ((position.pixels - targetOffset).abs() > 0.5) {
      _scrollController.jumpTo(targetOffset);
    }
    final snapshot = _currentScrollSnapshot();
    final progress = _recordCurrentChapterPosition(snapshot);
    // The drag is over: clear its origin so the next turn's paper back never
    // mirrors this turn's departure page.
    _pageTurnOriginChapterIndex = null;
    _pageTurnOriginSnapshot = null;
    _setReaderState(() {
      _simulationPreviewController = null;
      _simulationPaperBackController = null;
      _simulationPageTarget = null;
      _pageTurnAnimation = null;
      _commitPageTurnWhenSettled = false;
      _pageDragTargetIndex = null;
    });
    _setPageDragOffset(0);
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    _enqueueProgressSave(progress);
    if (previousPreview != null || previousPaperBack != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousPreview?.dispose();
        previousPaperBack?.dispose();
      });
    }
    _scheduleSimulationSnapshotWarmup();
  }

  void _setTextSelectionBlocked(bool blocked) {
    if (blocked) ContextMenuController.removeAny();
    if (_selectionController.blocked.value == blocked) return;
    _selectionController.setBlocked(blocked);
  }

  void _handleTextSelectionActivityChanged() {
    if (!_selectionController.active.value) return;
    _readingTapMoved = true;
    _clearSimulationTurnPointer();
    if (_pageDragOffset != 0 || _simulationPageTarget != null) {
      _resetPageDrag();
    }
  }
}
