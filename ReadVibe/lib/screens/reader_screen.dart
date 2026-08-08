import 'dart:async';
import 'dart:collection';
import 'dart:io';
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
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/font_service.dart';
import '../services/book_search_service.dart';
import '../services/storage_service.dart';
import '../services/system_text_action_service.dart';
import '../services/word_count_service.dart';
import '../widgets/chapter_list.dart';
import '../widgets/book_search_sheet.dart';
import '../widgets/reader_settings_sheet.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/reading_progress_bar.dart';

const double _simulationPageExtentTolerance = 0.01;

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
  final ValueNotifier<bool> _selectionBlockedNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _textSelectionActiveNotifier = ValueNotifier(false);
  bool _readingModeReloading = false;
  // A modal with a text field (currently full-text search) can cause Android
  // to report a transient keyboard inset.  Simulation pagination is based on
  // the reader viewport, so never allow that transient inset to repaginate the
  // paper behind an open modal.
  bool _readerModalOpen = false;
  double? _simulationViewportLock;
  bool _closingReader = false;
  double _viewPaddingTop = 0;
  ReadingProgress? _currentProgress;
  Set<String> _collapsedTocGroupIds = <String>{};
  double? _pendingScrollOffset;
  double? _pendingScrollProgress;
  _ReadingTextAnchor? _pendingScrollTextAnchor;
  bool _preferPendingScrollProgress = false;
  int _scrollRestoreSerial = 0;
  final Map<int, ScrollController> _adjacentScrollControllers =
      <int, ScrollController>{};
  final Map<int, int> _adjacentScrollRestoreSerials = <int, int>{};
  int _overlayToggleSerial = 0;
  int? _pageTurnOriginChapterIndex;
  _ScrollSnapshot? _pageTurnOriginSnapshot;
  final GlobalKey _currentPageBoundaryKey = GlobalKey();
  final GlobalKey _reversePageBoundaryKey = GlobalKey();
  // The preview page moves between the offstage idle slot and the active
  // turn stack as the drag crosses the visibility threshold. A GlobalKey
  // lets Flutter reparent it without disposing the chapter ListView.
  final GlobalKey _simulationPreviewBoundaryKey = GlobalKey();
  ui.Image? _pageTurnSnapshot;
  Future<bool>? _pageTurnSnapshotCapture;
  int _pageTurnSnapshotSerial = 0;
  ui.Image? _reversePageTurnSnapshot;
  Future<bool>? _reversePageTurnSnapshotCapture;
  int _reversePageTurnSnapshotSerial = 0;
  late final List<GlobalKey> _continuousChapterKeys;
  int _continuousAnchorChapterIndex = 0;
  final Map<int, double> _continuousChapterStarts = <int, double>{};
  final Map<int, double> _continuousChapterExtents = <int, double>{};
  bool _continuousMetricsScheduled = false;
  int _continuousRestoreSerial = 0;
  double? _pendingContinuousProgress;
  double? _pendingContinuousOffset;
  _ReadingTextAnchor? _pendingContinuousTextAnchor;
  _SimulationPageTarget? _simulationPageTarget;
  ScrollController? _simulationPreviewController;
  ScrollController? _simulationPaperBackController;
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
  double _readerViewportWidth = 0;
  double _readerViewportHeight = 0;
  EdgeInsets _readerViewPadding = EdgeInsets.zero;
  TextScaler _readerTextScaler = TextScaler.noScaling;

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
    _textSelectionActiveNotifier.addListener(
      _handleTextSelectionActivityChanged,
    );
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
      await _storage.saveBookWordCount(_book, wordCount);
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

  ScrollController _createScrollController([
    double initialOffset = 0,
    bool? simulationPagination,
  ]) {
    final controller = _SelectionAwareScrollController(
      selectionActive: _textSelectionActiveNotifier,
      freezeSelectionViewport: () =>
          _settings.readingMode == ReaderReadingMode.simulation,
      paginateToFullViewports:
          simulationPagination ??
          _settings.readingMode == ReaderReadingMode.simulation,
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
    final controller = _previewScrollController(
      initialScrollOffset: initialOffset,
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
    int? serial,
  }) {
    // Retry attempts must carry the serial of the chain that spawned them.
    // Reading the map again here would let a stale chain adopt a newer
    // chain's serial and pass the validity check below.
    final effectiveSerial =
        serial ?? (_adjacentScrollRestoreSerials[chapterIndex] ?? 0) + 1;
    if (serial == null) {
      _adjacentScrollRestoreSerials[chapterIndex] = effectiveSerial;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _adjacentScrollRestoreSerials[chapterIndex] != effectiveSerial ||
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
            serial: effectiveSerial,
          );
        }
        return;
      }

      final maxExtent = controller.position.maxScrollExtent;
      final savedProgress =
          overrideProgress ?? _currentProgress?.chapterProgress[chapterIndex];
      final savedOffset = _currentProgress?.chapterOffsets[chapterIndex] ?? 0;
      var target = savedProgress != null && savedProgress.isFinite
          ? savedProgress.clamp(0.0, 1.0).toDouble() * maxExtent
          : (savedOffset.isFinite && savedOffset >= 0 ? savedOffset : 0.0)
                .clamp(0.0, maxExtent)
                .toDouble();
      if (_settings.readingMode == ReaderReadingMode.simulation) {
        target = _alignSimulationOffset(
          target,
          pageExtent: controller.position.viewportDimension,
          maxExtent: maxExtent,
        );
      }
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

  /// What the drag preview is actually showing. When a turn commits, this is
  /// the page the user sees under the settling animation, so the committed
  /// chapter must land exactly here.
  _ScrollSnapshot? _simulationPreviewSnapshot(int chapterIndex) {
    if (_simulationPageTarget?.chapterIndex != chapterIndex) return null;
    final controller = _simulationPreviewController;
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
    // Never hide the status bar while the reader chrome is open. The timer
    // scheduled right after the book-opening animation can fire after the
    // user has already summoned the menu, and must not win that race.
    if (!mounted || _closingReader || _showOverlay) return;
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
        offset: safeRestoredOffset,
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
    _ReadingTextAnchor? textAnchor,
  }) {
    _pendingScrollOffset = offset.isFinite && offset >= 0 ? offset : 0;
    _pendingScrollProgress = progress != null && progress.isFinite
        ? progress.clamp(0.0, 1.0).toDouble()
        : null;
    _preferPendingScrollProgress = preferProgress;
    _pendingScrollTextAnchor = textAnchor;
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
      final textAnchor = _pendingScrollTextAnchor;
      final anchoredOffset = textAnchor == null
          ? null
          : _scrollOffsetForTextAnchor(
              textAnchor,
              settings: _settings,
              mode: _settings.readingMode,
              viewportDimension: _scrollController.position.viewportDimension,
              maxExtent: maxExtent,
            );
      var offset =
          anchoredOffset ??
          (_preferPendingScrollProgress && progress != null
              ? progress * maxExtent
              : requested.clamp(0.0, maxExtent).toDouble());
      if (_settings.readingMode == ReaderReadingMode.simulation) {
        offset = _alignSimulationOffset(
          offset,
          pageExtent: _scrollController.position.viewportDimension,
          maxExtent: maxExtent,
        );
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
    _pendingScrollTextAnchor = null;
    _preferPendingScrollProgress = false;
    _finishReadingModeReload();
  }

  void _finishReadingModeReload() {
    if (!_readingModeReloading || !mounted) return;
    setState(() => _readingModeReloading = false);
  }

  double _alignSimulationOffset(
    double offset, {
    required double pageExtent,
    double? maxExtent,
  }) {
    if (!offset.isFinite || !pageExtent.isFinite || pageExtent <= 0) return 0;
    final aligned = (offset / pageExtent).round() * pageExtent;
    if (maxExtent == null || !maxExtent.isFinite) {
      return math.max(0.0, aligned);
    }
    final alignedMax =
        ((maxExtent + _simulationPageExtentTolerance) / pageExtent).floor() *
        pageExtent;
    return aligned.clamp(0.0, math.max(0.0, alignedMax)).toDouble();
  }

  ScrollController _previewScrollController({
    required double initialScrollOffset,
  }) {
    if (_settings.readingMode == ReaderReadingMode.simulation) {
      return _FullViewportPagingScrollController(
        initialScrollOffset: initialScrollOffset,
      );
    }
    return ScrollController(
      initialScrollOffset: initialScrollOffset,
      keepScrollOffset: false,
    );
  }

  void _resetContinuousMetrics() {
    _continuousRestoreSerial++;
    _pendingContinuousProgress = null;
    _pendingContinuousOffset = null;
    _pendingContinuousTextAnchor = null;
    _continuousMetricsScheduled = false;
    _continuousChapterStarts
      ..clear()
      ..[_continuousAnchorChapterIndex] = 0;
    _continuousChapterExtents.clear();
  }

  void _requestContinuousRestore(
    double progress, {
    double? offset,
    _ReadingTextAnchor? textAnchor,
  }) {
    _continuousAnchorChapterIndex = _chapterIndex;
    _continuousChapterStarts
      ..clear()
      ..[_continuousAnchorChapterIndex] = 0;
    _continuousChapterExtents.clear();
    _pendingContinuousProgress = progress.isFinite
        ? progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    _pendingContinuousOffset = offset != null && offset.isFinite
        ? math.max(0.0, offset)
        : null;
    _pendingContinuousTextAnchor = textAnchor;
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
        } else {
          _clearPendingContinuousRestore(serial);
        }
        return;
      }
      final extent = _continuousChapterExtents[_continuousAnchorChapterIndex];
      if (extent == null || !extent.isFinite || extent <= 0) {
        if (attempt < 20) {
          _restoreContinuousPosition(serial, attempt + 1);
        } else {
          _clearPendingContinuousRestore(serial);
        }
        return;
      }
      final viewport = _scrollController.position.viewportDimension;
      final readableExtent = math.max(0.0, extent - viewport);
      final textAnchor = _pendingContinuousTextAnchor;
      final anchoredOffset = textAnchor == null
          ? null
          : _scrollOffsetForTextAnchor(
              textAnchor,
              settings: _settings,
              mode: ReaderReadingMode.continuous,
              viewportDimension: viewport,
              maxExtent: readableExtent,
            );
      final requestedOffset = anchoredOffset ?? _pendingContinuousOffset;
      final target =
          (requestedOffset ?? _pendingContinuousProgress! * readableExtent)
              .clamp(
                _scrollController.position.minScrollExtent,
                _scrollController.position.maxScrollExtent,
              )
              .toDouble();
      _pendingContinuousProgress = null;
      _pendingContinuousOffset = null;
      _pendingContinuousTextAnchor = null;
      if ((_scrollController.offset - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
      final snapshot = _continuousSnapshotForChapter(_chapterIndex);
      _recordCurrentChapterPosition(snapshot);
      _finishReadingModeReload();
    });
  }

  void _clearPendingContinuousRestore(int serial) {
    if (serial != _continuousRestoreSerial) return;
    _pendingContinuousProgress = null;
    _pendingContinuousOffset = null;
    _pendingContinuousTextAnchor = null;
    _finishReadingModeReload();
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
    _discardReversePageTurnSnapshot();
    _wordCountNotifier.dispose();
    _chapterWordCountsNotifier.dispose();
    _visibleProgressNotifier.dispose();
    _pageTurnController.dispose();
    _pageDragOffsetNotifier.dispose();
    _selectionBlockedNotifier.dispose();
    _textSelectionActiveNotifier.removeListener(
      _handleTextSelectionActivityChanged,
    );
    _textSelectionActiveNotifier.dispose();
    _scrollController.removeListener(_scheduleProgressSave);
    _scrollController.dispose();
    final adjacentControllers = _adjacentScrollControllers.values.toSet();
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();
    for (final controller in adjacentControllers) {
      controller.dispose();
    }
    _simulationPreviewController?.dispose();
    _simulationPaperBackController?.dispose();
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
    if (_settings.readingMode == ReaderReadingMode.simulation &&
        _textSelectionActiveNotifier.value) {
      return;
    }
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
    final paragraphs = chapter.hasRichEpubContent
        ? chapter.epubBlocks
              .where((block) => block.isText && block.text.trim().isNotEmpty)
              .map(_formatEpubParagraph)
              .where((paragraph) => paragraph.isNotEmpty)
              .toList(growable: false)
        : chapter.content
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

  String _formatEpubParagraph(EpubContentBlock block) {
    final body = block.text.replaceFirst(RegExp(r'^[\s　]+'), '').trimRight();
    if (body.isEmpty) return '';
    final indentCount = block.style.textIndentEm.round().clamp(0, 8);
    return '${List<String>.filled(indentCount, '　').join()}$body';
  }

  int _paragraphPrefixLength(Chapter chapter, int paragraphIndex) {
    if (!chapter.hasRichEpubContent) return _paragraphIndent.length;
    var current = 0;
    for (final block in chapter.epubBlocks) {
      if (!block.isText || block.text.trim().isEmpty) continue;
      if (current == paragraphIndex) {
        return block.style.textIndentEm.round().clamp(0, 8);
      }
      current++;
    }
    return 0;
  }

  String _formatChapterTitle(String title) {
    return title.replaceFirst(RegExp(r'^[\s　]+'), '').trimRight();
  }

  bool _hasEmbeddedEpubHeading(Chapter chapter) {
    if (!chapter.hasRichEpubContent) return false;
    for (final block in chapter.epubBlocks) {
      if (!block.isText || block.text.trim().isEmpty) continue;
      if (block.isHeading) return true;
      // Older imported EPUB payloads predate the semantic heading flag. Keep
      // them compatible when their first styled block is visibly the same
      // title; otherwise preserve the app-rendered directory title.
      final sameTitle =
          _formatChapterTitle(block.text) == _formatChapterTitle(chapter.title);
      return sameTitle &&
          block.style.textIndentEm == 0 &&
          (block.style.fontScale > 1.05 || block.style.fontWeight >= 600);
    }
    return false;
  }

  bool _changesTextLayout(ReaderSettings current, ReaderSettings next) {
    return current.fontSize != next.fontSize ||
        current.lineHeight != next.lineHeight ||
        current.fontWeight != next.fontWeight ||
        current.fontFamily != next.fontFamily ||
        current.importedFontFamily != next.importedFontFamily ||
        current.pageMargin != next.pageMargin ||
        current.paragraphSpacing != next.paragraphSpacing ||
        current.readingMode != next.readingMode;
  }

  _ReadingTextAnchor? _captureReadingTextAnchor(_ScrollSnapshot snapshot) {
    if (_readerViewportWidth <= 0 || _book.chapters.isEmpty) return null;
    final paragraphs = _paragraphsFor(_currentChapter);
    if (paragraphs.isEmpty) return null;
    final settings = _settings;
    final width = math.max(
      1.0,
      _readerViewportWidth - settings.pageMargin.horizontalPadding * 2,
    );
    final bodyStart = _bodyStartOffset(
      _currentChapter,
      settings: settings,
      mode: settings.readingMode,
      width: width,
    );
    if (_currentChapter.hasRichEpubContent) {
      return _captureRichEpubTextAnchor(
        chapter: _currentChapter,
        bodyOffset: snapshot.offset - bodyStart,
        settings: settings,
        mode: settings.readingMode,
        width: width,
      );
    }
    final bodyText = _joinedBodyText(paragraphs, settings);
    final painter = _layoutBodyText(
      bodyText,
      settings: settings,
      mode: settings.readingMode,
      width: width,
    );
    try {
      final bodyY = snapshot.offset - bodyStart;
      final position = bodyY <= 0 || painter.height <= 0
          ? 0
          : painter
                .getPositionForOffset(
                  Offset(
                    0,
                    bodyY.clamp(0.0, math.max(0.0, painter.height - 0.01)),
                  ),
                )
                .offset;
      return _anchorFromJoinedPosition(
        chapterIndex: _chapterIndex,
        paragraphs: paragraphs,
        settings: settings,
        position: position,
      );
    } finally {
      painter.dispose();
    }
  }

  double? _scrollOffsetForTextAnchor(
    _ReadingTextAnchor anchor, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double viewportDimension,
    required double maxExtent,
  }) {
    if (anchor.chapterIndex != _chapterIndex ||
        _readerViewportWidth <= 0 ||
        !maxExtent.isFinite) {
      return null;
    }
    final chapter = _book.chapters[anchor.chapterIndex];
    final paragraphs = _paragraphsFor(chapter);
    if (paragraphs.isEmpty) return 0;
    final width = math.max(
      1.0,
      _readerViewportWidth - settings.pageMargin.horizontalPadding * 2,
    );
    if (chapter.hasRichEpubContent) {
      final bodyOffset = _richEpubOffsetForAnchor(
        chapter: chapter,
        anchor: anchor,
        settings: settings,
        mode: mode,
        width: width,
      );
      final rawOffset =
          _bodyStartOffset(
            chapter,
            settings: settings,
            mode: mode,
            width: width,
          ) +
          bodyOffset;
      if (mode == ReaderReadingMode.simulation && viewportDimension > 0) {
        final pageOffset =
            ((rawOffset + 0.01) / viewportDimension).floor() *
            viewportDimension;
        return _alignSimulationOffset(
          pageOffset,
          pageExtent: viewportDimension,
          maxExtent: maxExtent,
        );
      }
      return rawOffset.clamp(0.0, maxExtent).toDouble();
    }
    final bodyText = _joinedBodyText(paragraphs, settings);
    final joinedPosition = _joinedPositionForAnchor(
      anchor,
      paragraphs: paragraphs,
      settings: settings,
    );
    final painter = _layoutBodyText(
      bodyText,
      settings: settings,
      mode: mode,
      width: width,
    );
    try {
      final caretOffset = painter.getOffsetForCaret(
        TextPosition(offset: joinedPosition.clamp(0, bodyText.length)),
        Rect.zero,
      );
      final rawOffset =
          _bodyStartOffset(
            chapter,
            settings: settings,
            mode: mode,
            width: width,
          ) +
          caretOffset.dy;
      if (mode == ReaderReadingMode.simulation && viewportDimension > 0) {
        final pageOffset =
            ((rawOffset + 0.01) / viewportDimension).floor() *
            viewportDimension;
        return _alignSimulationOffset(
          pageOffset,
          pageExtent: viewportDimension,
          maxExtent: maxExtent,
        );
      }
      return rawOffset.clamp(0.0, maxExtent).toDouble();
    } finally {
      painter.dispose();
    }
  }

  String _joinedBodyText(List<String> paragraphs, ReaderSettings settings) {
    final separator =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? '\n\n'
        : '\n';
    return paragraphs.join(separator);
  }

  _ReadingTextAnchor _anchorFromJoinedPosition({
    required int chapterIndex,
    required List<String> paragraphs,
    required ReaderSettings settings,
    required int position,
  }) {
    final separatorLength =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine ? 2 : 1;
    var cursor = 0;
    for (var index = 0; index < paragraphs.length; index++) {
      final paragraphLength = paragraphs[index].length;
      final paragraphEnd = cursor + paragraphLength;
      if (position <= paragraphEnd || index == paragraphs.length - 1) {
        return _ReadingTextAnchor(
          chapterIndex: chapterIndex,
          paragraphIndex: index,
          characterOffset: (position - cursor).clamp(0, paragraphLength),
        );
      }
      final nextParagraphStart = paragraphEnd + separatorLength;
      if (position < nextParagraphStart) {
        return _ReadingTextAnchor(
          chapterIndex: chapterIndex,
          paragraphIndex: math.min(index + 1, paragraphs.length - 1),
          characterOffset: 0,
        );
      }
      cursor = nextParagraphStart;
    }
    return _ReadingTextAnchor(
      chapterIndex: chapterIndex,
      paragraphIndex: paragraphs.length - 1,
      characterOffset: paragraphs.last.length,
    );
  }

  int _joinedPositionForAnchor(
    _ReadingTextAnchor anchor, {
    required List<String> paragraphs,
    required ReaderSettings settings,
  }) {
    final separatorLength =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine ? 2 : 1;
    final paragraphIndex = anchor.paragraphIndex.clamp(
      0,
      paragraphs.length - 1,
    );
    var position = 0;
    for (var index = 0; index < paragraphIndex; index++) {
      position += paragraphs[index].length + separatorLength;
    }
    return position +
        anchor.characterOffset.clamp(0, paragraphs[paragraphIndex].length);
  }

  double _bodyStartOffset(
    Chapter chapter, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final simulation = mode == ReaderReadingMode.simulation;
    final lineExtent = settings.fontSize * settings.lineHeight;
    final topPadding = switch (mode) {
      ReaderReadingMode.simulation => 0.0,
      ReaderReadingMode.chapter => _readerViewPadding.top + AppSpacing.lg,
      ReaderReadingMode.continuous =>
        _continuousAnchorChapterIndex >= 0 &&
                _continuousAnchorChapterIndex < _book.chapters.length &&
                identical(
                  chapter,
                  _book.chapters[_continuousAnchorChapterIndex],
                )
            ? _readerViewPadding.top + AppSpacing.lg
            : AppSpacing.xxl,
    };
    if (_hasEmbeddedEpubHeading(chapter)) return topPadding;
    final titleStyle = TextStyle(
      fontFamily: settings.effectiveFontFamily,
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: simulation ? lineExtent / 20 : 1.5,
    );
    final titleStrut = simulation
        ? StrutStyle(
            fontFamily: settings.effectiveFontFamily,
            fontSize: 20,
            height: lineExtent / 20,
            fontWeight: FontWeight.w600,
            forceStrutHeight: true,
          )
        : null;
    final titlePainter = TextPainter(
      text: TextSpan(
        text: _formatChapterTitle(chapter.title),
        style: titleStyle,
      ),
      textDirection: TextDirection.ltr,
      textScaler: _readerTextScaler,
      strutStyle: titleStrut,
    )..layout(maxWidth: width);
    try {
      final titleGap = simulation ? lineExtent : AppSpacing.xl;
      return topPadding + titlePainter.height + titleGap;
    } finally {
      titlePainter.dispose();
    }
  }

  TextPainter _layoutBodyText(
    String text, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final simulation = mode == ReaderReadingMode.simulation;
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: settings.effectiveFontFamily,
          fontSize: settings.fontSize,
          fontWeight: settings.effectiveFontWeight,
          height: settings.lineHeight,
          letterSpacing: 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: _readerTextScaler,
      strutStyle: simulation
          ? StrutStyle(
              fontFamily: settings.effectiveFontFamily,
              fontSize: settings.fontSize,
              height: settings.lineHeight,
              fontWeight: settings.effectiveFontWeight,
              forceStrutHeight: true,
            )
          : null,
    )..layout(maxWidth: width);
  }

  _ReadingTextAnchor _captureRichEpubTextAnchor({
    required Chapter chapter,
    required double bodyOffset,
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final safeOffset = math.max(0.0, bodyOffset);
    var cursor = 0.0;
    var paragraphIndex = 0;
    var lastParagraphIndex = 0;
    for (final block in chapter.epubBlocks) {
      final extent = _epubBlockExtent(
        block,
        settings: settings,
        mode: mode,
        width: width,
      );
      if (!block.isText || block.text.trim().isEmpty) {
        if (safeOffset < cursor + extent) {
          return _ReadingTextAnchor(
            chapterIndex: chapter.index,
            paragraphIndex: lastParagraphIndex,
            characterOffset: 0,
          );
        }
        cursor += extent;
        continue;
      }
      lastParagraphIndex = paragraphIndex;
      if (safeOffset < cursor + extent) {
        final metrics = _epubBlockMetrics(
          block,
          settings: settings,
          mode: mode,
          width: width,
        );
        final painter = _layoutEpubTextBlock(
          block,
          settings: settings,
          mode: mode,
          width: width,
        );
        try {
          final localY = (safeOffset - cursor - metrics.leading)
              .clamp(0.0, math.max(0.0, painter.height - 0.01))
              .toDouble();
          final position = painter
              .getPositionForOffset(Offset(0, localY))
              .offset;
          return _ReadingTextAnchor(
            chapterIndex: chapter.index,
            paragraphIndex: paragraphIndex,
            characterOffset: position.clamp(
              0,
              _formatEpubParagraph(block).length,
            ),
          );
        } finally {
          painter.dispose();
        }
      }
      cursor += extent;
      paragraphIndex++;
    }
    final paragraphs = _paragraphsFor(chapter);
    return _ReadingTextAnchor(
      chapterIndex: chapter.index,
      paragraphIndex: math.max(0, paragraphs.length - 1),
      characterOffset: paragraphs.isEmpty ? 0 : paragraphs.last.length,
    );
  }

  double _richEpubOffsetForAnchor({
    required Chapter chapter,
    required _ReadingTextAnchor anchor,
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    var cursor = 0.0;
    var paragraphIndex = 0;
    for (final block in chapter.epubBlocks) {
      final metrics = _epubBlockMetrics(
        block,
        settings: settings,
        mode: mode,
        width: width,
      );
      if (block.isText && block.text.trim().isNotEmpty) {
        if (paragraphIndex == anchor.paragraphIndex) {
          final painter = _layoutEpubTextBlock(
            block,
            settings: settings,
            mode: mode,
            width: width,
          );
          try {
            final paragraph = _formatEpubParagraph(block);
            final caret = painter.getOffsetForCaret(
              TextPosition(
                offset: anchor.characterOffset.clamp(0, paragraph.length),
              ),
              Rect.zero,
            );
            return cursor + metrics.leading + caret.dy;
          } finally {
            painter.dispose();
          }
        }
        paragraphIndex++;
      }
      cursor += metrics.total;
    }
    return cursor;
  }

  ({double leading, double content, double trailing, double total})
  _epubBlockMetrics(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final baseLine = settings.fontSize * settings.lineHeight;
    final leading = block.style.marginTopEm * settings.fontSize;
    final paragraphGap =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? baseLine
        : 0.0;
    final trailing =
        block.style.marginBottomEm * settings.fontSize + paragraphGap;
    double content;
    if (block.isImage) {
      content = _epubImageHeight(block, width: width, settings: settings);
    } else {
      final painter = _layoutEpubTextBlock(
        block,
        settings: settings,
        mode: mode,
        width: width,
      );
      content = painter.height;
      painter.dispose();
    }
    var total = leading + content + trailing;
    if (mode == ReaderReadingMode.simulation && baseLine > 0) {
      total = math.max(baseLine, (total / baseLine).ceil() * baseLine);
    }
    return (
      leading: leading,
      content: content,
      trailing: math.max(0, total - leading - content),
      total: total,
    );
  }

  double _epubBlockExtent(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) => _epubBlockMetrics(
    block,
    settings: settings,
    mode: mode,
    width: width,
  ).total;

  double _epubImageHeight(
    EpubContentBlock block, {
    required double width,
    required ReaderSettings settings,
  }) {
    final requestedWidth = block.imageWidth;
    final displayWidth = requestedWidth != null && requestedWidth > 0
        ? math.min(width, requestedWidth)
        : width;
    final sourceWidth = block.imageWidth;
    final sourceHeight = block.imageHeight;
    final aspect =
        sourceWidth != null &&
            sourceHeight != null &&
            sourceWidth > 0 &&
            sourceHeight > 0
        ? sourceWidth / sourceHeight
        : 1.5;
    final naturalHeight = displayWidth / aspect;
    return naturalHeight.clamp(
      settings.fontSize * settings.lineHeight * 2,
      560.0,
    );
  }

  TextPainter _layoutEpubTextBlock(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    return TextPainter(
      text: _epubTextSpan(
        block,
        settings: settings,
        foreground: Colors.black,
        background: Colors.white,
      ),
      textDirection: TextDirection.ltr,
      textAlign: _epubTextAlign(block.style.textAlign),
      textScaler: _readerTextScaler,
    )..layout(maxWidth: width);
  }

  TextSpan _epubTextSpan(
    EpubContentBlock block, {
    required ReaderSettings settings,
    required Color foreground,
    required Color background,
  }) {
    final formatted = _formatEpubParagraph(block);
    final prefixLength = math.max(0, formatted.length - block.text.length);
    final children = <InlineSpan>[];
    if (prefixLength > 0) {
      children.add(
        TextSpan(
          text: formatted.substring(0, prefixLength),
          style: _epubRunTextStyle(
            block.style,
            settings: settings,
            foreground: foreground,
            background: background,
          ),
        ),
      );
    }
    if (block.runs.isEmpty) {
      children.add(
        TextSpan(
          text: block.text.trim(),
          style: _epubRunTextStyle(
            block.style,
            settings: settings,
            foreground: foreground,
            background: background,
          ),
        ),
      );
    } else {
      for (final run in block.runs) {
        children.add(
          TextSpan(
            text: run.text,
            style: _epubRunTextStyle(
              run.style,
              settings: settings,
              foreground: foreground,
              background: background,
            ),
          ),
        );
      }
    }
    return TextSpan(children: children);
  }

  TextStyle _epubRunTextStyle(
    EpubContentStyle style, {
    required ReaderSettings settings,
    required Color foreground,
    required Color background,
  }) {
    final weight = style.fontWeight >= 600
        ? (style.fontWeight >= 800 ? FontWeight.w900 : FontWeight.w700)
        : settings.effectiveFontWeight;
    return TextStyle(
      fontFamily: settings.effectiveFontFamily,
      fontSize: settings.fontSize * style.fontScale,
      fontWeight: weight,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      decoration: style.underline
          ? TextDecoration.underline
          : TextDecoration.none,
      shadows: settings.effectiveFontShadows(foreground),
      height: settings.lineHeight * style.lineHeightScale,
      color: _safePublisherForeground(
        style.colorArgb,
        fallback: foreground,
        background: background,
      ),
      backgroundColor: style.backgroundColorArgb == null
          ? null
          : Color(style.backgroundColorArgb!).withValues(alpha: 0.18),
      letterSpacing:
          settings.fontSize * style.fontScale * style.letterSpacingEm + 0.2,
    );
  }

  TextAlign _epubTextAlign(String value) => switch (value) {
    'center' => TextAlign.center,
    'end' => TextAlign.end,
    'justify' => TextAlign.justify,
    _ => TextAlign.start,
  };

  Color _epubBlockBackground(
    EpubContentStyle style,
    ReaderThemeColors themeColors,
  ) {
    final raw = style.backgroundColorArgb;
    if (raw == null) return Colors.transparent;
    final publisher = Color(raw);
    final dark = themeColors.background.computeLuminance() < 0.25;
    return Color.lerp(themeColors.background, publisher, dark ? 0.16 : 0.42)!;
  }

  Color _epubForeground(
    EpubContentStyle style,
    ReaderThemeColors themeColors,
    Color background,
  ) {
    return _safePublisherForeground(
      style.colorArgb,
      fallback: themeColors.text,
      background: background,
    );
  }

  Color _safePublisherForeground(
    int? raw, {
    required Color fallback,
    required Color background,
  }) {
    if (raw == null) return fallback;
    final publisher = Color(raw);
    final first = publisher.computeLuminance() + 0.05;
    final second = background.computeLuminance() + 0.05;
    final contrast = first > second ? first / second : second / first;
    return contrast >= 3 ? publisher : fallback;
  }

  Widget _buildEpubBlockWidget({
    required EpubContentBlock block,
    required ReaderThemeColors themeColors,
    required double width,
    required bool simulationPage,
  }) {
    final mode = simulationPage
        ? ReaderReadingMode.simulation
        : _settings.readingMode;
    final metrics = _epubBlockMetrics(
      block,
      settings: _settings,
      mode: mode,
      width: width,
    );
    final blockBackground = _epubBlockBackground(block.style, themeColors);
    final foreground = _epubForeground(
      block.style,
      themeColors,
      blockBackground == Colors.transparent
          ? themeColors.background
          : blockBackground,
    );
    Widget content;
    if (block.isImage) {
      final path = block.imagePath;
      final requestedWidth = block.imageWidth;
      final displayWidth = requestedWidth != null && requestedWidth > 0
          ? math.min(width, requestedWidth)
          : width;
      content = SizedBox(
        width: displayWidth,
        height: metrics.content,
        child: path == null
            ? _epubImageFallback(block, themeColors)
            : Image.file(
                File(path),
                fit: BoxFit.contain,
                alignment: Alignment.center,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) =>
                    _epubImageFallback(block, themeColors),
              ),
      );
      content = Align(
        alignment: switch (block.style.textAlign) {
          'center' => Alignment.center,
          'end' => Alignment.centerRight,
          _ => Alignment.centerLeft,
        },
        child: content,
      );
    } else {
      content = SizedBox(
        width: width,
        height: metrics.content,
        child: Text.rich(
          _epubTextSpan(
            block,
            settings: _settings,
            foreground: foreground,
            background: blockBackground == Colors.transparent
                ? themeColors.background
                : blockBackground,
          ),
          textAlign: _epubTextAlign(block.style.textAlign),
          textScaler: _readerTextScaler,
        ),
      );
    }

    final backgroundPath = block.style.backgroundImagePath;
    final decoration =
        blockBackground == Colors.transparent && backgroundPath == null
        ? null
        : BoxDecoration(
            color: blockBackground == Colors.transparent
                ? null
                : blockBackground,
            image: backgroundPath != null && File(backgroundPath).existsSync()
                ? DecorationImage(
                    image: FileImage(File(backgroundPath)),
                    fit: BoxFit.cover,
                    opacity: 0.22,
                  )
                : null,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          );
    return SizedBox(
      height: metrics.total,
      child: Padding(
        padding: EdgeInsets.only(
          top: metrics.leading,
          bottom: metrics.trailing,
        ),
        child: DecoratedBox(
          decoration: decoration ?? const BoxDecoration(),
          child: content,
        ),
      ),
    );
  }

  Widget _epubImageFallback(
    EpubContentBlock block,
    ReaderThemeColors themeColors,
  ) {
    final label = block.altText?.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: themeColors.headerBg,
        border: Border.all(color: themeColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                color: themeColors.secondary,
                size: 28,
              ),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: themeColors.secondary, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _setPageDragOffset(double value) {
    if (_pageDragOffset == value) return;
    _pageDragOffset = value;
    _pageDragOffsetNotifier.value = value;
  }

  Future<bool> _capturePageTurnSnapshot() {
    if (!mounted ||
        _readerModalOpen ||
        _textSelectionActiveNotifier.value ||
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
      for (var attempt = 0; attempt < 8; attempt++) {
        if (!mounted ||
            _readerModalOpen ||
            _textSelectionActiveNotifier.value ||
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
          _readerModalOpen ||
          _textSelectionActiveNotifier.value ||
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
  }

  void _scheduleReversePageTurnSnapshotCapture(_SimulationPageTarget target) {
    if (_readerModalOpen ||
        _textSelectionActiveNotifier.value ||
        target.goingNext ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _settings.simulationPageTurnEffect !=
            SimulationPageTurnEffect.simulation) {
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

  Future<bool> _captureReversePageTurnSnapshot(_SimulationPageTarget target) {
    if (!mounted ||
        _readerModalOpen ||
        _textSelectionActiveNotifier.value ||
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
    _SimulationPageTarget target,
  ) async {
    try {
      final pixelRatio = math.min(MediaQuery.devicePixelRatioOf(context), 1.5);
      RenderRepaintBoundary? boundary;
      for (var attempt = 0; attempt < 8; attempt++) {
        final currentTarget = _simulationPageTarget;
        if (!mounted ||
            _readerModalOpen ||
            _textSelectionActiveNotifier.value ||
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
          _textSelectionActiveNotifier.value ||
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
      setState(() {});
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
        _textSelectionActiveNotifier.value ||
        !_settingsLoaded ||
        _settings.readingMode != ReaderReadingMode.simulation ||
        _settings.simulationPageTurnEffect !=
            SimulationPageTurnEffect.simulation ||
        _pageTurnSnapshot != null ||
        _pageTurnSnapshotCapture != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _readerModalOpen ||
          _textSelectionActiveNotifier.value ||
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
    _setPageDragOffset(0);
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    if (!mounted) return;
    if (rebuild) {
      setState(() => _pageDragTargetIndex = null);
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
    if (mounted) setState(() {});
  }

  void _endReaderModal() {
    if (!_readerModalOpen) return;
    _readerModalOpen = false;
    _simulationViewportLock = null;
    if (!mounted) return;
    setState(() {});
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
      final textLayoutChanged = _changesTextLayout(_settings, pending);
      final textAnchor = textLayoutChanged
          ? _captureReadingTextAnchor(snapshot)
          : null;
      final rebuildsContinuous =
          previousMode == ReaderReadingMode.continuous ||
          pending.readingMode == ReaderReadingMode.continuous;
      final rebuildsSimulation =
          modeChanged &&
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
        // Simulation and the scrolling modes use different viewport and
        // padding models. Reusing a ScrollPosition across those layouts lets
        // Flutter reinterpret old pixels as a different page. Build a fresh
        // controller at zero and restore the normalized chapter position only
        // after the target layout has reported its own dimensions.
        final nextController = _createScrollController(
          rebuildsSimulation ? 0 : snapshot.offset,
          pending.readingMode == ReaderReadingMode.simulation,
        );
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
        setState(() {
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
        setState(() => _showOverlay = false);
        _hideStatusBarForReader();
      }
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
    final previousSimulationPaperBack = _simulationPaperBackController;
    final overlayWasVisible = _showOverlay;
    _simulationPreviewController = null;
    _simulationPaperBackController = null;
    _simulationPageTarget = null;
    _discardReversePageTurnSnapshot();
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
    // Update _showOverlay first: _hideStatusBarForReader refuses to run while
    // the chrome is visible, so the state must already reflect the toggle.
    setState(() => _showOverlay = willShow);
    if (willShow) {
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
    if (_textSelectionActiveNotifier.value) {
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
        if (!_simulationTurnActive &&
            travel.dx.abs() >= 9 &&
            travel.dx.abs() > travel.dy.abs() * 1.15) {
          _simulationTurnActive = true;
          _readingTapMoved = true;
          _beginHorizontalPageTurn();
          // Drop the touch-slop dead zone from the first delta. Applying the
          // full travel would teleport the leaf past the slop distance while
          // the finger has effectively not moved yet.
          _updateHorizontalPageTurn(
            deltaX: travel.dx - 9 * travel.dx.sign,
            width: width,
          );
        } else if (_simulationTurnActive) {
          _readingTapMoved = true;
          _updateHorizontalPageTurn(
            deltaX: event.localPosition.dx - lastPosition.dx,
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

  void _handleHorizontalDragStart(DragStartDetails _) {
    if (_textSelectionActiveNotifier.value) return;
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
    if (_textSelectionActiveNotifier.value) return;
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
        _settings.simulationPageTurnEffect ==
            SimulationPageTurnEffect.simulation &&
        _pageTurnSnapshot == null) {
      unawaited(_capturePageTurnSnapshot());
    }
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
          return _SimulationPageTarget(
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
      return _SimulationPageTarget(
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
      nextController = _FullViewportPagingScrollController(
        initialScrollOffset: target.offset,
      );
    }
    if (target != null &&
        _settings.simulationPageTurnEffect ==
            SimulationPageTurnEffect.simulation) {
      final movingPageOffset = target.goingNext
          ? (_pageTurnOriginSnapshot ?? _currentScrollSnapshot()).offset
          : target.offset;
      nextPaperBackController = _FullViewportPagingScrollController(
        initialScrollOffset: math.max(0.0, movingPageOffset),
      );
    }
    _discardReversePageTurnSnapshot();
    _simulationPreviewController = nextController;
    _simulationPaperBackController = nextPaperBackController;
    setState(() {
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
    if (_textSelectionActiveNotifier.value) return;
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
    _setTextSelectionBlocked(false);
    _switchChapter(targetIndex, startAtTop: false);
  }

  void _finishSimulationPageTurn(_SimulationPageTarget target) {
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
    setState(() {
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
    if (_selectionBlockedNotifier.value == blocked) return;
    _selectionBlockedNotifier.value = blocked;
  }

  void _handleTextSelectionActivityChanged() {
    if (!_textSelectionActiveNotifier.value) return;
    _readingTapMoved = true;
    _clearSimulationTurnPointer();
    if (_pageDragOffset != 0 || _simulationPageTarget != null) {
      _resetPageDrag();
    }
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

  void _showSearch() {
    unawaited(_presentSearch());
  }

  Future<void> _presentSearch() async {
    if (!mounted || _readerModalOpen) return;
    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    _beginReaderModal();
    BookSearchResult? selectedResult;
    try {
      selectedResult = await showModalBottomSheet<BookSearchResult>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.88,
            child: BookSearchSheet(
              colors: themeColors,
              onSearch: (query) => BookSearchService.search(_book, query),
              onSelect: (result) =>
                  Navigator.of(sheetContext).pop<BookSearchResult>(result),
            ),
          ),
        ),
      );
    } finally {
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
    final anchor = _ReadingTextAnchor(
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
      setState(() => _readingModeReloading = true);
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

  void _showReaderMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
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
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _closeReader();
      },
      child: Scaffold(
        backgroundColor: themeColors.background,
        // Search owns the IME through its modal route.  Resizing this scaffold
        // would shrink a simulated page behind the sheet and force a visible
        // repagination of the reader body.
        resizeToAvoidBottomInset: false,
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
                final reportedHeight = constraints.maxHeight;
                final stableViewPadding = viewPadding.copyWith(
                  top: stableTopInset,
                );
                _readerViewportWidth = width;
                if (!_readerModalOpen) {
                  _readerViewportHeight = reportedHeight;
                }
                _readerViewPadding = stableViewPadding;
                // The simulation grid computes page height in unscaled line
                // extents while Flutter would render each line scaled by the
                // system font scale. On devices with a non-default scale the
                // two disagree and page boundaries land mid-line, clipping
                // the first/last row of glyphs. The reader has its own font
                // size setting, so lock the scale: measurement and rendering
                // share one grid on every device.
                _readerTextScaler = TextScaler.noScaling;
                final readerHeight =
                    _readerModalOpen &&
                        _settings.readingMode == ReaderReadingMode.simulation &&
                        _simulationViewportLock != null
                    ? _simulationViewportLock!
                    : reportedHeight;
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
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRect(
                            child: MediaQuery(
                              data: MediaQuery.of(context).copyWith(
                                textScaler: TextScaler.noScaling,
                              ),
                              child: _buildReadingModeView(
                                width: width,
                                height: readerHeight,
                                themeColors: themeColors,
                                fontFamily: fontFamily,
                                viewPadding: stableViewPadding,
                                horizontalPadding: horizontalPadding,
                              ),
                            ),
                          ),
                          if (_readingModeReloading)
                            Positioned.fill(
                              child: AbsorbPointer(
                                child: ColoredBox(
                                  color: themeColors.background,
                                ),
                              ),
                            ),
                        ],
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
                          top: AppSpacing.sm,
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
                              icon: Icons.search_rounded,
                              label: '搜索',
                              subtitle: '全文',
                              onTap: _showSearch,
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
      final hasEmbeddedHeading = _hasEmbeddedEpubHeading(chapter);
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
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                hasEmbeddedHeading ? chapterTop : 0,
                horizontalPadding,
                0,
              ),
              sliver: SliverList.builder(
                itemCount: chapter.hasRichEpubContent
                    ? chapter.epubBlocks.length
                    : 1,
                itemBuilder: (context, itemIndex) {
                  if (chapter.hasRichEpubContent) {
                    final contentWidth = math.max(
                      1.0,
                      _readerViewportWidth - horizontalPadding * 2,
                    );
                    return _buildEpubBlockWidget(
                      block: chapter.epubBlocks[itemIndex],
                      themeColors: themeColors,
                      width: contentWidth,
                      simulationPage: false,
                    );
                  }
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
          selectionBlocked: _selectionBlockedNotifier,
          selectionActive: _textSelectionActiveNotifier,
          onReaderModalOpened: _beginReaderModal,
          onReaderModalClosed: _endReaderModal,
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

    return ValueListenableBuilder<double>(
      valueListenable: _pageDragOffsetNotifier,
      builder: (context, offset, _) {
        return switch (_settings.simulationPageTurnEffect) {
          SimulationPageTurnEffect.simulation => _buildStraightBookTurnPages(
            width: width,
            dragOffset: offset,
            currentPage: currentPage,
            previousPage: previousPage,
            nextPage: nextPage,
            keepAlivePreviousPage: previousBoundaryPage,
            keepAliveNextPage: nextBoundaryPage,
            paperBackPage: paperBackPage,
            themeColors: themeColors,
          ),
          SimulationPageTurnEffect.smooth => _buildSmoothTurnPages(
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

  Widget _buildSmoothTurnPages({
    required double width,
    required double dragOffset,
    required Widget currentPage,
    required Widget? previousPage,
    required Widget? nextPage,
    Widget? keepAlivePreviousPage,
    Widget? keepAliveNextPage,
  }) {
    return Stack(
      children: [
        // Boundary pages displaced by an active preview copy stay attached
        // offstage: their shared controllers hold the restored edge position
        // that _switchChapter inherits when the turn commits.
        if (keepAlivePreviousPage != null &&
            !identical(keepAlivePreviousPage, previousPage))
          Offstage(child: keepAlivePreviousPage),
        if (keepAliveNextPage != null &&
            !identical(keepAliveNextPage, nextPage))
          Offstage(child: keepAliveNextPage),
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

  Widget _buildStraightBookTurnPages({
    required double width,
    required double dragOffset,
    required Widget currentPage,
    required Widget? previousPage,
    required Widget? nextPage,
    required Widget? paperBackPage,
    required ReaderThemeColors themeColors,
    Widget? keepAlivePreviousPage,
    Widget? keepAliveNextPage,
  }) {
    final progress = (dragOffset.abs() / width).clamp(0.0, 1.0);
    final goingNext = dragOffset <= 0;
    final targetPage = goingNext ? nextPage : previousPage;
    final hasTarget = progress > 0.001 && targetPage != null;
    if (!hasTarget) {
      // Idle: keep both boundary pages attached offstage so their ListViews
      // lay out and restore to their page edges before any drag starts. A
      // page that first attaches mid-drag paints its stale saved position
      // and then visibly jumps once the scheduled restore lands.
      return Stack(
        fit: StackFit.expand,
        children: [
          if (previousPage != null) Offstage(child: previousPage),
          if (nextPage != null) Offstage(child: nextPage),
          currentPage,
        ],
      );
    }
    final resolvedTargetPage = targetPage;
    final leafProgress = goingNext ? progress : 1 - progress;
    final geometry = _StraightLeafGeometry.calculate(
      size: Size(width, 1),
      progress: leafProgress,
    );
    final movingPage = goingNext ? currentPage : resolvedTargetPage;
    final paperBackSnapshot = goingNext
        ? _pageTurnSnapshot
        : _reversePageTurnSnapshot;
    final paperBackSource = paperBackSnapshot != null
        ? RawImage(
            image: paperBackSnapshot,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.high,
          )
        : paperBackPage;
    final inkTransmission = themeColors.background.computeLuminance() < 0.25
        ? 0.46
        : 0.38;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Only the turn's active target page is placed visibly. Every other
        // boundary page stays attached offstage so its shared controller
        // keeps the restored edge position for a direction flip or a commit.
        if (keepAlivePreviousPage != null &&
            !identical(keepAlivePreviousPage, resolvedTargetPage))
          Offstage(child: keepAlivePreviousPage),
        if (keepAliveNextPage != null &&
            !identical(keepAliveNextPage, resolvedTargetPage))
          Offstage(child: keepAliveNextPage),
        if (goingNext)
          KeyedSubtree(
            key: const ValueKey('physical-next-page'),
            child: _inactivePage(resolvedTargetPage),
          )
        else
          KeyedSubtree(
            key: const ValueKey('physical-current-page-base'),
            child: currentPage,
          ),
        KeyedSubtree(
          key: ValueKey(
            goingNext
                ? 'physical-forward-sheet'
                : 'physical-reversed-forward-sheet',
          ),
          child: ClipPath(
            clipper: _StraightLeafFrontClipper(progress: leafProgress),
            child: goingNext ? movingPage : _inactivePage(movingPage),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _StraightPaperPainter(
                progress: leafProgress,
                pageColor: themeColors.background,
                layer: _StraightPaperPaintLayer.base,
              ),
            ),
          ),
        ),
        if (paperBackSource != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipper: _StraightLeafBackClipper(progress: leafProgress),
                child: Transform.translate(
                  offset: Offset(geometry.creaseX * 2 - width, 0),
                  child: Transform.flip(
                    flipX: true,
                    child: Opacity(
                      opacity: inkTransmission,
                      child: _inactivePage(paperBackSource),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _StraightPaperPainter(
                progress: leafProgress,
                pageColor: themeColors.background,
                layer: _StraightPaperPaintLayer.lighting,
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
    final richBlocks = chapter.hasRichEpubContent
        ? chapter.epubBlocks
        : const <EpubContentBlock>[];
    final lineExtent = _settings.fontSize * _settings.lineHeight;
    final paragraphGap =
        _settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? lineExtent
        : 0.0;
    final bodyItemCount = chapter.hasRichEpubContent
        ? richBlocks.length
        : paragraphs.length;
    final hasStandaloneTitle = !_hasEmbeddedEpubHeading(chapter);
    final titleItemCount = hasStandaloneTitle ? 1 : 0;
    final itemCount = bodyItemCount + titleItemCount + 1;
    final scrollView = ListView.builder(
      key: ValueKey<String>(
        'chapter-${identityHashCode(chapter)}-controller-${identityHashCode(controller)}-${simulationPage ? 'simulation' : 'scroll'}',
      ),
      controller: controller,
      primary: false,
      physics: physics,
      scrollCacheExtent: simulationPage
          ? const ScrollCacheExtent.pixels(0)
          : const ScrollCacheExtent.pixels(900),
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        simulationPage ? 0 : viewPadding.top + AppSpacing.lg,
        horizontalPadding,
        simulationPage ? 0 : viewPadding.bottom + 80,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (hasStandaloneTitle && index == 0) {
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
          return simulationPage
              ? const SizedBox.shrink()
              : const SizedBox(height: AppSpacing.xxl);
        }

        final paragraphIndex = index - titleItemCount;
        if (chapter.hasRichEpubContent) {
          final contentWidth = math.max(
            1.0,
            _readerViewportWidth - horizontalPadding * 2,
          );
          return _buildEpubBlockWidget(
            block: richBlocks[paragraphIndex],
            themeColors: themeColors,
            width: contentWidth,
            simulationPage: simulationPage,
          );
        }
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
      selectionBlocked: _selectionBlockedNotifier,
      selectionActive: _textSelectionActiveNotifier,
      onReaderModalOpened: _beginReaderModal,
      onReaderModalClosed: _endReaderModal,
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

class _DoubleTapFilteredSelectionArea extends StatefulWidget {
  final Widget child;
  final ReaderThemeColors colors;
  final ValueListenable<bool> selectionBlocked;
  final ValueNotifier<bool> selectionActive;
  final VoidCallback onReaderModalOpened;
  final VoidCallback onReaderModalClosed;

  const _DoubleTapFilteredSelectionArea({
    required this.child,
    required this.colors,
    required this.selectionBlocked,
    required this.selectionActive,
    required this.onReaderModalOpened,
    required this.onReaderModalClosed,
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
  bool _externallyBlocked = false;
  bool _ownsActiveSelection = false;

  @override
  void initState() {
    super.initState();
    _externallyBlocked = widget.selectionBlocked.value;
    widget.selectionBlocked.addListener(_handleSelectionBlockChanged);
  }

  @override
  void didUpdateWidget(covariant _DoubleTapFilteredSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.selectionBlocked, widget.selectionBlocked)) return;
    oldWidget.selectionBlocked.removeListener(_handleSelectionBlockChanged);
    _externallyBlocked = widget.selectionBlocked.value;
    widget.selectionBlocked.addListener(_handleSelectionBlockChanged);
    _handleSelectionBlockChanged();
  }

  void _handleSelectionBlockChanged() {
    _externallyBlocked = widget.selectionBlocked.value;
    if (!_externallyBlocked) return;
    _setSelectionActive(false);
    _selectedContent = null;
    ContextMenuController.removeAny();
    _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_externallyBlocked) return;
      ContextMenuController.removeAny();
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    });
  }

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
    final selectedText = content?.plainText.trim();
    if (selectedText == null || selectedText.isEmpty) {
      _setSelectionActive(false);
      ContextMenuController.removeAny();
      if (content != null) _scheduleInvalidSelectionClear();
      return;
    }
    if (!_suppressSelection && !_externallyBlocked) {
      _setSelectionActive(true);
      return;
    }
    _setSelectionActive(false);
    if (_clearScheduled) return;
    _scheduleSelectionClear();
  }

  void _scheduleInvalidSelectionClear() {
    if (_clearScheduled) return;
    _clearScheduled = true;
    scheduleMicrotask(() {
      _clearScheduled = false;
      if (!mounted) return;
      final selectedText = _selectedContent?.plainText.trim();
      if (selectedText != null && selectedText.isNotEmpty) return;
      ContextMenuController.removeAny();
      _selectedContent = null;
      _setSelectionActive(false);
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    });
  }

  void _scheduleSelectionClear() {
    if (_clearScheduled) return;
    _clearScheduled = true;
    scheduleMicrotask(() {
      _clearScheduled = false;
      if (!mounted || (!_suppressSelection && !_externallyBlocked)) return;
      ContextMenuController.removeAny();
      _selectedContent = null;
      _setSelectionActive(false);
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
        bool launched;
        try {
          launched = await SystemTextActionService.launch(
            action: action,
            target: defaultTarget,
            text: selectedText,
          );
        } on Object {
          await SystemTextActionService.setDefaultTargetId(action, null);
          rethrow;
        }
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
    } on Object catch (error, stackTrace) {
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
    widget.onReaderModalOpened();
    try {
      return await showModalBottomSheet<_TextActionChoice>(
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
                                ? () => setSheetState(
                                    () => selectedId = target.id,
                                  )
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
                          _TextActionChoice(
                            target: selected,
                            remember: remember,
                          ),
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
    } finally {
      widget.onReaderModalClosed();
    }
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
    if (_externallyBlocked) return const SizedBox.shrink();
    final selectedText = _selectedContent?.plainText.trim();
    if (selectedText == null || selectedText.isEmpty) {
      _scheduleInvalidSelectionClear();
      return const SizedBox.shrink();
    }
    final defaults = state.contextMenuButtonItems;
    final copy = _buttonOfType(defaults, ContextMenuButtonType.copy);
    final share = _buttonOfType(defaults, ContextMenuButtonType.share);
    final selectAll = _buttonOfType(defaults, ContextMenuButtonType.selectAll);
    if (copy == null) {
      _scheduleInvalidSelectionClear();
      return const SizedBox.shrink();
    }
    final buttons = <ContextMenuButtonItem>[
      copy.copyWith(label: '复制'),
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
    widget.selectionBlocked.removeListener(_handleSelectionBlockChanged);
    if (_ownsActiveSelection && widget.selectionActive.value) {
      widget.selectionActive.value = false;
    }
    _suppressionTimer?.cancel();
    super.dispose();
  }

  void _setSelectionActive(bool active) {
    if (active) {
      _ownsActiveSelection = true;
      if (!widget.selectionActive.value) widget.selectionActive.value = true;
      return;
    }
    if (!_ownsActiveSelection) return;
    _ownsActiveSelection = false;
    if (widget.selectionActive.value) widget.selectionActive.value = false;
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

double _fullViewportMaxScrollExtent(
  double rawMaxScrollExtent,
  double viewportDimension,
) {
  if (!rawMaxScrollExtent.isFinite || rawMaxScrollExtent <= 0) return 0;
  if (!viewportDimension.isFinite || viewportDimension <= 0) {
    return rawMaxScrollExtent;
  }
  final rawPageCount = rawMaxScrollExtent / viewportDimension;
  final nearestPageCount = rawPageCount.round();
  final nearestExtent = nearestPageCount * viewportDimension;
  final pageCount =
      (rawMaxScrollExtent - nearestExtent).abs() <=
          _simulationPageExtentTolerance
      ? nearestPageCount
      : rawPageCount.ceil();
  return math.max(0.0, pageCount * viewportDimension);
}

/// Extends a simulation chapter's logical scroll range to a whole number of
/// pages. The added range is blank paper after the real chapter content, so
/// the final page starts at the next exact viewport boundary instead of
/// overlapping the preceding page to bottom-align a short remainder.
class _FullViewportPagingScrollController extends ScrollController {
  _FullViewportPagingScrollController({super.initialScrollOffset})
    : super(keepScrollOffset: false);

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _FullViewportPagingScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
    );
  }
}

class _FullViewportPagingScrollPosition
    extends ScrollPositionWithSingleContext with _PageGridRealignMixin {
  _FullViewportPagingScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  bool get pageGridRealignEnabled => true;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = super.applyContentDimensions(
      minScrollExtent,
      _fullViewportMaxScrollExtent(maxScrollExtent, viewportDimension),
    );
    _schedulePageGridRealign();
    return applied;
  }
}

/// Self-healing page-grid guard for simulation pages.
///
/// Flutter silently re-interprets a ScrollPosition's pixels whenever content
/// dimensions change — a new font size, different device metrics, system
/// inset changes — and any drift from the page grid shows up as half-clipped
/// first/last glyph rows, or as the chapter tail bouncing between two
/// candidate offsets. After every layout, drift beyond half a pixel is
/// snapped back to the nearest page boundary on the next frame.
mixin _PageGridRealignMixin on ScrollPositionWithSingleContext {
  bool get pageGridRealignEnabled;

  bool _pageGridRealignScheduled = false;

  void _schedulePageGridRealign() {
    if (!pageGridRealignEnabled ||
        _pageGridRealignScheduled ||
        !hasPixels ||
        !hasContentDimensions) {
      return;
    }
    final snapped = _nearestPageGridOffset();
    if (snapped == null || (pixels - snapped).abs() <= 0.5) return;
    _pageGridRealignScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pageGridRealignScheduled = false;
      if (!hasPixels || !hasContentDimensions) return;
      final target = _nearestPageGridOffset();
      if (target == null || (pixels - target).abs() <= 0.5) return;
      jumpTo(target);
    });
  }

  double? _nearestPageGridOffset() {
    final extent = viewportDimension;
    if (!extent.isFinite || extent <= 0) return null;
    final minExtent = minScrollExtent;
    final maxExtent = maxScrollExtent;
    if (!minExtent.isFinite || !maxExtent.isFinite) return null;
    return ((pixels / extent).round() * extent)
        .clamp(minExtent, maxExtent)
        .toDouble();
  }
}

/// Separates direct reader scrolling from Flutter's selection edge scroller.
///
/// Once a non-empty selection exists, a finger dragging the underlying
/// Scrollable must not compete with the selection handle for the same pointer.
/// Chapter and continuous modes still allow programmatic [animateTo] calls so
/// Flutter can extend the selection at the viewport edge. Simulation mode adds
/// the stricter finite-page lock and rejects every pixel mutation.
class _SelectionAwareScrollController extends ScrollController {
  final ValueListenable<bool> selectionActive;
  final bool Function() freezeSelectionViewport;
  final bool paginateToFullViewports;

  _SelectionAwareScrollController({
    required this.selectionActive,
    required this.freezeSelectionViewport,
    required this.paginateToFullViewports,
    super.initialScrollOffset,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SelectionAwareScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
      selectionActive: selectionActive,
      viewportIsFrozen: () =>
          selectionActive.value && freezeSelectionViewport(),
      paginateToFullViewports: paginateToFullViewports,
    );
  }
}

class _SelectionAwareScrollPosition extends ScrollPositionWithSingleContext
    with _PageGridRealignMixin {
  final ValueListenable<bool> selectionActive;
  final bool Function() viewportIsFrozen;
  final bool paginateToFullViewports;
  Completer<void>? _frozenAnimationCompleter;

  _SelectionAwareScrollPosition({
    required super.physics,
    required super.context,
    required this.selectionActive,
    required this.viewportIsFrozen,
    required this.paginateToFullViewports,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    super.debugLabel,
  }) {
    selectionActive.addListener(_handleSelectionActivityChanged);
  }

  @override
  bool get pageGridRealignEnabled => paginateToFullViewports;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = super.applyContentDimensions(
      minScrollExtent,
      paginateToFullViewports
          ? _fullViewportMaxScrollExtent(maxScrollExtent, viewportDimension)
          : maxScrollExtent,
    );
    _schedulePageGridRealign();
    return applied;
  }

  void _handleSelectionActivityChanged() {
    if (!viewportIsFrozen()) _releaseFrozenAnimation();
  }

  void _releaseFrozenAnimation() {
    final completer = _frozenAnimationCompleter;
    _frozenAnimationCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  // Flutter's selection edge scroller first checks these extents before it
  // starts an animateTo loop. Collapsing both extents to the visible page
  // position makes a simulation page a true, finite selection surface while
  // the selection gesture is active. This stops the auto-scroller at its
  // source instead of completing a blocked animation and letting it retry in
  // a tight asynchronous loop.
  @override
  double get minScrollExtent =>
      viewportIsFrozen() ? pixels : super.minScrollExtent;

  @override
  double get maxScrollExtent =>
      viewportIsFrozen() ? pixels : super.maxScrollExtent;

  @override
  double setPixels(double newPixels) {
    if (viewportIsFrozen()) return newPixels - pixels;
    return super.setPixels(newPixels);
  }

  @override
  void forcePixels(double value) {
    if (viewportIsFrozen()) return;
    super.forcePixels(value);
  }

  @override
  void applyUserOffset(double delta) {
    // A selection-handle drag and a Scrollable drag can both remain in the
    // Android pointer stream. Let the selection own that stream. Flutter's
    // edge auto-scroller uses animateTo instead, so chapter and continuous
    // selections can still advance vertically without racing this path.
    if (selectionActive.value) return;
    super.applyUserOffset(delta);
  }

  @override
  void pointerScroll(double delta) {
    if (selectionActive.value) return;
    super.pointerScroll(delta);
  }

  @override
  void jumpTo(double value) {
    if (viewportIsFrozen()) return;
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    // Keep a rejected edge-scroll request pending for the lifetime of the
    // fixed-page selection. Completing immediately makes Flutter's selection
    // auto-scroller retry in a tight loop at the page edge.
    if (viewportIsFrozen()) {
      return (_frozenAnimationCompleter ??= Completer<void>()).future;
    }
    _releaseFrozenAnimation();
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void dispose() {
    selectionActive.removeListener(_handleSelectionActivityChanged);
    _releaseFrozenAnimation();
    super.dispose();
  }
}

class _ReadingTextAnchor {
  final int chapterIndex;
  final int paragraphIndex;
  final int characterOffset;

  const _ReadingTextAnchor({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.characterOffset,
  });
}

class _ScrollSnapshot {
  final double offset;
  final double progress;

  const _ScrollSnapshot({required this.offset, required this.progress});
}

enum _StraightPaperPaintLayer { base, lighting }

class _StraightLeafFrontClipper extends CustomClipper<Path> {
  final double progress;

  const _StraightLeafFrontClipper({required this.progress});

  @override
  Path getClip(Size size) =>
      _StraightLeafGeometry.calculate(size: size, progress: progress).frontPath;

  @override
  bool shouldReclip(covariant _StraightLeafFrontClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

class _StraightLeafBackClipper extends CustomClipper<Path> {
  final double progress;

  const _StraightLeafBackClipper({required this.progress});

  @override
  Path getClip(Size size) =>
      _StraightLeafGeometry.calculate(size: size, progress: progress).backPath;

  @override
  bool shouldReclip(covariant _StraightLeafBackClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

class _StraightPaperPainter extends CustomPainter {
  final double progress;
  final Color pageColor;
  final _StraightPaperPaintLayer layer;

  const _StraightPaperPainter({
    required this.progress,
    required this.pageColor,
    required this.layer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final p = progress.clamp(0.0, 1.0).toDouble();
    if (p <= 0 || p >= 1) return;
    final geometry = _StraightLeafGeometry.calculate(size: size, progress: p);
    final strength = geometry.foldStrength;
    final visibleBounds = geometry.backPath.getBounds().intersect(
      Offset.zero & size,
    );
    if (visibleBounds.width <= 0.1) return;

    final isDarkPage = pageColor.computeLuminance() < 0.25;
    if (layer == _StraightPaperPaintLayer.base) {
      canvas.drawShadow(
        geometry.backPath,
        Colors.black.withValues(alpha: 0.30 * strength),
        12 + 8 * strength,
        false,
      );
      final paper = Color.lerp(
        pageColor,
        Colors.white,
        isDarkPage ? 0.02 : 0.045,
      )!;
      canvas.drawPath(geometry.backPath, Paint()..color = paper);
      return;
    }

    final lighting = LinearGradient(
      colors: [
        Colors.black.withValues(alpha: 0.10 * strength),
        Colors.white.withValues(alpha: 0.11 * strength),
        Colors.transparent,
        Colors.black.withValues(alpha: 0.14 * strength),
      ],
      stops: const [0, 0.22, 0.70, 1],
    ).createShader(visibleBounds);
    canvas
      ..save()
      ..clipPath(geometry.backPath)
      ..drawRect(visibleBounds, Paint()..shader = lighting)
      ..restore();

    canvas.drawLine(
      Offset(geometry.outerEdgeX, 0),
      Offset(geometry.outerEdgeX, size.height),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.20 * strength)
        ..strokeWidth = 1.25,
    );
    canvas.drawLine(
      Offset(geometry.creaseX, 0),
      Offset(geometry.creaseX, size.height),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * strength)
        ..strokeWidth = 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8),
    );
    canvas.drawLine(
      Offset(geometry.creaseX - 0.75, 0),
      Offset(geometry.creaseX - 0.75, size.height),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.32 * strength)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _StraightPaperPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.pageColor != pageColor ||
        oldDelegate.layer != layer;
  }
}

class _StraightLeafGeometry {
  final Path frontPath;
  final Path backPath;
  final double creaseX;
  final double outerEdgeX;
  final double foldStrength;

  const _StraightLeafGeometry({
    required this.frontPath,
    required this.backPath,
    required this.creaseX,
    required this.outerEdgeX,
    required this.foldStrength,
  });

  static _StraightLeafGeometry calculate({
    required Size size,
    required double progress,
  }) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    final creaseX = size.width * (1 - p);
    final outerEdgeX = creaseX * 2 - size.width;
    final front = Path()..addRect(Rect.fromLTRB(0, 0, creaseX, size.height));
    final back = Path()
      ..addRect(
        Rect.fromLTRB(
          math.min(outerEdgeX, creaseX),
          0,
          math.max(outerEdgeX, creaseX),
          size.height,
        ),
      );
    return _StraightLeafGeometry(
      frontPath: front,
      backPath: back,
      creaseX: creaseX,
      outerEdgeX: outerEdgeX,
      foldStrength: math.sin(math.pi * p).clamp(0.0, 1.0).toDouble(),
    );
  }
}
