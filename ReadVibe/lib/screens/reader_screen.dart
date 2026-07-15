import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        RenderRepaintBoundary,
        RenderSliver,
        ScrollCacheExtent,
        SelectedContent;
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/font_service.dart';
import '../services/storage_service.dart';
import '../services/system_text_action_service.dart';
import '../services/word_count_service.dart';
import '../widgets/chapter_list.dart';
import '../widgets/reader_settings_sheet.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/reading_progress_bar.dart';

/// Reader screen — displays book content with settings overlay
class ReaderScreen extends StatefulWidget {
  final Book book;
  final ValueListenable<ReaderThemeColors>? transitionColors;
  final ValueChanged<ReaderSettings>? onSettingsChanged;

  const ReaderScreen({
    super.key,
    required this.book,
    this.transitionColors,
    this.onSettingsChanged,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _paragraphIndent = '　　';
  static const _readingTapSlop = 18.0;
  static const _readingTapTimeout = Duration(milliseconds: 600);

  final _storage = StorageService();
  late final _fontService = FontService(_storage);
  late ReaderSettings _settings;
  late int _chapterIndex;
  bool _showOverlay = false;
  late ScrollController _scrollController;
  bool _settingsLoaded = false;
  Timer? _saveTimer;
  final _pageDragOffsetNotifier = ValueNotifier<double>(0);
  late final AnimationController _pageTurnController;
  Animation<double>? _pageTurnAnimation;
  double _pageDragOffset = 0;
  double _pageCurlAnchorY = double.nan;
  int? _pageDragTargetIndex;
  bool _commitPageTurnWhenSettled = false;
  int _pageTurnSerial = 0;
  bool _warmAdjacentPages = false;
  ReaderSettings? _pendingSettingsApply;
  Timer? _settingsApplyTimer;
  Timer? _hideStatusBarTimer;
  int? _readingTapPointer;
  Offset? _readingTapOrigin;
  Duration? _readingTapStartedAt;
  bool _readingTapMoved = false;
  int? _simulationTurnPointer;
  Offset? _simulationTurnOrigin;
  Offset? _simulationTurnLastPosition;
  VelocityTracker? _simulationTurnVelocityTracker;
  bool _simulationTurnActive = false;
  bool _closingReader = false;
  double _viewPaddingTop = 0;
  ReadingProgress? _currentProgress;
  Set<String> _collapsedTocGroupIds = <String>{};
  double? _pendingScrollOffset;
  double? _pendingScrollProgress;
  bool _preferPendingScrollProgress = false;
  int _scrollRestoreSerial = 0;
  final Map<int, ScrollController> _adjacentScrollControllers =
      <int, ScrollController>{};
  final Map<int, int> _adjacentScrollRestoreSerials = <int, int>{};
  int _overlayToggleSerial = 0;
  int? _pageTurnOriginChapterIndex;
  _ScrollSnapshot? _pageTurnOriginSnapshot;
  final GlobalKey _currentPageBoundaryKey = GlobalKey();
  final GlobalKey _incomingPageBoundaryKey = GlobalKey();
  ui.Image? _pageTurnSnapshot;
  Future<bool>? _pageTurnSnapshotCapture;
  int _pageTurnSnapshotSerial = 0;
  ui.Image? _incomingPageSnapshot;
  Future<bool>? _incomingPageSnapshotCapture;
  int _incomingPageSnapshotSerial = 0;
  late final List<GlobalKey> _continuousChapterKeys;
  int _continuousAnchorChapterIndex = 0;
  final Map<int, double> _continuousChapterStarts = <int, double>{};
  final Map<int, double> _continuousChapterExtents = <int, double>{};
  bool _continuousMetricsScheduled = false;
  int _continuousRestoreSerial = 0;
  double? _pendingContinuousProgress;
  _SimulationPageTarget? _simulationPageTarget;
  ScrollController? _simulationPreviewController;
  late final ValueNotifier<int?> _wordCountNotifier;
  late final ValueNotifier<List<int>?> _chapterWordCountsNotifier;
  late final ValueNotifier<double> _visibleProgressNotifier;
  _ScrollSnapshot _lastScrollSnapshot = const _ScrollSnapshot(
    offset: 0,
    progress: 0,
  );
  Future<void> _progressSaveQueue = Future<void>.value();
  final LinkedHashMap<Chapter, List<String>> _paragraphCache =
      LinkedHashMap<Chapter, List<String>>();

  Book get _book => widget.book;

  @override
  void initState() {
    super.initState();
    _chapterIndex = 0;
    _settings = const ReaderSettings();
    _continuousChapterKeys = List<GlobalKey>.generate(
      _book.chapters.length,
      (_) => GlobalKey(),
      growable: false,
    );
    _wordCountNotifier = ValueNotifier<int?>(_book.wordCount);
    _chapterWordCountsNotifier = ValueNotifier<List<int>?>(
      _book.chapterWordCounts?.length == _book.chapters.length
          ? _book.chapterWordCounts
          : null,
    );
    _visibleProgressNotifier = ValueNotifier<double>(0);
    _scrollController = _createScrollController();
    WidgetsBinding.instance.addObserver(this);
    // Keep screen on while reading — the user should not have to tap to
    // prevent the device from sleeping mid-paragraph.
    _ignorePlatformFuture(WakelockPlus.enable(), 'enable wakelock');
    // Keep the shelf stable while the book-opening route is still revealing
    // it underneath. The reader hides the status bar only after the opening
    // animation has fully settled.
    _showLibrarySystemBars();
    _hideStatusBarTimer = Timer(AppMotion.bookOpen, _hideStatusBarForReader);
    _pageTurnController =
        AnimationController(vsync: this, duration: AppMotion.pageTurn)
          ..addListener(() {
            final animation = _pageTurnAnimation;
            if (animation == null) return;
            _setPageDragOffset(animation.value);
          });
    _loadInitialState();
    if (_book.wordCount == null) unawaited(_ensureBookWordCount());
    if (_chapterWordCountsNotifier.value == null) {
      unawaited(_ensureChapterWordCounts());
    }
  }

  Future<void> _ensureBookWordCount() async {
    try {
      final wordCount = await WordCountService().count(_book);
      await _storage.saveBookWordCount(_book.id, wordCount);
      if (mounted) _wordCountNotifier.value = wordCount;
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to count reader text: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _ensureChapterWordCounts() async {
    try {
      final chapterWordCounts = await WordCountService().countChapters(_book);
      await _storage.saveChapterWordCounts(_book, chapterWordCounts);
      if (mounted) _chapterWordCountsNotifier.value = chapterWordCounts;
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to count chapter text: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  ScrollController _createScrollController([double initialOffset = 0]) {
    final controller = ScrollController(
      initialScrollOffset: initialOffset.isFinite && initialOffset >= 0
          ? initialOffset
          : 0,
    );
    controller.addListener(_scheduleProgressSave);
    return controller;
  }

  ScrollController _controllerForAdjacentChapter(
    int chapterIndex, {
    double? overrideProgress,
  }) {
    final existing = _adjacentScrollControllers[chapterIndex];
    if (existing != null) {
      _scheduleAdjacentScrollRestore(
        chapterIndex,
        existing,
        overrideProgress: overrideProgress,
      );
      return existing;
    }

    final savedOffset = _currentProgress?.chapterOffsets[chapterIndex] ?? 0;
    final initialOffset = savedOffset.isFinite && savedOffset >= 0
        ? savedOffset
        : 0.0;
    // Preview controllers must never use the active chapter's progress
    // listener. They are positioned offscreen before a horizontal drag and
    // only become authoritative if that page turn is committed.
    final controller = ScrollController(
      initialScrollOffset: initialOffset,
      keepScrollOffset: false,
    );
    _adjacentScrollControllers[chapterIndex] = controller;
    _scheduleAdjacentScrollRestore(
      chapterIndex,
      controller,
      overrideProgress: overrideProgress,
    );
    return controller;
  }

  void _scheduleAdjacentScrollRestore(
    int chapterIndex,
    ScrollController controller, {
    double? overrideProgress,
    int attempt = 0,
  }) {
    final serial = attempt == 0
        ? (_adjacentScrollRestoreSerials[chapterIndex] ?? 0) + 1
        : _adjacentScrollRestoreSerials[chapterIndex] ?? 0;
    if (attempt == 0) {
      _adjacentScrollRestoreSerials[chapterIndex] = serial;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _adjacentScrollRestoreSerials[chapterIndex] != serial ||
          !identical(_adjacentScrollControllers[chapterIndex], controller)) {
        return;
      }
      if (!controller.hasClients || !controller.position.hasContentDimensions) {
        if (attempt < 20) {
          _scheduleAdjacentScrollRestore(
            chapterIndex,
            controller,
            overrideProgress: overrideProgress,
            attempt: attempt + 1,
          );
        }
        return;
      }

      final maxExtent = controller.position.maxScrollExtent;
      final savedProgress =
          overrideProgress ?? _currentProgress?.chapterProgress[chapterIndex];
      final savedOffset = _currentProgress?.chapterOffsets[chapterIndex] ?? 0;
      final target = savedProgress != null && savedProgress.isFinite
          ? savedProgress.clamp(0.0, 1.0).toDouble() * maxExtent
          : (savedOffset.isFinite && savedOffset >= 0 ? savedOffset : 0.0)
                .clamp(0.0, maxExtent)
                .toDouble();
      if ((controller.offset - target).abs() > 0.5) {
        controller.jumpTo(target);
      }
    });
  }

  _ScrollSnapshot? _adjacentScrollSnapshot(int chapterIndex) {
    final controller = _adjacentScrollControllers[chapterIndex];
    if (controller == null ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions) {
      return null;
    }
    final maxExtent = controller.position.maxScrollExtent;
    final rawOffset = controller.offset;
    final offset = rawOffset.isFinite
        ? rawOffset.clamp(0.0, maxExtent).toDouble()
        : 0.0;
    return _ScrollSnapshot(
      offset: offset,
      progress: maxExtent > 0 ? offset / maxExtent : 0,
    );
  }

  void _hideStatusBarForReader() {
    if (!mounted || _closingReader) return;
    _applySystemBarStyle();
    // Bottom gesture navigation stays visible; only the top status bar is
    // hidden for the immersive reading surface.
    _ignorePlatformFuture(
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [SystemUiOverlay.bottom],
      ),
      'hide reader status bar',
    );
  }

  void _showStatusBar() {
    if (!mounted) return;
    _applySystemBarStyle();
    _ignorePlatformFuture(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
      'show status bar',
    );
  }

  void _showLibrarySystemBars() {
    _applySystemBarStyle();
    _ignorePlatformFuture(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
      'restore library system bars',
    );
  }

  void _applySystemBarStyle() {
    final colors =
        widget.transitionColors?.value ??
        AppTheme.getReaderTheme(
          _settings.theme,
          systemBrightness:
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
        );
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemUiOverlayStyle(colors));
  }

  void _ignorePlatformFuture(Future<void> future, String operation) {
    unawaited(
      future.catchError((Object error, StackTrace stack) {
        debugPrint('Failed to $operation: $error');
        debugPrintStack(stackTrace: stack);
      }),
    );
  }

  Future<void> _closeReader() async {
    if (_closingReader) return;
    setState(() => _closingReader = true);
    _hideStatusBarTimer?.cancel();
    _saveTimer?.cancel();
    _showLibrarySystemBars();
    await _saveProgress();
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _loadInitialState() async {
    var savedSettings = const ReaderSettings();
    ReadingProgress? savedProgress;
    try {
      final results = await Future.wait<Object?>([
        _storage.getSettings(),
        _storage.getProgress(_book.id),
        _storage.getCollapsedTocGroups(_book.id),
      ]);
      savedSettings = results[0] as ReaderSettings;
      savedProgress = results[1] as ReadingProgress?;
      _collapsedTocGroupIds = Set<String>.from(results[2] as Set<String>);
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to load reader state: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    var loadedSettings = savedSettings;
    try {
      loadedSettings = await _fontService.ensureImportedFontLoaded(
        savedSettings,
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to load reader font: $error');
      debugPrintStack(stackTrace: stackTrace);
      loadedSettings = savedSettings.copyWith(
        fontFamily: ReaderSettings.systemFontFamily,
      );
    }
    if (!mounted) return;

    _settings = loadedSettings;
    widget.onSettingsChanged?.call(loadedSettings);
    if (loadedSettings.fontFamily != savedSettings.fontFamily) {
      _persistSettings(loadedSettings);
    }
    if (_book.chapters.isNotEmpty && savedProgress != null) {
      _chapterIndex = savedProgress.chapterIndex.clamp(
        0,
        _book.chapters.length - 1,
      );
    }
    final restoredOffset = savedProgress == null
        ? 0.0
        : savedProgress.chapterOffsets[_chapterIndex] ??
              (savedProgress.chapterIndex == _chapterIndex
                  ? savedProgress.scrollOffset
                  : 0.0);
    final safeRestoredOffset = restoredOffset.isFinite && restoredOffset >= 0
        ? restoredOffset
        : 0.0;
    final restoredProgress =
        savedProgress?.chapterProgress[_chapterIndex] ??
        (savedProgress?.chapterIndex == _chapterIndex
            ? savedProgress?.scrollProgress
            : null);
    final safeRestoredProgress =
        restoredProgress != null && restoredProgress.isFinite
        ? restoredProgress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    final hasSavedProgressRatio =
        savedProgress?.chapterProgress.containsKey(_chapterIndex) == true;
    _lastScrollSnapshot = _ScrollSnapshot(
      offset: safeRestoredOffset,
      progress: safeRestoredProgress,
    );
    _continuousAnchorChapterIndex = _chapterIndex;
    _visibleProgressNotifier.value = safeRestoredProgress;
    _currentProgress = ReadingProgress(
      bookId: _book.id,
      chapterIndex: _chapterIndex,
      scrollOffset: safeRestoredOffset,
      scrollProgress: safeRestoredProgress,
      chapterOffsets: Map<int, double>.from(
        savedProgress?.chapterOffsets ?? const <int, double>{},
      )..[_chapterIndex] = safeRestoredOffset,
      chapterProgress: Map<int, double>.from(
        savedProgress?.chapterProgress ?? const <int, double>{},
      ),
      lastReadDate: savedProgress?.lastReadDate ?? DateTime.now(),
    );
    _scrollController.removeListener(_scheduleProgressSave);
    _scrollController.dispose();
    _scrollController = _createScrollController(safeRestoredOffset);
    _settingsLoaded = true;

    setState(() {});
    if (loadedSettings.readingMode == ReaderReadingMode.continuous) {
      _requestContinuousRestore(
        hasSavedProgressRatio ? safeRestoredProgress : 0,
      );
    } else {
      _scheduleAdjacentWarmup();
      _requestScrollRestore(
        offset: safeRestoredOffset,
        progress: hasSavedProgressRatio ? safeRestoredProgress : null,
        preferProgress: hasSavedProgressRatio,
      );
      _scheduleSimulationSnapshotWarmup();
    }
  }

  void _requestScrollRestore({
    required double offset,
    double? progress,
    required bool preferProgress,
  }) {
    _pendingScrollOffset = offset.isFinite && offset >= 0 ? offset : 0;
    _pendingScrollProgress = progress != null && progress.isFinite
        ? progress.clamp(0.0, 1.0).toDouble()
        : null;
    _preferPendingScrollProgress = preferProgress;
    final serial = ++_scrollRestoreSerial;
    _restorePendingScrollPosition(serial);
  }

  void _restorePendingScrollPosition(int serial, [int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          serial != _scrollRestoreSerial ||
          _pendingScrollOffset == null) {
        return;
      }
      if (!_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions) {
        if (attempt < 20) {
          _restorePendingScrollPosition(serial, attempt + 1);
        } else {
          _clearPendingScrollRestore(serial);
        }
        return;
      }
      final requested = _pendingScrollOffset ?? 0;
      final maxExtent = _scrollController.position.maxScrollExtent;
      final progress = _pendingScrollProgress;
      var offset = _preferPendingScrollProgress && progress != null
          ? progress * maxExtent
          : requested.clamp(0.0, maxExtent).toDouble();
      if (_settings.readingMode == ReaderReadingMode.simulation) {
        offset = _alignSimulationOffset(offset, maxExtent: maxExtent);
      }
      _lastScrollSnapshot = _ScrollSnapshot(
        offset: offset,
        progress: maxExtent > 0 ? offset / maxExtent : 0,
      );
      _scrollController.jumpTo(offset);
      _clearPendingScrollRestore(serial);
      if (_currentProgress != null) {
        _currentProgress = _currentProgress!.recordPosition(
          _chapterIndex,
          offset,
          progress: maxExtent > 0 ? offset / maxExtent : 0,
        );
        _enqueueProgressSave(_currentProgress!);
      }
    });
  }

  void _clearPendingScrollRestore(int serial) {
    if (serial != _scrollRestoreSerial) return;
    _pendingScrollOffset = null;
    _pendingScrollProgress = null;
    _preferPendingScrollProgress = false;
  }

  double _alignSimulationOffset(double offset, {double? maxExtent}) {
    final lineExtent = _settings.fontSize * _settings.lineHeight;
    if (!offset.isFinite || lineExtent <= 0) return 0;
    final aligned = (offset / lineExtent).round() * lineExtent;
    if (maxExtent == null || !maxExtent.isFinite) {
      return math.max(0.0, aligned);
    }
    return aligned.clamp(0.0, maxExtent).toDouble();
  }

  void _resetContinuousMetrics() {
    _continuousRestoreSerial++;
    _pendingContinuousProgress = null;
    _continuousMetricsScheduled = false;
    _continuousChapterStarts
      ..clear()
      ..[_continuousAnchorChapterIndex] = 0;
    _continuousChapterExtents.clear();
  }

  void _requestContinuousRestore(double progress) {
    _continuousAnchorChapterIndex = _chapterIndex;
    _continuousChapterStarts
      ..clear()
      ..[_continuousAnchorChapterIndex] = 0;
    _continuousChapterExtents.clear();
    _pendingContinuousProgress = progress.isFinite
        ? progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    final serial = ++_continuousRestoreSerial;
    _restoreContinuousPosition(serial);
  }

  void _restoreContinuousPosition(int serial, [int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          serial != _continuousRestoreSerial ||
          _settings.readingMode != ReaderReadingMode.continuous ||
          _pendingContinuousProgress == null) {
        return;
      }
      _refreshContinuousMetrics(updateActiveChapter: false);
      if (!_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions) {
        if (attempt < 20) {
          _restoreContinuousPosition(serial, attempt + 1);
        }
        return;
      }
      final extent = _continuousChapterExtents[_continuousAnchorChapterIndex];
      if (extent == null || !extent.isFinite || extent <= 0) {
        if (attempt < 20) {
          _restoreContinuousPosition(serial, attempt + 1);
        }
        return;
      }
      final viewport = _scrollController.position.viewportDimension;
      final readableExtent = math.max(0.0, extent - viewport);
      final target = (_pendingContinuousProgress! * readableExtent)
          .clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          )
          .toDouble();
      _pendingContinuousProgress = null;
      if ((_scrollController.offset - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
      final snapshot = _continuousSnapshotForChapter(_chapterIndex);
      _recordCurrentChapterPosition(snapshot);
    });
  }

  void _scheduleContinuousMetricsUpdate() {
    if (_continuousMetricsScheduled ||
        _settings.readingMode != ReaderReadingMode.continuous) {
      return;
    }
    _continuousMetricsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _continuousMetricsScheduled = false;
      if (!mounted || _settings.readingMode != ReaderReadingMode.continuous) {
        return;
      }
      _refreshContinuousMetrics(updateActiveChapter: true);
    });
  }

