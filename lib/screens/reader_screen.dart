import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, RenderSliver, ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';
import '../services/font_service.dart';
import '../services/book_search_service.dart';
import '../services/storage_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/chapter_list.dart';
import '../widgets/chapter_editor_sheet.dart';
import '../widgets/book_search_sheet.dart';
import '../widgets/reader_settings_sheet.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/reading_progress_bar.dart';
import '../controllers/chapter_editing_controller.dart';
import '../controllers/reader_progress_controller.dart';
import '../controllers/reader_search_controller.dart';
import '../controllers/reader_selection_controller.dart';
import '../controllers/reader_word_count_controller.dart';
import 'reader/reader_epub_layout.dart';
import 'reader/reader_pagination_support.dart';
import 'reader/reader_selection_support.dart';
import 'reader/reader_selectable_block.dart';

const double _simulationPageExtentTolerance = 0.01;

/// Reader screen — displays book content with settings overlay
class ReaderScreen extends StatefulWidget {
  final Book book;
  final ReaderRepository? repository;
  final ValueListenable<ReaderThemeColors>? transitionColors;
  final ValueChanged<ReaderSettings>? onSettingsChanged;

  const ReaderScreen({
    super.key,
    required this.book,
    this.repository,
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

  late final ReaderRepository _storage;
  late final FontService _fontService;
  late final ChapterEditingController _chapterEditingController;
  late Book _book;
  late ReaderSettings _settings;
  late int _chapterIndex;
  bool _showOverlay = false;
  late ScrollController _scrollController;
  bool _settingsLoaded = false;
  String? _readerLoadError;
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
  final ReaderSelectionController _selectionController =
      ReaderSelectionController();
  final ReaderProgressController _progressController =
      ReaderProgressController();
  final ReaderSearchController _searchController = ReaderSearchController();
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
  ReadingTextAnchor? _pendingScrollTextAnchor;
  bool _preferPendingScrollProgress = false;
  int _scrollRestoreSerial = 0;
  final Map<int, ScrollController> _adjacentScrollControllers =
      <int, ScrollController>{};
  final Map<int, int> _adjacentScrollRestoreSerials = <int, int>{};
  int _overlayToggleSerial = 0;
  int? _pageTurnOriginChapterIndex;
  ScrollSnapshot? _pageTurnOriginSnapshot;
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
  ReadingTextAnchor? _pendingContinuousTextAnchor;
  SimulationPageTarget? _simulationPageTarget;
  ScrollController? _simulationPreviewController;
  ScrollController? _simulationPaperBackController;
  late final ReaderWordCountController _wordCountController;
  late final ValueNotifier<double> _visibleProgressNotifier;
  ScrollSnapshot _lastScrollSnapshot = const ScrollSnapshot(
    offset: 0,
    progress: 0,
  );
  final LinkedHashMap<Chapter, List<String>> _paragraphCache =
      LinkedHashMap<Chapter, List<String>>();
  int _paragraphCacheCharacters = 0;
  final LinkedHashMap<Chapter, double> _simulationContentExtentCache =
      LinkedHashMap<Chapter, double>();
  SimulationLayoutSignature? _simulationContentExtentSignature;
  SimulationLayoutSignature? _simulationLineExtentSignature;
  double? _simulationLineExtentCache;
  double _readerViewportWidth = 0;
  double _readerViewportHeight = 0;
  EdgeInsets _readerViewPadding = EdgeInsets.zero;
  TextScaler _readerTextScaler = TextScaler.noScaling;

  ReaderEpubLayout get _epubLayout => ReaderEpubLayout(
    textScaler: _readerTextScaler,
    resolveSimulationLineExtent: _resolvedSimulationLineExtent,
  );

  @override
  void initState() {
    super.initState();
    _storage = widget.repository ?? StorageService();
    _fontService = FontService(_storage);
    _chapterEditingController = ChapterEditingController(_storage);
    _book = widget.book;
    _chapterIndex = 0;
    _settings = const ReaderSettings();
    _continuousChapterKeys = List<GlobalKey>.generate(
      _book.chapters.length,
      (_) => GlobalKey(),
      growable: false,
    );
    _wordCountController = ReaderWordCountController(_storage, _book);
    _visibleProgressNotifier = ValueNotifier<double>(0);
    _scrollController = _createScrollController();
    _selectionController.active.addListener(
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
    if (_wordCountController.needsRefresh(_book)) {
      unawaited(_wordCountController.ensure(_book));
    }
  }

  ScrollController _createScrollController([
    double initialOffset = 0,
    bool? simulationPagination,
  ]) {
    final controller = SelectionAwareScrollController(
      selectionActive: _selectionController.active,
      selectionDragging: _selectionController.dragging,
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

  ScrollSnapshot? _adjacentScrollSnapshot(int chapterIndex) {
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
    return ScrollSnapshot(
      offset: offset,
      progress: maxExtent > 0 ? offset / maxExtent : 0,
    );
  }

  /// What the drag preview is actually showing. When a turn commits, this is
  /// the page the user sees under the settling animation, so the committed
  /// chapter must land exactly here.
  ScrollSnapshot? _simulationPreviewSnapshot(int chapterIndex) {
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
    return ScrollSnapshot(
      offset: offset,
      progress: maxExtent > 0 ? offset / maxExtent : 0,
    );
  }

  void _hideStatusBarForReader() {
    // Never hide the status bar while the reader chrome is open. The timer
    // scheduled right after the book-opening animation can fire after the
    // user has already summoned the menu, and must not win that race.
    if (!mounted || _closingReader || _showOverlay || _readerModalOpen) return;
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

  Future<void> _deleteDamagedBook() async {
    await _storage.deleteBook(_book.id);
    if (mounted) Navigator.of(context).pop();
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
    for (final entry in _book.embeddedFonts.entries) {
      try {
        await _fontService.loadFont(family: entry.key, path: entry.value);
      } on Object catch (error, stackTrace) {
        debugPrint('Failed to load embedded book font ${entry.key}: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
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
    if (_book.chapters.isNotEmpty) {
      try {
        final chapter = _book.chapters[_chapterIndex];
        chapter.content;
        if (chapter.hasRichEpubContent) chapter.epubBlocks;
      } on Object catch (error, stackTrace) {
        _readerLoadError = '第 ${_chapterIndex + 1} 章正文文件缺失或损坏';
        debugPrint('Failed to load initial chapter: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
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
    _lastScrollSnapshot = ScrollSnapshot(
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
    ReadingTextAnchor? textAnchor,
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
      _lastScrollSnapshot = ScrollSnapshot(
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
      return FullViewportPagingScrollController(
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
    ReadingTextAnchor? textAnchor,
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

  ScrollSnapshot _continuousSnapshotForChapter(int chapterIndex) {
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
    return ScrollSnapshot(
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
    _wordCountController.dispose();
    _visibleProgressNotifier.dispose();
    _pageTurnController.dispose();
    _pageDragOffsetNotifier.dispose();
    _selectionController.active.removeListener(
      _handleTextSelectionActivityChanged,
    );
    _selectionController.dispose();
    _searchController.dispose();
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
        _selectionController.active.value) {
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
      return _progressController.pending;
    }
    final snapshot = _currentScrollSnapshot();
    final updated = _recordCurrentChapterPosition(snapshot);
    return _enqueueProgressSave(updated);
  }

  ReadingProgress _recordCurrentChapterPosition(ScrollSnapshot snapshot) {
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

  ScrollSnapshot _currentScrollSnapshot() {
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
      final snapshot = ScrollSnapshot(
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
      final snapshot = ScrollSnapshot(
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
    return _progressController.enqueue(
      () => _storage.saveProgress(progress),
      onError: (error, stack) {
        debugPrint('Failed to save reading progress: $error');
        debugPrintStack(stackTrace: stack);
      },
    );
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
              .map(_epubLayout.formatParagraph)
              .where((paragraph) => paragraph.isNotEmpty)
              .toList(growable: false)
        : chapter.content
              .split(RegExp(r'(?:\r\n?|\n)+'))
              .map(_formatParagraph)
              .where((p) => p.isNotEmpty)
              .toList(growable: false);
    final characters = paragraphs.fold<int>(
      0,
      (sum, paragraph) => sum + paragraph.length,
    );
    const maxCachedCharacters = 12 * 1024 * 1024;
    if (characters > maxCachedCharacters) {
      _paragraphCache.clear();
      _paragraphCacheCharacters = 0;
    } else {
      while ((_paragraphCache.length >= 5 ||
              _paragraphCacheCharacters + characters > maxCachedCharacters) &&
          _paragraphCache.isNotEmpty) {
        final removed = _paragraphCache.remove(_paragraphCache.keys.first)!;
        _paragraphCacheCharacters -= removed.fold<int>(
          0,
          (sum, paragraph) => sum + paragraph.length,
        );
      }
    }
    _paragraphCache[chapter] = paragraphs;
    _paragraphCacheCharacters += characters;
    return paragraphs;
  }

  String _formatParagraph(String paragraph) {
    final body = paragraph.replaceFirst(RegExp(r'^[\s　]+'), '').trimRight();
    return body.isEmpty ? '' : '$_paragraphIndent$body';
  }

  int _paragraphPrefixLength(Chapter chapter, int paragraphIndex) {
    if (!chapter.hasRichEpubContent) return _paragraphIndent.length;
    return _epubLayout.paragraphPrefixLength(chapter, paragraphIndex);
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

  ReadingTextAnchor? _captureReadingTextAnchor(ScrollSnapshot snapshot) {
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
    final bodyY = math.max(0.0, snapshot.offset - bodyStart);
    final paragraphGap =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? _resolvedSimulationOrNaturalLineExtent(settings, settings.readingMode)
        : 0.0;
    var cursor = 0.0;
    for (var index = 0; index < paragraphs.length; index++) {
      final paragraph = paragraphs[index];
      final painter = _layoutBodyText(
        paragraph,
        settings: settings,
        mode: settings.readingMode,
        width: width,
      );
      try {
        if (bodyY <= cursor + painter.height ||
            index == paragraphs.length - 1) {
          final localY = (bodyY - cursor)
              .clamp(0.0, math.max(0.0, painter.height - 0.01))
              .toDouble();
          final position = painter.height <= 0
              ? 0
              : painter.getPositionForOffset(Offset(0, localY)).offset;
          return ReadingTextAnchor(
            chapterIndex: _chapterIndex,
            paragraphIndex: index,
            characterOffset: position.clamp(0, paragraph.length),
          );
        }
        cursor += painter.height + paragraphGap;
      } finally {
        painter.dispose();
      }
    }
    return ReadingTextAnchor(
      chapterIndex: _chapterIndex,
      paragraphIndex: paragraphs.length - 1,
      characterOffset: paragraphs.last.length,
    );
  }

  double? _scrollOffsetForTextAnchor(
    ReadingTextAnchor anchor, {
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
    final targetIndex = anchor.paragraphIndex.clamp(0, paragraphs.length - 1);
    final paragraphGap =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? _resolvedSimulationOrNaturalLineExtent(settings, mode)
        : 0.0;
    var bodyOffset = 0.0;
    for (var index = 0; index <= targetIndex; index++) {
      final paragraph = paragraphs[index];
      final painter = _layoutBodyText(
        paragraph,
        settings: settings,
        mode: mode,
        width: width,
      );
      try {
        if (index == targetIndex) {
          final caretOffset = painter.getOffsetForCaret(
            TextPosition(
              offset: anchor.characterOffset.clamp(0, paragraph.length),
            ),
            Rect.zero,
          );
          bodyOffset += caretOffset.dy;
        } else {
          bodyOffset += painter.height + paragraphGap;
        }
      } finally {
        painter.dispose();
      }
    }
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
          ((rawOffset + 0.01) / viewportDimension).floor() * viewportDimension;
      return _alignSimulationOffset(
        pageOffset,
        pageExtent: viewportDimension,
        maxExtent: maxExtent,
      );
    }
    return rawOffset.clamp(0.0, maxExtent).toDouble();
  }

  double _resolvedSimulationOrNaturalLineExtent(
    ReaderSettings settings,
    ReaderReadingMode mode,
  ) => mode == ReaderReadingMode.simulation
      ? _resolvedSimulationLineExtent(settings)
      : settings.fontSize * settings.lineHeight;

  double _resolvedSimulationLineExtent(ReaderSettings settings) {
    final signature = SimulationLayoutSignature(
      contentWidth: 0,
      settings: settings,
    );
    final cached = _simulationLineExtentCache;
    if (cached != null &&
        cached.isFinite &&
        cached > 0 &&
        _simulationLineExtentSignature?.matches(signature) == true) {
      return cached;
    }

    final nominalExtent = settings.fontSize * settings.lineHeight;
    final painter = TextPainter(
      text: TextSpan(
        text: '汉Ag\n汉Ag',
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
      strutStyle: StrutStyle(
        fontFamily: settings.effectiveFontFamily,
        fontSize: settings.fontSize,
        height: settings.lineHeight,
        fontWeight: settings.effectiveFontWeight,
        forceStrutHeight: true,
      ),
    )..layout(maxWidth: math.max(1.0, nominalExtent * 8));
    try {
      final lineMetrics = painter.computeLineMetrics();
      final measuredExtent = lineMetrics.length >= 2
          ? lineMetrics[1].baseline - lineMetrics[0].baseline
          : lineMetrics.isNotEmpty
          ? lineMetrics.first.height
          : painter.height;
      final resolved = measuredExtent.isFinite && measuredExtent > 0
          ? measuredExtent
          : nominalExtent;
      _simulationLineExtentSignature = signature;
      _simulationLineExtentCache = resolved;
      return resolved;
    } finally {
      painter.dispose();
    }
  }

  double _bodyStartOffset(
    Chapter chapter, {
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    final simulation = mode == ReaderReadingMode.simulation;
    final lineExtent = simulation
        ? _resolvedSimulationLineExtent(settings)
        : settings.fontSize * settings.lineHeight;
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
    if (_epubLayout.hasEmbeddedHeading(chapter)) return topPadding;
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
        text: _epubLayout.formatChapterTitle(chapter.title),
        style: titleStyle,
      ),
      textDirection: TextDirection.ltr,
      textScaler: _readerTextScaler,
      strutStyle: titleStrut,
    )..layout(maxWidth: width);
    try {
      if (simulation) {
        // The title uses a different font size, so even a forced strut can
        // resolve to a slightly different physical line box. Snap the whole
        // title block (plus one blank body line) to the measured body grid;
        // otherwise every later page inherits the title's fractional phase.
        final titleLineCount = math.max(
          1,
          ((titlePainter.height - _simulationPageExtentTolerance) / lineExtent)
              .ceil(),
        );
        return topPadding + (titleLineCount + 1) * lineExtent;
      }
      return topPadding + titlePainter.height + AppSpacing.xl;
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

  ReadingTextAnchor _captureRichEpubTextAnchor({
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
      final extent = _epubLayout.blockExtent(
        block,
        settings: settings,
        mode: mode,
        width: width,
      );
      if (!block.isText || block.text.trim().isEmpty) {
        if (safeOffset < cursor + extent) {
          return ReadingTextAnchor(
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
        final metrics = _epubLayout.blockMetrics(
          block,
          settings: settings,
          mode: mode,
          width: width,
        );
        final painter = _epubLayout.layoutTextBlock(
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
          return ReadingTextAnchor(
            chapterIndex: chapter.index,
            paragraphIndex: paragraphIndex,
            characterOffset: position.clamp(
              0,
              _epubLayout.formatParagraph(block).length,
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
    return ReadingTextAnchor(
      chapterIndex: chapter.index,
      paragraphIndex: math.max(0, paragraphs.length - 1),
      characterOffset: paragraphs.isEmpty ? 0 : paragraphs.last.length,
    );
  }

  double _richEpubOffsetForAnchor({
    required Chapter chapter,
    required ReadingTextAnchor anchor,
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    var cursor = 0.0;
    var paragraphIndex = 0;
    for (final block in chapter.epubBlocks) {
      final metrics = _epubLayout.blockMetrics(
        block,
        settings: settings,
        mode: mode,
        width: width,
      );
      if (block.isText && block.text.trim().isNotEmpty) {
        if (paragraphIndex == anchor.paragraphIndex) {
          final painter = _epubLayout.layoutTextBlock(
            block,
            settings: settings,
            mode: mode,
            width: width,
          );
          try {
            final paragraph = _epubLayout.formatParagraph(block);
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

  void _setPageDragOffset(double value) {
    if (_pageDragOffset == value) return;
    _pageDragOffset = value;
    _pageDragOffsetNotifier.value = value;
  }

  Future<bool> _capturePageTurnSnapshot() {
    if (!mounted ||
        _readerModalOpen ||
        _selectionController.active.value ||
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
            _selectionController.active.value ||
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
          _selectionController.active.value ||
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

  void _scheduleReversePageTurnSnapshotCapture(SimulationPageTarget target) {
    if (_readerModalOpen ||
        _selectionController.active.value ||
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
        _selectionController.active.value ||
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
          _selectionController.active.value ||
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
    _lastScrollSnapshot = ScrollSnapshot(
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
        _lastScrollSnapshot = ScrollSnapshot(
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
        _settings.simulationPageTurnEffect ==
            SimulationPageTurnEffect.simulation) {
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

  void _showChapterList() => unawaited(_presentChapterList());

  Future<void> _presentChapterList() async {
    if (!mounted || _readerModalOpen) return;
    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    _beginReaderModal();
    try {
      await showModalBottomSheet<void>(
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
            wordCountListenable: _wordCountController.wordCount,
            chapterWordCountsListenable: _wordCountController.chapterWordCounts,
            collapsedGroupIds: _collapsedTocGroupIds,
            onGroupExpansionChanged: _handleTocGroupExpansionChanged,
            onSelect: _openChapter,
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

  void _showSettings() => unawaited(_presentSettings());

  Future<void> _presentSettings() async {
    if (!mounted || _readerModalOpen) return;
    var sheetSettings = _settings;
    _beginReaderModal();
    try {
      await showModalBottomSheet<void>(
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

  void _showChapterEditor() => unawaited(_presentChapterEditor());

  Future<void> _presentChapterEditor() async {
    if (!mounted || _readerModalOpen) return;
    if (_settings.readingMode != ReaderReadingMode.chapter) {
      _showReaderMessage('编辑器仅在分章滑动模式中可用');
      return;
    }
    final chapter = _currentChapter;
    final snapshot = _currentScrollSnapshot();
    final textAnchor = _captureReadingTextAnchor(snapshot);
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

    _paragraphCache.clear();
    _paragraphCacheCharacters = 0;
    _simulationContentExtentCache.clear();
    _simulationContentExtentSignature = null;
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController();
    final adjacentControllers = _adjacentScrollControllers.values.toSet();
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();
    _resetContinuousMetrics();
    setState(() {
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
    AppToast.info(context, message);
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

    if (_book.chapters.isEmpty || _readerLoadError != null) {
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
                    _readerLoadError ?? '这本书没有可阅读的正文',
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
                  if (_readerLoadError != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: _deleteDamagedBook,
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('删除损坏书籍'),
                    ),
                  ],
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
                              data: MediaQuery.of(
                                context,
                              ).copyWith(textScaler: TextScaler.noScaling),
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
                            if (_settings.readingMode ==
                                ReaderReadingMode.chapter)
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
    final slivers = <Widget>[];
    for (
      var chapterIndex = 0;
      chapterIndex < _book.chapters.length;
      chapterIndex++
    ) {
      final chapter = _book.chapters[chapterIndex];
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
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final block in chapter.epubBlocks)
                                _epubLayout.buildBlock(
                                  settings: _settings,
                                  block: block,
                                  themeColors: themeColors,
                                  width: contentWidth,
                                  simulationPage: false,
                                ),
                            ],
                          );
                        }
                        return _epubLayout.buildBlock(
                          settings: _settings,
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
                          shadows: _settings.effectiveFontShadows(
                            themeColors.text,
                          ),
                          height: _settings.lineHeight,
                          color: themeColors.text,
                          letterSpacing: 0.2,
                        ),
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

    return ValueListenableBuilder<double>(
      valueListenable: _pageDragOffsetNotifier,
      builder: (context, offset, _) {
        return switch (_settings.simulationPageTurnEffect) {
          SimulationPageTurnEffect.simulation => StraightBookTurnPages(
            width: width,
            dragOffset: offset,
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
  }) {
    final signature = SimulationLayoutSignature(
      contentWidth: contentWidth,
      settings: _settings,
    );
    if (_simulationContentExtentSignature?.matches(signature) != true) {
      _simulationContentExtentSignature = signature;
      _simulationContentExtentCache.clear();
    }
    final cached = _simulationContentExtentCache.remove(chapter);
    if (cached != null) {
      _simulationContentExtentCache[chapter] = cached;
      return cached;
    }

    final titleExtent = _bodyStartOffset(
      chapter,
      settings: _settings,
      mode: ReaderReadingMode.simulation,
      width: contentWidth,
    );
    if (chapter.hasRichEpubContent) {
      final extent =
          titleExtent +
          richBlocks.fold<double>(
            0,
            (extent, block) =>
                extent +
                _epubLayout.blockExtent(
                  block,
                  settings: _settings,
                  mode: ReaderReadingMode.simulation,
                  width: contentWidth,
                ),
          );
      _cacheSimulationContentExtent(chapter, extent);
      return extent;
    }

    final lineExtent = _resolvedSimulationLineExtent(_settings);
    final paragraphGap =
        _settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? lineExtent
        : 0.0;
    var bodyExtent = 0.0;
    for (var index = 0; index < paragraphs.length; index++) {
      final painter = _layoutBodyText(
        paragraphs[index],
        settings: _settings,
        mode: ReaderReadingMode.simulation,
        width: contentWidth,
      );
      try {
        bodyExtent += painter.computeLineMetrics().length * lineExtent;
      } finally {
        painter.dispose();
      }
      if (index < paragraphs.length - 1) bodyExtent += paragraphGap;
    }
    final extent = titleExtent + bodyExtent;
    _cacheSimulationContentExtent(chapter, extent);
    return extent;
  }

  void _cacheSimulationContentExtent(Chapter chapter, double extent) {
    _simulationContentExtentCache[chapter] = extent;
    while (_simulationContentExtentCache.length > 5) {
      _simulationContentExtentCache.remove(
        _simulationContentExtentCache.keys.first,
      );
    }
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
        return _epubLayout.buildBlock(
          settings: _settings,
          block: richBlocks[paragraphIndex],
          themeColors: themeColors,
          width: contentWidth,
          simulationPage: simulationPage,
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
      final bodyText = Text(
        paragraphs[paragraphIndex],
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
      );
      return Padding(
        padding: EdgeInsets.only(
          bottom: paragraphIndex == paragraphs.length - 1 ? 0 : paragraphGap,
        ),
        child: simulationPage
            ? bodyText
            : AnimatedDefaultTextStyle(
                duration: AppMotion.normal,
                curve: AppMotion.standard,
                style: bodyStyle,
                child: bodyText,
              ),
      );
    }

    final Widget scrollView;
    if (simulationPage) {
      final exactScrollExtent = _simulationChapterContentExtent(
        chapter: chapter,
        paragraphs: paragraphs,
        richBlocks: richBlocks,
        contentWidth: contentWidth,
      );
      scrollView = ListView.custom(
        key: scrollViewKey,
        controller: controller,
        primary: false,
        physics: physics,
        scrollCacheExtent: const ScrollCacheExtent.pixels(0),
        padding: scrollViewPadding,
        semanticChildCount: itemCount,
        childrenDelegate: ExactScrollExtentSliverChildBuilderDelegate(
          buildItem,
          childCount: itemCount,
          exactScrollExtent: exactScrollExtent,
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