  void _refreshContinuousMetrics({required bool updateActiveChapter}) {
    if (_continuousChapterKeys.isEmpty) return;
    _continuousChapterStarts.putIfAbsent(
      _continuousAnchorChapterIndex,
      () => 0,
    );
    for (var index = 0; index < _continuousChapterKeys.length; index++) {
      final renderObject = _continuousChapterKeys[index].currentContext
          ?.findRenderObject();
      if (renderObject is! RenderSliver) continue;
      final extent = renderObject.geometry?.scrollExtent;
      if (extent != null && extent.isFinite && extent >= 0) {
        _continuousChapterExtents[index] = extent;
      }
    }

    var changed = true;
    while (changed) {
      changed = false;
      for (var index = 0; index < _continuousChapterKeys.length - 1; index++) {
        final start = _continuousChapterStarts[index];
        final extent = _continuousChapterExtents[index];
        if (start != null && extent != null) {
          final nextStart = start + extent;
          if (_continuousChapterStarts[index + 1] != nextStart) {
            _continuousChapterStarts[index + 1] = nextStart;
            changed = true;
          }
        }
      }
      for (var index = _continuousChapterKeys.length - 1; index > 0; index--) {
        final start = _continuousChapterStarts[index];
        final previousExtent = _continuousChapterExtents[index - 1];
        if (start != null && previousExtent != null) {
          final previousStart = start - previousExtent;
          if (_continuousChapterStarts[index - 1] != previousStart) {
            _continuousChapterStarts[index - 1] = previousStart;
            changed = true;
          }
        }
      }
    }

    if (!updateActiveChapter ||
        !_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions ||
        _pendingContinuousProgress != null) {
      return;
    }
    final viewportOffset = _scrollController.offset + 0.5;
    var activeIndex = _chapterIndex;
    var activeStart = double.negativeInfinity;
    for (final entry in _continuousChapterStarts.entries) {
      if (entry.value <= viewportOffset && entry.value >= activeStart) {
        activeIndex = entry.key;
        activeStart = entry.value;
      }
    }
    activeIndex = activeIndex.clamp(0, _book.chapters.length - 1);
    if (activeIndex != _chapterIndex) {
      final previousIndex = _chapterIndex;
      final previousSnapshot = _continuousSnapshotForChapter(previousIndex);
      final base = _currentProgress;
      if (base != null) {
        _currentProgress = base.recordPosition(
          previousIndex,
          previousSnapshot.offset,
          progress: previousSnapshot.progress,
        );
      }
      setState(() => _chapterIndex = activeIndex);
    }
    final snapshot = _continuousSnapshotForChapter(_chapterIndex);
    final updated = _recordCurrentChapterPosition(snapshot);
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 500),
      () => _enqueueProgressSave(updated),
    );
  }

  _ScrollSnapshot _continuousSnapshotForChapter(int chapterIndex) {
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return _lastScrollSnapshot;
    }
    final start = _continuousChapterStarts[chapterIndex];
    final extent = _continuousChapterExtents[chapterIndex];
    if (start == null || extent == null || !extent.isFinite) {
      return _lastScrollSnapshot;
    }
    final viewport = _scrollController.position.viewportDimension;
    final readableExtent = math.max(0.0, extent - viewport);
    final localOffset = (_scrollController.offset - start)
        .clamp(0.0, readableExtent)
        .toDouble();
    return _ScrollSnapshot(
      offset: localOffset,
      progress: readableExtent > 0 ? localOffset / readableExtent : 0,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ignorePlatformFuture(WakelockPlus.disable(), 'disable wakelock');
    _hideStatusBarTimer?.cancel();
    _saveTimer?.cancel();
    _settingsApplyTimer?.cancel();
    if (!_closingReader) unawaited(_saveProgress());
    _discardPageTurnSnapshot();
    _wordCountNotifier.dispose();
    _chapterWordCountsNotifier.dispose();
    _visibleProgressNotifier.dispose();
    _pageTurnController.dispose();
    _pageDragOffsetNotifier.dispose();
    _scrollController.removeListener(_scheduleProgressSave);
    _scrollController.dispose();
    final adjacentControllers = _adjacentScrollControllers.values.toSet();
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();
    for (final controller in adjacentControllers) {
      controller.dispose();
    }
    _simulationPreviewController?.dispose();
    _showLibrarySystemBars();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress());
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (!_settingsLoaded) return;
    widget.onSettingsChanged?.call(_settings);
    _applySystemBarStyle();
  }

  void _scheduleProgressSave() {
    if (!_settingsLoaded || _closingReader) return;
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      _scheduleContinuousMetricsUpdate();
    }
    if (_pageDragOffset == 0 && !_pageTurnController.isAnimating) {
      _discardPageTurnSnapshot();
      _scheduleSimulationSnapshotWarmup();
    }
    final snapshot = _currentScrollSnapshot();
    _recordCurrentChapterPosition(snapshot);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveProgress);
  }

  Future<void> _saveProgress() {
    if (_currentProgress == null || _book.chapters.isEmpty) {
      return _progressSaveQueue;
    }
    final snapshot = _currentScrollSnapshot();
    final updated = _recordCurrentChapterPosition(snapshot);
    return _enqueueProgressSave(updated);
  }

  ReadingProgress _recordCurrentChapterPosition(_ScrollSnapshot snapshot) {
    final base =
        _currentProgress ??
        ReadingProgress(
          bookId: _book.id,
          chapterIndex: _chapterIndex,
          lastReadDate: DateTime.now(),
        );
    final updated = base.recordPosition(
      _chapterIndex,
      snapshot.offset,
      progress: snapshot.progress,
    );
    _currentProgress = updated;
    _lastScrollSnapshot = snapshot;
    _visibleProgressNotifier.value = snapshot.progress;
    return updated;
  }

  _ScrollSnapshot _currentScrollSnapshot() {
    if (_settings.readingMode == ReaderReadingMode.continuous) {
      return _continuousSnapshotForChapter(_chapterIndex);
    }
    // A real attached position always wins. Previously a restore value that
    // had not been cleared yet masked all subsequent user scrolling, causing
    // chapter switches to repeatedly save the stale pending offset.
    if (_scrollController.hasClients &&
        _scrollController.position.hasContentDimensions) {
      final rawOffset = _scrollController.offset;
      final offset = rawOffset.isFinite && rawOffset >= 0 ? rawOffset : 0.0;
      final maxExtent = _scrollController.position.maxScrollExtent;
      final snapshot = _ScrollSnapshot(
        offset: offset,
        progress: maxExtent > 0
            ? (offset / maxExtent).clamp(0.0, 1.0).toDouble()
            : 0,
      );
      _lastScrollSnapshot = snapshot;
      return snapshot;
    }

    final pendingOffset = _pendingScrollOffset;
    final pendingProgress = _pendingScrollProgress;
    if (pendingOffset != null && pendingOffset.isFinite && pendingOffset >= 0) {
      final snapshot = _ScrollSnapshot(
        offset: pendingOffset,
        progress:
            pendingProgress != null &&
                pendingProgress.isFinite &&
                pendingProgress >= 0
            ? pendingProgress.clamp(0.0, 1.0).toDouble()
            : 0,
      );
      _lastScrollSnapshot = snapshot;
      return snapshot;
    }

    // State.dispose runs after the Scrollable has detached its position. The
    // last listener-maintained snapshot remains authoritative; returning zero
    // here would overwrite the user's correct position while closing.
    return _lastScrollSnapshot;
  }

  Future<void> _enqueueProgressSave(ReadingProgress progress) {
    _progressSaveQueue = _progressSaveQueue
        .then((_) => _storage.saveProgress(progress))
        .catchError((Object error, StackTrace stack) {
          debugPrint('Failed to save reading progress: $error');
          debugPrintStack(stackTrace: stack);
        });
    return _progressSaveQueue;
  }

  void _persistSettings(ReaderSettings settings) {
    unawaited(
      _storage.saveSettings(settings).catchError((
        Object error,
        StackTrace stack,
      ) {
        debugPrint('Failed to save reader settings: $error');
        debugPrintStack(stackTrace: stack);
      }),
    );
  }

  Chapter get _currentChapter => _book.chapters[_chapterIndex];

  List<String> _paragraphsFor(Chapter chapter) {
    final cached = _paragraphCache.remove(chapter);
    if (cached != null) {
      _paragraphCache[chapter] = cached;
      return cached;
    }
    final paragraphs = chapter.content
        .split(RegExp(r'(?:\r\n?|\n)+'))
        .map(_formatParagraph)
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    _paragraphCache[chapter] = paragraphs;
    while (_paragraphCache.length > 5) {
      _paragraphCache.remove(_paragraphCache.keys.first);
    }
    return paragraphs;
  }

  String _formatParagraph(String paragraph) {
    final body = paragraph.replaceFirst(RegExp(r'^[\s　]+'), '').trimRight();
    return body.isEmpty ? '' : '$_paragraphIndent$body';
  }

  String _formatChapterTitle(String title) {
    return title.replaceFirst(RegExp(r'^[\s　]+'), '').trimRight();
  }

  void _setPageDragOffset(double value) {
    if (_pageDragOffset == value) return;
    _pageDragOffset = value;
    _pageDragOffsetNotifier.value = value;
  }

  Future<bool> _capturePageTurnSnapshot() {
    if (!mounted ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _settings.simulationPageTurnEffect !=
            SimulationPageTurnEffect.simulation) {
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
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!mounted ||
            serial != _pageTurnSnapshotSerial ||
            chapterIndex != _chapterIndex ||
            _settings.readingMode != ReaderReadingMode.simulation ||
            _settings.simulationPageTurnEffect !=
                SimulationPageTurnEffect.simulation) {
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
          serial != _pageTurnSnapshotSerial ||
          chapterIndex != _chapterIndex ||
          _settings.readingMode != ReaderReadingMode.simulation ||
          _settings.simulationPageTurnEffect !=
              SimulationPageTurnEffect.simulation) {
        image.dispose();
        return false;
      }

      final previousImage = _pageTurnSnapshot;
      _pageTurnSnapshot = image;
      previousImage?.dispose();
      // Rebuild at the same drag offset so the newly captured mirror appears
      // on the active simulated paper back without restarting the gesture.
      setState(() {});
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
    _discardIncomingPageSnapshot();
  }

  void _scheduleIncomingPageSnapshotCapture(_SimulationPageTarget target) {
    if (target.goingNext ||
        _incomingPageSnapshot != null ||
        _incomingPageSnapshotCapture != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final activeTarget = _simulationPageTarget;
      if (activeTarget == null ||
          activeTarget.goingNext ||
          !activeTarget.matches(target)) {
        return;
      }
      unawaited(_captureIncomingPageSnapshot(target));
    });
  }

  Future<bool> _captureIncomingPageSnapshot(_SimulationPageTarget target) {
    if (!mounted ||
        target.goingNext ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _settings.simulationPageTurnEffect !=
            SimulationPageTurnEffect.simulation) {
      return Future<bool>.value(false);
    }
    if (_incomingPageSnapshot != null) return Future<bool>.value(true);
    final existing = _incomingPageSnapshotCapture;
    if (existing != null) return existing;

    final serial = ++_incomingPageSnapshotSerial;
    late final Future<bool> operation;
    operation = _performIncomingPageSnapshotCapture(serial, target)
        .whenComplete(() {
          if (identical(_incomingPageSnapshotCapture, operation)) {
            _incomingPageSnapshotCapture = null;
          }
        });
    _incomingPageSnapshotCapture = operation;
    return operation;
  }

  Future<bool> _performIncomingPageSnapshotCapture(
    int serial,
    _SimulationPageTarget target,
  ) async {
    try {
      final pixelRatio = math.min(MediaQuery.devicePixelRatioOf(context), 1.5);
      RenderRepaintBoundary? boundary;
      for (var attempt = 0; attempt < 3; attempt++) {
        final activeTarget = _simulationPageTarget;
        if (!mounted ||
            serial != _incomingPageSnapshotSerial ||
            activeTarget == null ||
            activeTarget.goingNext ||
            !activeTarget.matches(target) ||
            _settings.readingMode != ReaderReadingMode.simulation ||
            _settings.simulationPageTurnEffect !=
                SimulationPageTurnEffect.simulation) {
          return false;
        }
        final renderObject = _incomingPageBoundaryKey.currentContext
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
      final activeTarget = _simulationPageTarget;
      if (!mounted ||
          serial != _incomingPageSnapshotSerial ||
          activeTarget == null ||
          activeTarget.goingNext ||
          !activeTarget.matches(target)) {
        image.dispose();
        return false;
      }
      final previousImage = _incomingPageSnapshot;
      _incomingPageSnapshot = image;
      previousImage?.dispose();
      setState(() {});
      return true;
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to capture the incoming previous page: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  void _discardIncomingPageSnapshot() {
    _incomingPageSnapshotSerial++;
    _incomingPageSnapshotCapture = null;
    final image = _incomingPageSnapshot;
    _incomingPageSnapshot = null;
    image?.dispose();
  }

  void _scheduleSimulationSnapshotWarmup() {
    if (!_settingsLoaded ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _settings.simulationPageTurnEffect !=
            SimulationPageTurnEffect.simulation ||
        _pageTurnSnapshot != null ||
        _pageTurnSnapshotCapture != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _settings.readingMode != ReaderReadingMode.simulation ||
          _settings.simulationPageTurnEffect !=
              SimulationPageTurnEffect.simulation ||
          _pageDragOffset != 0 ||
          _pageTurnController.isAnimating ||
          _pageTurnSnapshot != null) {
        return;
      }
      unawaited(_capturePageTurnSnapshot());
    });
  }

  void _resetPageDrag({bool rebuild = true}) {
    _clearSimulationTurnPointer();
    final simulationPreview = _simulationPreviewController;
    _simulationPreviewController = null;
    _simulationPageTarget = null;
    _pageTurnController.stop();
    _pageTurnAnimation = null;
    _commitPageTurnWhenSettled = false;
    _pageTurnOriginChapterIndex = null;
    _pageTurnOriginSnapshot = null;
    _setPageDragOffset(0);
    _discardPageTurnSnapshot();
    if (!mounted) return;
    if (rebuild) {
      setState(() => _pageDragTargetIndex = null);
    } else {
      _pageDragTargetIndex = null;
    }
    if (simulationPreview != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        simulationPreview.dispose();
      });
    }
    _scheduleSimulationSnapshotWarmup();
  }

  void _scheduleAdjacentWarmup() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _warmAdjacentPages) return;
      setState(() => _warmAdjacentPages = true);
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
      final rebuildsContinuous =
          previousMode == ReaderReadingMode.continuous ||
          pending.readingMode == ReaderReadingMode.continuous;
      final progress = _recordCurrentChapterPosition(snapshot);
      _enqueueProgressSave(progress);
      _resetPageDrag(rebuild: false);

      if (rebuildsContinuous) {
        final previousController = _scrollController;
        previousController.removeListener(_scheduleProgressSave);
        final nextController = _createScrollController(snapshot.offset);
        final adjacentControllers = _adjacentScrollControllers.values.toSet();
        _adjacentScrollControllers.clear();
        _adjacentScrollRestoreSerials.clear();
        _continuousAnchorChapterIndex = _chapterIndex;
        _resetContinuousMetrics();
        setState(() {
          _settings = pending;
          _scrollController = nextController;
          _warmAdjacentPages = false;
          _pageDragTargetIndex = null;
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
        setState(() {
          _settings = pending;
          _warmAdjacentPages = false;
          _pageDragTargetIndex = null;
        });
      }

      if (pending.readingMode == ReaderReadingMode.continuous) {
        _requestContinuousRestore(snapshot.progress);
      } else {
        _scheduleAdjacentWarmup();
        _requestScrollRestore(
          offset: snapshot.offset,
          progress: snapshot.progress,
          preferProgress: true,
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
    _lastScrollSnapshot = _ScrollSnapshot(
      offset: targetOffset,
      progress: targetProgress,
    );
    _visibleProgressNotifier.value = targetProgress;

    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController();
    _continuousAnchorChapterIndex = index;
    _resetContinuousMetrics();
    setState(() {
      _chapterIndex = index;
      _scrollController = nextController;
      _showOverlay = false;
    });
    _hideStatusBarForReader();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
    });
    _enqueueProgressSave(progress);
    _requestContinuousRestore(targetProgress);
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
      if (startAtTop && _scrollController.hasClients) {
        _discardPageTurnSnapshot();
        _scrollController.jumpTo(0);
        final progress = _recordCurrentChapterPosition(
          const _ScrollSnapshot(offset: 0, progress: 0),
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
    // The adjacent preview is already laid out at the saved reading position.
    // Inherit its exact pixel offset when committing the turn so the page seen
    // during the gesture is the same page that remains after the animation.
    final previewSnapshot = startAtTop ? null : _adjacentScrollSnapshot(index);
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
    _lastScrollSnapshot = _ScrollSnapshot(
      offset: targetOffset,
      progress: targetProgress,
    );
    _visibleProgressNotifier.value = targetProgress;

    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController(targetOffset);
    final previousAdjacentControllers = _adjacentScrollControllers.values
        .toSet();
    final previousSimulationPreview = _simulationPreviewController;
    _simulationPreviewController = null;
    _simulationPageTarget = null;
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();

    setState(() {
      _chapterIndex = index;
      _scrollController = nextController;
      _warmAdjacentPages = false;
      _pageDragTargetIndex = null;
      _pageTurnAnimation = null;
      _commitPageTurnWhenSettled = false;
      _simulationPageTarget = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
      for (final controller in previousAdjacentControllers) {
        controller.dispose();
      }
      previousSimulationPreview?.dispose();
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
    if (willShow) {
      _showStatusBar();
    } else {
      _hideStatusBarForReader();
    }
    setState(() => _showOverlay = willShow);
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
        _lastScrollSnapshot = _ScrollSnapshot(
          offset: target,
          progress: maxExtent > 0 ? target / maxExtent : 0,
        );
      }
      _scheduleSimulationSnapshotWarmup();
    });
  }

  void _handleReadingPointerDown(PointerDownEvent event) {
    if (_readingTapPointer != null) return;
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
      if (_settings.simulationPageTurnEffect ==
          SimulationPageTurnEffect.simulation) {
        unawaited(_capturePageTurnSnapshot());
      }
    }
  }

  void _handleReadingPointerMove(PointerMoveEvent event, double width) {
    if (event.pointer == _simulationTurnPointer) {
      _simulationTurnVelocityTracker?.addPosition(
        event.timeStamp,
        event.position,
      );
      final origin = _simulationTurnOrigin;
      final lastPosition = _simulationTurnLastPosition;
      if (origin != null && lastPosition != null) {
        final travel = event.localPosition - origin;
        if (!_simulationTurnActive &&
            travel.dx.abs() >= 9 &&
            travel.dx.abs() > travel.dy.abs() * 1.15) {
          _simulationTurnActive = true;
          _readingTapMoved = true;
          _beginHorizontalPageTurn(event.localPosition);
          _updateHorizontalPageTurn(
            deltaX: travel.dx,
            localPosition: event.localPosition,
            width: width,
          );
        } else if (_simulationTurnActive) {
          _readingTapMoved = true;
          _updateHorizontalPageTurn(
            deltaX: event.localPosition.dx - lastPosition.dx,
            localPosition: event.localPosition,
            width: width,
          );
        }
      }
      _simulationTurnLastPosition = event.localPosition;
    }

    if (event.pointer != _readingTapPointer || _readingTapMoved) return;
    final origin = _readingTapOrigin;
    if (origin == null) return;
    if ((event.position - origin).distance > _readingTapSlop) {
      _readingTapMoved = true;
    }
  }

  void _handleReadingPointerUp(PointerUpEvent event, double width) {
    if (event.pointer != _readingTapPointer) return;
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
        ? _readingTapTimeout + const Duration(milliseconds: 1)
        : event.timeStamp - startedAt;
    final shouldToggle = !_readingTapMoved && elapsed <= _readingTapTimeout;
    _clearReadingTap();
    if (simulationTurnWasActive) {
      _endHorizontalPageTurn(simulationVelocity, width);
    } else if (shouldToggle) {
      _toggleOverlay();
    }
  }

  void _handleReadingPointerCancel(PointerCancelEvent event) {
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

  void _handleHorizontalDragStart(DragStartDetails details) {
    _beginHorizontalPageTurn(details.localPosition);
  }

  void _beginHorizontalPageTurn(Offset localPosition) {
    if (_settings.readingMode == ReaderReadingMode.continuous) return;
    _pageCurlAnchorY = localPosition.dy;
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
    }
    _pageTurnController.stop();
    _pageTurnAnimation = null;
    if (_settings.readingMode == ReaderReadingMode.simulation &&
        _settings.simulationPageTurnEffect ==
            SimulationPageTurnEffect.simulation &&
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
    _updateHorizontalPageTurn(
      deltaX: details.delta.dx,
      localPosition: details.localPosition,
      width: width,
    );
  }

  void _updateHorizontalPageTurn({
    required double deltaX,
    required Offset localPosition,
    required double width,
  }) {
    if (width <= 0 || _settings.readingMode == ReaderReadingMode.continuous) {
      return;
    }
    if (_settings.readingMode == ReaderReadingMode.simulation &&
        _settings.simulationPageTurnEffect ==
            SimulationPageTurnEffect.simulation &&
        _pageTurnSnapshot == null) {
      unawaited(_capturePageTurnSnapshot());
    }
    _pageCurlAnchorY = localPosition.dy;
    final proposed = (_pageDragOffset + deltaX).clamp(-width, width);

    if (_settings.readingMode == ReaderReadingMode.simulation) {
      final goingNext = proposed < 0;
      final target = proposed == 0
          ? null
          : _simulationTargetForDirection(goingNext: goingNext);
      if (target == null) {
        _replaceSimulationPageTarget(null);
        _setPageDragOffset(proposed * 0.14);
        return;
      }
      _replaceSimulationPageTarget(target, hideOverlay: true);
      _setPageDragOffset(
        goingNext ? proposed.clamp(-width, 0.0) : proposed.clamp(0.0, width),
      );
      return;
    }

    final targetIndex = _pageDragTargetIndex ?? _targetIndexForOffset(proposed);
    if (targetIndex == null) {
      _setPageDragOffset(proposed * 0.14);
      return;
    }

    final goingNext = targetIndex > _chapterIndex;
    if (_pageDragTargetIndex != targetIndex || _showOverlay) {
      setState(() {
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

  int? _targetIndexForOffset(double offset) {
    if (offset < 0 && _chapterIndex < _book.chapters.length - 1) {
      return _chapterIndex + 1;
    }
    if (offset > 0 && _chapterIndex > 0) {
      return _chapterIndex - 1;
    }
    return null;
  }

  _SimulationPageTarget? _simulationTargetForDirection({
    required bool goingNext,
  }) {
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return null;
    }
    final position = _scrollController.position;
    final maxExtent = position.maxScrollExtent;
    final currentOffset = position.pixels.clamp(0.0, maxExtent).toDouble();
    final pageExtent = math.max(1.0, position.viewportDimension);

    if (goingNext) {
      if (currentOffset < maxExtent - 1) {
        final targetOffset = math.min(maxExtent, currentOffset + pageExtent);
        return _SimulationPageTarget(
          chapterIndex: _chapterIndex,
          offset: targetOffset,
          progress: maxExtent > 0 ? targetOffset / maxExtent : 0,
          goingNext: true,
        );
      }
      if (_chapterIndex >= _book.chapters.length - 1) return null;
      final targetIndex = _chapterIndex + 1;
      final preview = _adjacentScrollSnapshot(targetIndex);
      return _SimulationPageTarget(
        chapterIndex: targetIndex,
        offset: preview?.offset ?? 0,
        progress: preview?.progress ?? 0,
        goingNext: true,
      );
    }

    if (currentOffset > 1) {
      final targetOffset = math.max(0.0, currentOffset - pageExtent);
      return _SimulationPageTarget(
        chapterIndex: _chapterIndex,
        offset: targetOffset,
        progress: maxExtent > 0 ? targetOffset / maxExtent : 0,
        goingNext: false,
      );
    }
    if (_chapterIndex <= 0) return null;
    final targetIndex = _chapterIndex - 1;
    final preview = _adjacentScrollSnapshot(targetIndex);
    return _SimulationPageTarget(
      chapterIndex: targetIndex,
      offset:
          preview?.offset ?? _currentProgress?.chapterOffsets[targetIndex] ?? 0,
      progress: preview?.progress ?? 1,
      goingNext: false,
    );
  }

  void _replaceSimulationPageTarget(
    _SimulationPageTarget? target, {
    bool hideOverlay = false,
  }) {
    final current = _simulationPageTarget;
    final sameTarget =
        current != null && target != null && current.matches(target);
    if (sameTarget && (!hideOverlay || !_showOverlay)) {
      if (!target.goingNext) _scheduleIncomingPageSnapshotCapture(target);
      return;
    }

    if (!sameTarget) _discardIncomingPageSnapshot();

    final previousController = _simulationPreviewController;
    ScrollController? nextController;
    if (target != null && target.chapterIndex == _chapterIndex) {
      nextController = ScrollController(
        initialScrollOffset: target.offset,
        keepScrollOffset: false,
      );
    }
    _simulationPreviewController = nextController;
    setState(() {
      _simulationPageTarget = target;
      if (hideOverlay) _showOverlay = false;
    });
    if (hideOverlay) _hideStatusBarForReader();
    if (target != null && !target.goingNext) {
      _scheduleIncomingPageSnapshotCapture(target);
    }
    if (previousController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousController.dispose();
      });
    }
  }

  void _handleHorizontalDragEnd(DragEndDetails details, double width) {
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
    final velocityCommits =
        (goingNext && velocity < -260) || (!goingNext && velocity > 260);
    final shouldCommit = progress > 0.16 || velocityCommits;
    final endOffset = shouldCommit ? (goingNext ? -width : width) : 0.0;
    _animatePageDragTo(endOffset, commit: shouldCommit);
  }

  void _handleHorizontalDragCancel() {
    if (_pageDragOffset == 0 &&
        _pageDragTargetIndex == null &&
        _simulationPageTarget == null) {
      return;
    }
    _animatePageDragTo(0, commit: false);
  }

  void _animatePageDragTo(double endOffset, {required bool commit}) {
    final targetIndex = _pageDragTargetIndex;
    final simulationTarget = _simulationPageTarget;
    _pageTurnController.stop();
    _pageTurnController.reset();
    _commitPageTurnWhenSettled = commit;
    final serial = ++_pageTurnSerial;
    _pageTurnAnimation = Tween<double>(begin: _pageDragOffset, end: endOffset)
        .animate(
          CurvedAnimation(
            parent: _pageTurnController,
            curve: AppMotion.standard,
          ),
        );
    _pageTurnController.forward().then((_) {
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

  void _finishPageTurn(int targetIndex) {
    _switchChapter(targetIndex, startAtTop: false);
  }

  void _finishSimulationPageTurn(_SimulationPageTarget target) {
    if (target.chapterIndex != _chapterIndex) {
      _simulationPageTarget = null;
      _simulationPreviewController = null;
      _switchChapter(target.chapterIndex, startAtTop: false);
      return;
    }
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      _resetPageDrag();
      return;
    }

    final position = _scrollController.position;
    final targetOffset = target.offset
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final previousPreview = _simulationPreviewController;
    _simulationPreviewController = null;
    _simulationPageTarget = null;
    _discardPageTurnSnapshot();
    _pageTurnAnimation = null;
    _commitPageTurnWhenSettled = false;
    _pageDragTargetIndex = null;
    _setPageDragOffset(0);
    if ((position.pixels - targetOffset).abs() > 0.5) {
      _scrollController.jumpTo(targetOffset);
    }
    final snapshot = _currentScrollSnapshot();
    final progress = _recordCurrentChapterPosition(snapshot);
    setState(() {});
    _enqueueProgressSave(progress);
    if (previousPreview != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousPreview.dispose();
      });
    }
    _scheduleSimulationSnapshotWarmup();
  }

  void _showChapterList() {
    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: AnimationStyle(
        duration: AppMotion.sheet,
        reverseDuration: AppMotion.normal,
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.3,
        builder: (_, scrollController) => ChapterListSheet(
          chapters: _book.chapters,
          currentChapter: _chapterIndex,
          scrollController: scrollController,
          colors: themeColors,
          wordCountListenable: _wordCountNotifier,
          chapterWordCountsListenable: _chapterWordCountsNotifier,
          collapsedGroupIds: _collapsedTocGroupIds,
          onGroupExpansionChanged: _handleTocGroupExpansionChanged,
          onSelect: (index) {
            _openChapter(index);
          },
        ),
      ),
    );
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

  void _showSettings() {
    var sheetSettings = _settings;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
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
  }

  void _showReaderMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_settingsLoaded) {
      final loadingColors =
          widget.transitionColors?.value ??
          AppTheme.getReaderTheme(
            ReaderThemeMode.system,
            systemBrightness: MediaQuery.platformBrightnessOf(context),
          );
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemUiOverlayStyle(loadingColors),
        child: Scaffold(
          backgroundColor: loadingColors.background,
          body: Center(
            child: CircularProgressIndicator(color: loadingColors.accent),
          ),
        ),
      );
    }

    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );

    if (_book.chapters.isEmpty) {
      final content = Scaffold(
        backgroundColor: themeColors.background,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    color: themeColors.accent,
                    size: 40,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '这本书没有可阅读的正文',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: themeColors.text,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '请返回书架后重新导入文件。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: themeColors.secondary),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  ElevatedButton(
                    onPressed: _closeReader,
                    child: const Text('返回书架'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemUiOverlayStyle(themeColors),
        child: content,
      );
    }

    final fontFamily = _settings.effectiveFontFamily;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    // Snapshot the initial top inset once so the layout stays fixed when the
    // status bar is hidden after the book-opening animation settles.
    if (_viewPaddingTop == 0 && viewPadding.top > 0) {
      _viewPaddingTop = viewPadding.top;
    }
    final stableTopInset = _viewPaddingTop > 0
        ? _viewPaddingTop
        : viewPadding.top;
    final horizontalPadding = _settings.pageMargin.horizontalPadding;

    final content = PopScope(
      canPop: _closingReader,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _closeReader();
      },
      child: Scaffold(
        backgroundColor: themeColors.background,
        body: Stack(
          children: [
            // ── Stable reader background ─────────────
            // The book-opening route draws the visible shared-element
            // choreography. This layer simply guarantees an opaque reading
            // surface once the transition has expanded to full screen.
            Positioned.fill(child: ColoredBox(color: themeColors.background)),

            // ── Reading content ─────────────────────
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _handleReadingPointerDown,
                  onPointerMove: (event) =>
                      _handleReadingPointerMove(event, width),
                  onPointerUp: (event) => _handleReadingPointerUp(event, width),
                  onPointerCancel: _handleReadingPointerCancel,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart:
                        _settings.readingMode != ReaderReadingMode.chapter
                        ? null
                        : _handleHorizontalDragStart,
                    onHorizontalDragUpdate:
                        _settings.readingMode != ReaderReadingMode.chapter
                        ? null
                        : (details) =>
                              _handleHorizontalDragUpdate(details, width),
                    onHorizontalDragEnd:
                        _settings.readingMode != ReaderReadingMode.chapter
                        ? null
                        : (details) => _handleHorizontalDragEnd(details, width),
                    onHorizontalDragCancel:
                        _settings.readingMode != ReaderReadingMode.chapter
                        ? null
                        : _handleHorizontalDragCancel,
                    child: AnimatedContainer(
                      duration: AppMotion.normal,
                      curve: AppMotion.standard,
                      color: themeColors.background,
                      child: ClipRect(
                        child: _buildReadingModeView(
                          width: width,
                          height: constraints.maxHeight,
                          themeColors: themeColors,
                          fontFamily: fontFamily,
                          viewPadding: viewPadding.copyWith(
                            top: stableTopInset,
                          ),
                          horizontalPadding: horizontalPadding,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

            // ── Reading progress ─────────────────────
            // Always visible, independent of _showOverlay — gives a sense of
            // progress without needing to summon the header/footer bars.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ReadingProgressBar(
                progress: _visibleProgressNotifier,
                trackColor: themeColors.border,
                fillColor: AppTheme.accent,
              ),
            ),

            // ── Header bar ──────────────────────────
            Positioned(
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
                        padding: EdgeInsets.only(top: stableTopInset),
                        decoration: BoxDecoration(
                          color: themeColors.headerBg,
                          border: Border(
                            bottom: BorderSide(
                              color: themeColors.border,
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: Row(
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
                                    _formatChapterTitle(_currentChapter.title),
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
                            const SizedBox(
                              width: 48,
                            ), // Balance the back button
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Bottom bar ──────────────────────────
            Positioned(
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
                          top: AppSpacing.md,
                          left: AppSpacing.xl,
                          right: AppSpacing.xl,
                        ),
                        decoration: BoxDecoration(
                          color: themeColors.headerBg,
                          border: Border(
                            top: BorderSide(
                              color: themeColors.border,
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: Row(
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
                              icon: Icons.text_fields,
                              label: '设置',
                              subtitle: '${_settings.fontSize.toInt()}pt',
                              onTap: _showSettings,
                              color: themeColors.secondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemUiOverlayStyle(themeColors),
      child: content,
    );
  }

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
        return _buildSmoothTurnPages(
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
    final slivers = <Widget>[];
    for (
      var chapterIndex = 0;
      chapterIndex < _book.chapters.length;
      chapterIndex++
    ) {
      final chapter = _book.chapters[chapterIndex];
      slivers.add(
        SliverMainAxisGroup(
          key: _continuousChapterKeys[chapterIndex],
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  chapterIndex == _continuousAnchorChapterIndex
                      ? viewPadding.top + AppSpacing.lg
                      : AppSpacing.xxl,
                  horizontalPadding,
                  AppSpacing.xl,
                ),
                child: Text(
                  _formatChapterTitle(chapter.title),
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
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverList.builder(
                itemCount: 1,
                itemBuilder: (context, _) {
                  final separator =
                      _settings.paragraphSpacing ==
                          ReaderParagraphSpacing.blankLine
                      ? '\n\n'
                      : '\n';
                  return Text(
                    _paragraphsFor(chapter).join(separator),
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: _settings.fontSize,
                      fontWeight: _settings.effectiveFontWeight,
                      shadows: _settings.effectiveFontShadows(themeColors.text),
                      height: _settings.lineHeight,
                      color: themeColors.text,
                      letterSpacing: 0.2,
                    ),
                  );
                },
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
        child: _DoubleTapFilteredSelectionArea(
          colors: themeColors,
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
        repaintBoundaryKey:
            target?.goingNext == false &&
                target?.chapterIndex == _chapterIndex - 1
            ? _incomingPageBoundaryKey
            : null,
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
      if (target.chapterIndex == _chapterIndex) {
        final controller = _simulationPreviewController;
        if (controller != null) {
          targetPage = _buildChapterPage(
            chapter: _currentChapter,
            themeColors: themeColors,
            fontFamily: fontFamily,
            viewPadding: viewPadding,
            horizontalPadding: horizontalPadding,
            controller: controller,
            repaintBoundaryKey: target.goingNext
                ? null
                : _incomingPageBoundaryKey,
            physics: pagePhysics,
            simulationPage: true,
          );
        }
      } else if (target.goingNext) {
        targetPage = nextBoundaryPage;
      } else {
        targetPage = previousBoundaryPage;
      }
    }

    final previousPage = target?.goingNext == false
        ? targetPage
        : target == null
        ? previousBoundaryPage
        : null;
    final nextPage = target?.goingNext == true
        ? targetPage
        : target == null
        ? nextBoundaryPage
        : null;

    return ValueListenableBuilder<double>(
      valueListenable: _pageDragOffsetNotifier,
      builder: (context, offset, _) {
        return switch (_settings.simulationPageTurnEffect) {
          SimulationPageTurnEffect.simulation => _buildCurledBookTurnPages(
            width: width,
            dragOffset: offset,
            currentPage: currentPage,
            previousPage: previousPage,
            nextPage: nextPage,
            themeColors: themeColors,
          ),
          SimulationPageTurnEffect.smooth => _buildSmoothTurnPages(
            width: width,
            dragOffset: offset,
            currentPage: currentPage,
            previousPage: previousPage,
            nextPage: nextPage,
          ),
        };
      },
    );
  }

  Widget _buildSmoothTurnPages({
    required double width,
    required double dragOffset,
    required Widget currentPage,
    required Widget? previousPage,
    required Widget? nextPage,
  }) {
    return Stack(
      children: [
        if (previousPage != null)
          KeyedSubtree(
            key: const ValueKey('previous-page'),
            child: Transform.translate(
              offset: Offset(dragOffset - width, 0),
              child: _inactivePage(previousPage),
            ),
          ),
        if (nextPage != null)
          KeyedSubtree(
            key: const ValueKey('next-page'),
            child: Transform.translate(
              offset: Offset(dragOffset + width, 0),
              child: _inactivePage(nextPage),
            ),
          ),
        KeyedSubtree(
          key: const ValueKey('current-page'),
          child: Transform.translate(
            offset: Offset(dragOffset, 0),
            child: currentPage,
          ),
        ),
      ],
    );
  }

  Widget _buildCurledBookTurnPages({
    required double width,
    required double dragOffset,
    required Widget currentPage,
    required Widget? previousPage,
    required Widget? nextPage,
    required ReaderThemeColors themeColors,
  }) {
    final progress = (dragOffset.abs() / width).clamp(0.0, 1.0);
    final goingNext = dragOffset <= 0;
    final targetPage = goingNext ? nextPage : previousPage;
    final hasTarget = progress > 0.001 && targetPage != null;
    if (!hasTarget) {
      return currentPage;
    }

    final direction = goingNext
        ? _LeafTurnDirection.forward
        : _LeafTurnDirection.previousCover;
    final paperBackSnapshot = goingNext
        ? _pageTurnSnapshot
        : _incomingPageSnapshot;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (goingNext)
          KeyedSubtree(
            key: const ValueKey('physical-next-page'),
            child: _inactivePage(targetPage),
          )
        else
          KeyedSubtree(
            key: const ValueKey('physical-current-page-base'),
            child: currentPage,
          ),
        if (goingNext)
          KeyedSubtree(
            key: const ValueKey('physical-forward-sheet'),
            child: ClipPath(
              clipper: _ForwardLeafFrontClipper(
                progress: progress,
                curlAnchorY: _pageCurlAnchorY,
              ),
              child: currentPage,
            ),
          )
        else
          KeyedSubtree(
            key: const ValueKey('physical-previous-sheet-cover'),
            child: ClipPath(
              clipper: _PreviousLeafFrontClipper(
                progress: progress,
                curlAnchorY: _pageCurlAnchorY,
              ),
              child: _inactivePage(targetPage),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BookLeafCurlPainter(
                progress: progress,
                direction: direction,
                pageColor: themeColors.background,
                curlAnchorY: _pageCurlAnchorY,
                paperBackSnapshot: paperBackSnapshot,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _inactivePage(Widget child) {
    return ExcludeSemantics(child: IgnorePointer(child: child));
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
    final lineExtent = _settings.fontSize * _settings.lineHeight;
    final paragraphGap =
        _settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? lineExtent
        : 0.0;
    final itemCount = paragraphs.length + 2;
    final scrollView = ListView.builder(
      key: ValueKey<String>(
        'chapter-${identityHashCode(chapter)}-${controller != null}',
      ),
      controller: controller,
      primary: false,
      physics: physics,
      scrollCacheExtent: const ScrollCacheExtent.pixels(900),
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        simulationPage ? 0 : viewPadding.top + AppSpacing.lg,
        horizontalPadding,
        simulationPage ? 0 : viewPadding.bottom + 80,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: simulationPage ? lineExtent : AppSpacing.xl,
            ),
            child: AnimatedDefaultTextStyle(
              duration: AppMotion.normal,
              curve: AppMotion.standard,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: themeColors.text,
                height: simulationPage ? lineExtent / 20 : 1.5,
              ),
              child: Text(
                _formatChapterTitle(chapter.title),
                strutStyle: simulationPage
                    ? StrutStyle(
                        fontFamily: fontFamily,
                        fontSize: 20,
                        height: lineExtent / 20,
                        fontWeight: FontWeight.w600,
                        forceStrutHeight: true,
                      )
                    : null,
              ),
            ),
          );
        }
        if (index == itemCount - 1) {
          return SizedBox(height: simulationPage ? lineExtent : AppSpacing.xxl);
        }

        final paragraphIndex = index - 1;
        return Padding(
          padding: EdgeInsets.only(
            bottom: paragraphIndex == paragraphs.length - 1 ? 0 : paragraphGap,
          ),
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: _settings.fontSize,
              fontWeight: _settings.effectiveFontWeight,
              shadows: _settings.effectiveFontShadows(themeColors.text),
              height: _settings.lineHeight,
              color: themeColors.text,
              letterSpacing: 0.2,
            ),
            child: Text(
              paragraphs[paragraphIndex],
              strutStyle: simulationPage
                  ? StrutStyle(
                      fontFamily: fontFamily,
                      fontSize: _settings.fontSize,
                      height: _settings.lineHeight,
                      fontWeight: _settings.effectiveFontWeight,
                      forceStrutHeight: true,
                    )
                  : null,
            ),
          ),
        );
      },
    );

    Widget readingContent = _DoubleTapFilteredSelectionArea(
      colors: themeColors,
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
                    '章节 ${chapter.index + 1}/${_book.chapters.length} · ${_formatChapterTitle(chapter.title)}',
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
              vertical: AppSpacing.xs,
              horizontal: AppSpacing.md,
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 2),
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

class _DoubleTapFilteredSelectionArea extends StatefulWidget {
  final Widget child;
  final ReaderThemeColors colors;

  const _DoubleTapFilteredSelectionArea({
    required this.child,
    required this.colors,
  });

  @override
  State<_DoubleTapFilteredSelectionArea> createState() =>
      _DoubleTapFilteredSelectionAreaState();
}

class _TextActionChoice {
  final SystemTextActionTarget target;
  final bool remember;

  const _TextActionChoice({required this.target, required this.remember});
}

class _DoubleTapFilteredSelectionAreaState
    extends State<_DoubleTapFilteredSelectionArea> {
  static const _tapSlop = 18.0;
  static const _doubleTapSlop = 100.0;
  static const _doubleTapTimeout = Duration(milliseconds: 300);
  static const _aiIconAssets = <String, String>{
    'deepseek': 'assets/images/ai/deepseek.webp',
    'chatgpt': 'assets/images/ai/chatgpt.webp',
    'gemini': 'assets/images/ai/gemini.webp',
    'claude': 'assets/images/ai/claude.webp',
    'copilot': 'assets/images/ai/copilot.webp',
    'perplexity': 'assets/images/ai/perplexity.webp',
  };

  final _selectionAreaKey = GlobalKey<SelectionAreaState>();
  int? _pointer;
  Offset? _downPosition;
  Duration? _downTime;
  bool _moved = false;
  bool _secondTapCandidate = false;
  Duration? _lastTapUpTime;
  Offset? _lastTapUpPosition;
  bool _suppressSelection = false;
  bool _clearScheduled = false;
  SelectedContent? _selectedContent;
  Timer? _suppressionTimer;

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _downPosition = event.position;
    _downTime = event.timeStamp;
    _moved = false;
    final lastTime = _lastTapUpTime;
    final lastPosition = _lastTapUpPosition;
    final gap = lastTime == null ? null : event.timeStamp - lastTime;
    _secondTapCandidate =
        gap != null &&
        !gap.isNegative &&
        gap <= _doubleTapTimeout &&
        lastPosition != null &&
        (event.position - lastPosition).distance <= _doubleTapSlop;
    if (_secondTapCandidate) {
      _lastTapUpTime = null;
      _lastTapUpPosition = null;
      _suppressSelection = true;
      _suppressionTimer?.cancel();
      // A long press selects after this window has elapsed, so long-press copy
      // remains available even when it begins shortly after a normal tap.
      _suppressionTimer = Timer(
        _doubleTapTimeout,
        () => _suppressSelection = false,
      );
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _moved) return;
    final downPosition = _downPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > _tapSlop) {
      _moved = true;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final downTime = _downTime;
    final shortTap =
        !_moved &&
        downTime != null &&
        event.timeStamp - downTime <= const Duration(milliseconds: 600);
    if (shortTap && !_secondTapCandidate) {
      _lastTapUpTime = event.timeStamp;
      _lastTapUpPosition = event.position;
    } else if (!shortTap) {
      _lastTapUpTime = null;
      _lastTapUpPosition = null;
    }
    _clearPointerState();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _clearPointerState();
  }

  void _clearPointerState() {
    _pointer = null;
    _downPosition = null;
    _downTime = null;
    _moved = false;
    _secondTapCandidate = false;
  }

  void _handleSelectionChanged(SelectedContent? content) {
    _selectedContent = content;
    if (content == null || !_suppressSelection || _clearScheduled) return;
    _clearScheduled = true;
    scheduleMicrotask(() {
      _clearScheduled = false;
      if (!mounted || !_suppressSelection) return;
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    });
  }

  ContextMenuButtonItem? _buttonOfType(
    List<ContextMenuButtonItem> buttons,
    ContextMenuButtonType type,
  ) {
    for (final button in buttons) {
      if (button.type == type) return button;
    }
    return null;
  }

  Future<void> _runSystemTextAction({required bool translate}) async {
    final selectedText = _selectedContent?.plainText.trim();
    ContextMenuController.removeAny();
    if (selectedText == null || selectedText.isEmpty) return;
    final action = translate
        ? SystemTextActionType.translate
        : SystemTextActionType.search;
    try {
      final targets = await SystemTextActionService.getTargets(action);
      if (!mounted) return;
      final defaultTargetId = await SystemTextActionService.getDefaultTargetId(
        action,
      );
      if (!mounted) return;

      SystemTextActionTarget? defaultTarget;
      for (final target in targets) {
        if (target.id == defaultTargetId && target.available) {
          defaultTarget = target;
          break;
        }
      }
      if (defaultTarget != null) {
        final launched = await SystemTextActionService.launch(
          action: action,
          target: defaultTarget,
          text: selectedText,
        );
        if (launched) return;
        await SystemTextActionService.setDefaultTargetId(action, null);
      }
      if (!mounted) return;

      final choice = await _showTextActionPicker(
        context,
        action: action,
        targets: targets,
      );
      if (choice == null || !mounted) return;
      final launched = await SystemTextActionService.launch(
        action: action,
        target: choice.target,
        text: selectedText,
      );
      if (launched && choice.remember) {
        await SystemTextActionService.setDefaultTargetId(
          action,
          choice.target.id,
        );
      }
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(translate ? '所选 AI 应用无法接收翻译内容' : '所选浏览器无法打开搜索'),
          ),
        );
      }
    } on PlatformException catch (error, stackTrace) {
      debugPrint('Failed to launch a system text action: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('无法打开所选外部应用'),
          ),
        );
      }
    }
  }

  Future<_TextActionChoice?> _showTextActionPicker(
    BuildContext context, {
    required SystemTextActionType action,
    required List<SystemTextActionTarget> targets,
  }) async {
    final availableTargets = targets.where((target) => target.available);
    if (availableTargets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            action == SystemTextActionType.translate
                ? '没有检测到可接收文字的 AI 应用'
                : '没有可用的浏览器',
          ),
        ),
      );
      return null;
    }

    var selectedId = availableTargets.first.id;
    var remember = false;
    return showModalBottomSheet<_TextActionChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final selected = targets.firstWhere(
            (target) => target.id == selectedId,
          );
          return SafeArea(
            child: Container(
              margin: const EdgeInsets.all(AppSpacing.md),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: widget.colors.headerBg,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: widget.colors.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action == SystemTextActionType.translate
                        ? '选择 AI 翻译应用'
                        : '选择搜索浏览器',
                    style: TextStyle(
                      color: widget.colors.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    action == SystemTextActionType.translate
                        ? '左右滑动选择已安装且可以接收文字的 AI 应用'
                        : '左右滑动选择 edge、chrome 或系统浏览器',
                    style: TextStyle(
                      color: widget.colors.secondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    height: 120,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      itemCount: targets.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: AppSpacing.sm),
                      itemBuilder: (context, index) {
                        final target = targets[index];
                        return _buildTextActionTargetCard(
                          target: target,
                          selected: target.id == selectedId,
                          action: action,
                          onTap: target.available
                              ? () =>
                                    setSheetState(() => selectedId = target.id)
                              : null,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  CheckboxListTile(
                    value: remember,
                    onChanged: (value) =>
                        setSheetState(() => remember = value ?? false),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: widget.colors.accent,
                    checkColor: Colors.white,
                    title: Text(
                      '记住并默认打开',
                      style: TextStyle(
                        color: widget.colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '下次点击${action == SystemTextActionType.translate ? '翻译' : '搜索'}时直接跳转',
                      style: TextStyle(
                        color: widget.colors.secondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                        sheetContext,
                        _TextActionChoice(target: selected, remember: remember),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: widget.colors.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md,
                        ),
                      ),
                      child: Text(
                        action == SystemTextActionType.translate
                            ? '发送给 ${selected.label}'
                            : '使用 ${selected.label} 搜索',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTextActionTargetCard({
    required SystemTextActionTarget target,
    required bool selected,
    required SystemTextActionType action,
    required VoidCallback? onTap,
  }) {
    final translating = action == SystemTextActionType.translate;
    final foreground = target.available
        ? widget.colors.text
        : widget.colors.secondary.withValues(alpha: 0.52);
    final accent = selected ? widget.colors.accent : widget.colors.border;
    final cardWidth = translating ? 104.0 : 112.0;
    final iconAsset = _aiIconAssets[target.id];

    return Semantics(
      button: true,
      selected: selected,
      enabled: target.available,
      label: '${target.label}${target.available ? '' : '，未安装'}',
      onTap: onTap,
      child: AnimatedScale(
        scale: selected ? 1 : 0.965,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: cardWidth,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? widget.colors.accent.withValues(alpha: 0.11)
                      : widget.colors.background.withValues(alpha: 0.58),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(
                    color: accent,
                    width: selected ? 1.6 : 0.8,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: widget.colors.accent.withValues(alpha: 0.14),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Opacity(
                  opacity: target.available ? 1 : 0.42,
                  child: translating
                      ? _buildAiTargetCardContent(
                          target: target,
                          selected: selected,
                          foreground: foreground,
                          iconAsset: iconAsset,
                        )
                      : _buildSearchTargetCardContent(
                          target: target,
                          selected: selected,
                          foreground: foreground,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAiTargetCardContent({
    required SystemTextActionTarget target,
    required bool selected,
    required Color foreground,
    required String? iconAsset,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (iconAsset != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              iconAsset,
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          target.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: foreground,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          selected ? '已选择' : '点按选择',
          style: TextStyle(
            color: selected ? widget.colors.accent : widget.colors.secondary,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildSearchTargetCardContent({
    required SystemTextActionTarget target,
    required bool selected,
    required Color foreground,
  }) {
    final displayName = target.id == 'system' ? '系统' : target.label;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'SEARCH WITH',
          style: TextStyle(
            color: widget.colors.secondary,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.15,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: foreground,
            fontSize: target.id == 'system' ? 19 : 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: selected ? 44 : 24,
          height: 3,
          decoration: BoxDecoration(
            color: selected
                ? widget.colors.accent
                : widget.colors.secondary.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          target.available ? (selected ? '已选择' : '浏览器') : '未安装',
          style: TextStyle(
            color: selected ? widget.colors.accent : widget.colors.secondary,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildContextMenu(BuildContext context, SelectableRegionState state) {
    final defaults = state.contextMenuButtonItems;
    final copy = _buttonOfType(defaults, ContextMenuButtonType.copy);
    final share = _buttonOfType(defaults, ContextMenuButtonType.share);
    final selectAll = _buttonOfType(defaults, ContextMenuButtonType.selectAll);
    final buttons = <ContextMenuButtonItem>[
      if (copy != null) copy.copyWith(label: '复制'),
      if (share != null) share.copyWith(label: '分享'),
      if (selectAll != null) selectAll.copyWith(label: '全选'),
      ContextMenuButtonItem(
        label: '翻译',
        onPressed: () => unawaited(_runSystemTextAction(translate: true)),
      ),
      ContextMenuButtonItem(
        label: '搜索',
        onPressed: () => unawaited(_runSystemTextAction(translate: false)),
      ),
    ];
    final baseTheme = Theme.of(context);
    return Theme(
      data: baseTheme.copyWith(
        colorScheme: baseTheme.colorScheme.copyWith(
          primary: widget.colors.accent,
          surface: widget.colors.headerBg,
          onSurface: widget.colors.text,
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: widget.colors.text,
            textStyle: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ),
      child: AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: buttons,
      ),
    );
  }

  @override
  void dispose() {
    _suppressionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: SelectionArea(
        key: _selectionAreaKey,
        onSelectionChanged: _handleSelectionChanged,
        contextMenuBuilder: _buildContextMenu,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Winning this arena prevents the usual double-tap word selection.
          // The selection callback above is a second guard for platform gesture
          // implementations that resolve the selectable region first.
          onDoubleTap: () {},
          child: widget.child,
        ),
      ),
    );
  }
}

class _SimulationPageTarget {
  final int chapterIndex;
  final double offset;
  final double progress;
  final bool goingNext;

  const _SimulationPageTarget({
    required this.chapterIndex,
    required this.offset,
    required this.progress,
    required this.goingNext,
  });

  bool matches(_SimulationPageTarget other) {
    return chapterIndex == other.chapterIndex &&
        goingNext == other.goingNext &&
        (offset - other.offset).abs() < 0.5;
  }
}

class _ScrollSnapshot {
  final double offset;
  final double progress;

  const _ScrollSnapshot({required this.offset, required this.progress});
}

enum _LeafTurnDirection { forward, previousCover }

class _ForwardLeafFrontClipper extends CustomClipper<Path> {
  final double progress;
  final double curlAnchorY;

  const _ForwardLeafFrontClipper({
    required this.progress,
    required this.curlAnchorY,
  });

  @override
  Path getClip(Size size) => _ForwardLeafGeometry.calculate(
    size: size,
    progress: progress,
    curlAnchorY: curlAnchorY,
  ).frontPath;

  @override
  bool shouldReclip(covariant _ForwardLeafFrontClipper oldClipper) {
    return oldClipper.progress != progress ||
        oldClipper.curlAnchorY != curlAnchorY;
  }
}

/// The previous leaf is constructed as an incoming sheet from the left. It is
/// deliberately not the forward leaf played backwards: the current page stays
/// still underneath while the previous page's front settles over it.
class _PreviousLeafFrontClipper extends CustomClipper<Path> {
  final double progress;
  final double curlAnchorY;

  const _PreviousLeafFrontClipper({
    required this.progress,
    required this.curlAnchorY,
  });

  @override
  Path getClip(Size size) => _PreviousLeafCoverGeometry.calculate(
    size: size,
    progress: progress,
    curlAnchorY: curlAnchorY,
  ).frontPath;

  @override
  bool shouldReclip(covariant _PreviousLeafFrontClipper oldClipper) {
    return oldClipper.progress != progress ||
        oldClipper.curlAnchorY != curlAnchorY;
  }
}

class _BookLeafCurlPainter extends CustomPainter {
  final double progress;
  final _LeafTurnDirection direction;
  final Color pageColor;
  final double curlAnchorY;
  final ui.Image? paperBackSnapshot;

  const _BookLeafCurlPainter({
    required this.progress,
    required this.direction,
    required this.pageColor,
    required this.curlAnchorY,
    required this.paperBackSnapshot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final p = progress.clamp(0.0, 1.0).toDouble();
    if (p <= 0 || p >= 1) return;
    final geometry = direction == _LeafTurnDirection.forward
        ? _ForwardLeafGeometry.calculate(
            size: size,
            progress: p,
            curlAnchorY: curlAnchorY,
          )
        : _PreviousLeafCoverGeometry.calculate(
            size: size,
            progress: p,
            curlAnchorY: curlAnchorY,
          );
    final strength = geometry.curlStrength;
    if (strength <= 0.001) return;

    _paintLeafShadow(canvas, geometry, strength);
    _paintFrontCreaseShade(canvas, geometry, strength);
    canvas.drawShadow(
      geometry.backPath,
      Colors.black.withValues(alpha: 0.34 * strength),
      10 + 16 * strength,
      false,
    );
    _paintPaperBack(canvas, size, geometry, strength);
  }

  void _paintLeafShadow(
    Canvas canvas,
    _BookLeafGeometry geometry,
    double strength,
  ) {
    canvas.drawPath(
      geometry.outerEdgePath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.24 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16 + 12 * strength
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  }

  void _paintFrontCreaseShade(
    Canvas canvas,
    _BookLeafGeometry geometry,
    double strength,
  ) {
    canvas
      ..save()
      ..clipPath(geometry.frontPath)
      ..drawPath(
        geometry.creasePath,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.15 * strength)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 18 + 16 * strength
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 11),
      )
      ..restore();
  }

  void _paintPaperBack(
    Canvas canvas,
    Size size,
    _BookLeafGeometry geometry,
    double strength,
  ) {
    final bounds = geometry.backPath.getBounds().intersect(Offset.zero & size);
    if (bounds.width <= 0.1 || bounds.height <= 0.1) return;

    final isDarkPage = pageColor.computeLuminance() < 0.25;
    final paper = Color.lerp(
      pageColor,
      Colors.white,
      isDarkPage ? 0.025 : 0.06,
    )!;
    canvas.drawPath(geometry.backPath, Paint()..color = paper);

    final snapshot = paperBackSnapshot;
    if (snapshot != null) {
      // Reflect the actual rendered page around the diagonal fold chord. The
      // snapshot contains the live header, title, body, font, theme and exact
      // scroll offset, so the reverse side carries the ink from this leaf
      // instead of a decorative placeholder texture.
      final inkTransmission = isDarkPage ? 0.66 : 0.54;
      final creaseStart = geometry.creaseStart;
      final creaseEnd = geometry.creaseEnd;
      final creaseAngle = math.atan2(
        creaseEnd.dy - creaseStart.dy,
        creaseEnd.dx - creaseStart.dx,
      );
      canvas
        ..save()
        ..clipPath(geometry.backPath)
        ..translate(creaseStart.dx, creaseStart.dy)
        ..rotate(creaseAngle)
        ..scale(1, -1)
        ..rotate(-creaseAngle)
        ..translate(-creaseStart.dx, -creaseStart.dy)
        ..drawImageRect(
          snapshot,
          Rect.fromLTWH(
            0,
            0,
            snapshot.width.toDouble(),
            snapshot.height.toDouble(),
          ),
          Offset.zero & size,
          Paint()
            ..filterQuality = FilterQuality.high
            ..colorFilter = ColorFilter.matrix(<double>[
              1,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              0,
              inkTransmission,
              0,
            ]),
        )
        ..restore();
      canvas.drawPath(
        geometry.backPath,
        Paint()..color = paper.withValues(alpha: isDarkPage ? 0.16 : 0.20),
      );
    }

    final highlightOnLeft = direction == _LeafTurnDirection.previousCover;
    final lighting = LinearGradient(
      begin: highlightOnLeft ? Alignment.centerRight : Alignment.centerLeft,
      end: highlightOnLeft ? Alignment.centerLeft : Alignment.centerRight,
      colors: [
        Colors.black.withValues(alpha: 0.19 * strength),
        Colors.white.withValues(alpha: 0.24 * strength),
        Colors.transparent,
        Colors.black.withValues(alpha: 0.22 * strength),
      ],
      stops: const [0, 0.24, 0.66, 1],
    ).createShader(bounds);
    canvas
      ..save()
      ..clipPath(geometry.backPath)
      ..drawRect(bounds, Paint()..shader = lighting)
      ..restore();

    canvas.drawPath(
      geometry.outerEdgePath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25,
    );
    canvas.drawPath(
      geometry.creasePath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.34 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25,
    );
    canvas.drawPath(
      geometry.creasePath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.12 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4),
    );
  }

  @override
  bool shouldRepaint(covariant _BookLeafCurlPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.direction != direction ||
        oldDelegate.pageColor != pageColor ||
        oldDelegate.curlAnchorY != curlAnchorY ||
        oldDelegate.paperBackSnapshot != paperBackSnapshot;
  }
}

class _BookLeafGeometry {
  final Path frontPath;
  final Path backPath;
  final Path creasePath;
  final Path outerEdgePath;
  final Offset creaseStart;
  final Offset creaseEnd;
  final double curlStrength;

  const _BookLeafGeometry({
    required this.frontPath,
    required this.backPath,
    required this.creasePath,
    required this.outerEdgePath,
    required this.creaseStart,
    required this.creaseEnd,
    required this.curlStrength,
  });
}

class _ForwardLeafGeometry {
  static _BookLeafGeometry calculate({
    required Size size,
    required double progress,
    required double curlAnchorY,
  }) {
    final width = size.width;
    final height = size.height;
    final p = progress.clamp(0.0, 1.0).toDouble();
    final curl = _curlEnvelope(p);
    final anchor = _normalizedCurlAnchor(height, curlAnchorY);
    final cornerSign = anchor >= 0.5 ? 1.0 : -1.0;
    final center = width * (1 - p);
    final anchorBias = ((anchor - 0.5).abs() * 2).clamp(0.0, 1.0);
    final diagonal = width * (0.20 + 0.10 * anchorBias) * curl;
    final curve = width * 0.075 * curl;

    double creaseX(double value) => value.clamp(0.0, width).toDouble();

    final creaseTop = Offset(creaseX(center + diagonal * cornerSign), 0);
    final creaseBottom = Offset(
      creaseX(center - diagonal * cornerSign),
      height,
    );
    final creaseControlTop = Offset(
      creaseTop.dx - curve * cornerSign,
      height * 0.30,
    );
    final creaseControlBottom = Offset(
      creaseBottom.dx + curve * cornerSign,
      height * 0.70,
    );
    final creasePath = Path()
      ..moveTo(creaseTop.dx, creaseTop.dy)
      ..cubicTo(
        creaseControlTop.dx,
        creaseControlTop.dy,
        creaseControlBottom.dx,
        creaseControlBottom.dy,
        creaseBottom.dx,
        creaseBottom.dy,
      );
    final front = Path()
      ..moveTo(0, 0)
      ..lineTo(creaseTop.dx, creaseTop.dy)
      ..cubicTo(
        creaseControlTop.dx,
        creaseControlTop.dy,
        creaseControlBottom.dx,
        creaseControlBottom.dy,
        creaseBottom.dx,
        creaseBottom.dy,
      )
      ..lineTo(0, height)
      ..close();

    // Reflect the original right edge across the fold. Unlike the old narrow
    // vertical strip, this produces a broad diagonal reverse side that sweeps
    // across the screen like a flexible paper leaf.
    final edgeTop = Offset(creaseTop.dx * 2 - width, 0);
    final edgeBottom = Offset(creaseBottom.dx * 2 - width, height);
    final edgeControlTop = Offset(
      edgeTop.dx + curve * 1.15 * cornerSign,
      height * 0.30,
    );
    final edgeControlBottom = Offset(
      edgeBottom.dx - curve * 1.15 * cornerSign,
      height * 0.70,
    );
    final outerEdge = Path()
      ..moveTo(edgeTop.dx, edgeTop.dy)
      ..cubicTo(
        edgeControlTop.dx,
        edgeControlTop.dy,
        edgeControlBottom.dx,
        edgeControlBottom.dy,
        edgeBottom.dx,
        edgeBottom.dy,
      );
    final back = Path()
      ..addPath(creasePath, Offset.zero)
      ..lineTo(edgeBottom.dx, edgeBottom.dy)
      ..cubicTo(
        edgeControlBottom.dx,
        edgeControlBottom.dy,
        edgeControlTop.dx,
        edgeControlTop.dy,
        edgeTop.dx,
        edgeTop.dy,
      )
      ..close();

    return _BookLeafGeometry(
      frontPath: front,
      backPath: back,
      creasePath: creasePath,
      outerEdgePath: outerEdge,
      creaseStart: creaseTop,
      creaseEnd: creaseBottom,
      curlStrength: curl,
    );
  }
}

class _PreviousLeafCoverGeometry {
  static _BookLeafGeometry calculate({
    required Size size,
    required double progress,
    required double curlAnchorY,
  }) {
    final width = size.width;
    final height = size.height;
    final p = progress.clamp(0.0, 1.0).toDouble();
    final curl = _curlEnvelope(p);
    final anchor = _normalizedCurlAnchor(height, curlAnchorY);
    final cornerSign = anchor >= 0.5 ? 1.0 : -1.0;
    final center = width * p;
    final anchorBias = ((anchor - 0.5).abs() * 2).clamp(0.0, 1.0);
    final diagonal = width * (0.20 + 0.10 * anchorBias) * curl;
    final curve = width * 0.078 * curl;

    double creaseX(double value) => value.clamp(0.0, width).toDouble();

    // This fold leans in the opposite direction from the forward leaf. The
    // previous page therefore arrives from the left and covers the stationary
    // current page instead of exposing it with a reversed outgoing animation.
    final creaseTop = Offset(creaseX(center - diagonal * cornerSign), 0);
    final creaseBottom = Offset(
      creaseX(center + diagonal * cornerSign),
      height,
    );
    final creaseControlTop = Offset(
      creaseTop.dx + curve * cornerSign,
      height * 0.30,
    );
    final creaseControlBottom = Offset(
      creaseBottom.dx - curve * cornerSign,
      height * 0.70,
    );
    final creasePath = Path()
      ..moveTo(creaseTop.dx, creaseTop.dy)
      ..cubicTo(
        creaseControlTop.dx,
        creaseControlTop.dy,
        creaseControlBottom.dx,
        creaseControlBottom.dy,
        creaseBottom.dx,
        creaseBottom.dy,
      );
    final front = Path()
      ..moveTo(0, 0)
      ..lineTo(creaseTop.dx, creaseTop.dy)
      ..cubicTo(
        creaseControlTop.dx,
        creaseControlTop.dy,
        creaseControlBottom.dx,
        creaseControlBottom.dy,
        creaseBottom.dx,
        creaseBottom.dy,
      )
      ..lineTo(0, height)
      ..close();

    // The incoming sheet's leading edge is the reflected left edge. At half
    // turn, its front and translucent back together span the viewport and lie
    // above the untouched current page.
    final edgeTop = Offset(creaseTop.dx * 2, 0);
    final edgeBottom = Offset(creaseBottom.dx * 2, height);
    final edgeControlTop = Offset(
      edgeTop.dx - curve * 1.15 * cornerSign,
      height * 0.30,
    );
    final edgeControlBottom = Offset(
      edgeBottom.dx + curve * 1.15 * cornerSign,
      height * 0.70,
    );
    final outerEdge = Path()
      ..moveTo(edgeTop.dx, edgeTop.dy)
      ..cubicTo(
        edgeControlTop.dx,
        edgeControlTop.dy,
        edgeControlBottom.dx,
        edgeControlBottom.dy,
        edgeBottom.dx,
        edgeBottom.dy,
      );
    final back = Path()
      ..addPath(creasePath, Offset.zero)
      ..lineTo(edgeBottom.dx, edgeBottom.dy)
      ..cubicTo(
        edgeControlBottom.dx,
        edgeControlBottom.dy,
        edgeControlTop.dx,
        edgeControlTop.dy,
        edgeTop.dx,
        edgeTop.dy,
      )
      ..close();

    return _BookLeafGeometry(
      frontPath: front,
      backPath: back,
      creasePath: creasePath,
      outerEdgePath: outerEdge,
      creaseStart: creaseTop,
      creaseEnd: creaseBottom,
      curlStrength: curl,
    );
  }
}

double _curlEnvelope(double progress) {
  final wave = math.sin(math.pi * progress).clamp(0.0, 1.0).toDouble();
  return math.pow(wave, 0.58).toDouble();
}

double _normalizedCurlAnchor(double height, double curlAnchorY) {
  if (height <= 0 || !curlAnchorY.isFinite) return 0.62;
  return (curlAnchorY / height).clamp(0.08, 0.92).toDouble();
}
