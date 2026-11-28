import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart'
    show
        RenderAbstractViewport,
        RenderOffstage,
        RenderParagraph,
        RenderRepaintBoundary,
        RenderSliver,
        ScrollCacheExtent,
        ScrollDirection;
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/services.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../models/book.dart';
import '../models/reader_bookmark.dart';
import '../models/reader_note.dart';
import '../models/reader_settings.dart';
import '../models/reading_paragraph.dart';
import '../repositories/reader_repositories.dart';
import '../services/font_service.dart';
import '../services/book_search_service.dart';
import '../services/motion_service.dart';
import '../services/storage_service.dart';
import '../services/storage/chapter_disk_store.dart' show LazyChapter;
import '../widgets/app_toast.dart';
import '../widgets/app_sheet.dart';
import '../widgets/chapter_list.dart';
import '../widgets/chapter_editor_sheet.dart';
import '../widgets/book_search_sheet.dart';
import '../widgets/reader_note_composer_sheet.dart';
import '../widgets/reader_note_quick_sheet.dart';
import '../widgets/reader_notes_hub_sheet.dart';
import '../widgets/reader_quote_card_sheet.dart';
import '../widgets/reader_settings_sheet.dart';
import '../widgets/pressable_scale.dart';
import '../controllers/chapter_editing_controller.dart';
import '../controllers/reader_progress_controller.dart';
import '../controllers/reader_search_controller.dart';
import '../controllers/reader_selection_controller.dart';
import '../controllers/reader_word_count_controller.dart';
import '../controllers/reader_window_controller.dart';
import 'reader/reader_epub_layout.dart';
import 'reader/reader_justified_text.dart';
import 'reader/reader_layout_cache.dart';
import 'reader/reader_note_highlights.dart';
import 'reader/reader_pagination_support.dart';
import 'reader/reader_selection_support.dart';
import 'reader/reader_selectable_block.dart';

part 'reader/reader_mode_views.dart';
part 'reader/reader_overlay_bars.dart';
part 'reader/reader_page_turn.dart';
part 'reader/reader_sheets_and_links.dart';

const double _simulationPageExtentTolerance = 0.01;

// Hairline drawn where the reader bars meet the page.
const double _readerChromeBorder = 0.5;

/// Reader screen — displays book content with settings overlay
class ReaderScreen extends StatefulWidget {
  final Book book;
  final ReaderRepository? repository;
  final ValueListenable<ReaderThemeColors>? transitionColors;
  final ValueChanged<ReaderSettings>? onSettingsChanged;
  final ReadingTextAnchor? initialAnchor;

  const ReaderScreen({
    super.key,
    required this.book,
    this.repository,
    this.transitionColors,
    this.onSettingsChanged,
    this.initialAnchor,
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
  // How far each reader bar reaches past its own content, so its inner edge
  // falls between two lines of text instead of across one.
  double _headerTextGap = 0;
  double _footerTextGap = 0;
  double _headerChromeInset = 0;
  double _footerChromeInset = 0;
  bool _chromeAlignmentScheduled = false;
  final GlobalKey _readerStackKey = GlobalKey();
  final GlobalKey _readingSurfaceKey = GlobalKey();
  final GlobalKey _headerRowKey = GlobalKey();
  final GlobalKey _footerRowKey = GlobalKey();
  late ScrollController _scrollController;
  bool _settingsLoaded = false;
  String? _readerLoadError;
  Timer? _saveTimer;
  final _pageDragOffsetNotifier = ValueNotifier<double>(0);
  // How far the curling leaf's corner has risen off its edge.
  final _pageCurlLiftNotifier = ValueNotifier<double>(0);
  late final Listenable _pageTurnPose = Listenable.merge([
    _pageDragOffsetNotifier,
    _pageCurlLiftNotifier,
  ]);
  // What this reader holds the display's fast refresh rate for: a finger on
  // the page, and a leaf that is off its resting place.
  final Object _touchMotion = Object();
  final Object _pageMotion = Object();
  late final AnimationController _pageTurnController;
  Animation<double>? _pageTurnAnimation;
  Animation<double>? _pageCurlLiftAnimation;
  double _pageDragOffset = 0;
  // The finger's own travel past the book's first or last page. The leaf
  // shows only a rubber-banded part of it, so the drag has to remember the
  // rest to keep tracking the finger.
  double _pageEdgeStretch = 0;
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
  // Finger position that counts as zero drag once the touch slop is passed.
  Offset? _simulationTurnAnchor;
  PageCurlCorner _pageCurlCorner = PageCurlCorner.middle;
  final ReaderSelectionController _selectionController =
      ReaderSelectionController();
  final ReaderProgressController _progressController =
      ReaderProgressController();
  final ReaderSearchController _searchController = ReaderSearchController();
  bool _readingModeReloading = false;
  Timer? _reloadingGuardTimer;
  // A modal with a text field (currently full-text search) can cause Android
  // to report a transient keyboard inset.  Simulation pagination is based on
  // the reader viewport, so never allow that transient inset to repaginate the
  // paper behind an open modal.
  bool _readerModalOpen = false;
  double? _simulationViewportLock;
  bool _closingReader = false;
  final _windowController = ReaderWindowController();
  late final Future<void> _windowReady;
  ReadingProgress? _currentProgress;
  Set<String> _collapsedTocGroupIds = <String>{};
  List<ReaderBookmark> _bookmarks = const <ReaderBookmark>[];
  List<ReaderNote> _notes = const <ReaderNote>[];
  Map<int, Map<int, List<ReaderNote>>> _notesByChapterParagraph =
      const <int, Map<int, List<ReaderNote>>>{};
  final ReaderNoteHighlightRegistry _noteHighlightRegistry =
      ReaderNoteHighlightRegistry();
  final ReaderEpubLinkRegistry _epubLinkRegistry = ReaderEpubLinkRegistry();
  DateTime? _lastEpubLinkOpenedAt;
  ReadingTextAnchor? _pinnedReadingAnchor;
  Locale? _readerLocale;
  // Resolving the reading anchor lays out every paragraph above the viewport,
  // so the toggle icon reads this cached flag instead of probing each build.
  // It is refreshed when the chrome appears and whenever a mark is committed.
  bool _currentPositionBookmarked = false;
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
  final Map<int, GlobalKey> _continuousChapterKeys = <int, GlobalKey>{};
  int _continuousWindowStart = 0;
  int _continuousWindowEnd = -1;
  int _continuousViewGeneration = 0;
  bool _continuousRecenterScheduled = false;
  int _continuousAnchorChapterIndex = 0;
  final Map<int, double> _continuousChapterStarts = <int, double>{};
  final Map<int, double> _continuousChapterExtents = <int, double>{};
  bool _continuousMetricsScheduled = false;
  bool _prefetchRefreshScheduled = false;
  int _continuousRestoreSerial = 0;
  double? _pendingContinuousProgress;
  double? _pendingContinuousOffset;
  ReadingTextAnchor? _pendingContinuousTextAnchor;
  SimulationPageTarget? _simulationPageTarget;
  ScrollController? _simulationPreviewController;
  ScrollController? _simulationPaperBackController;
  late final ReaderWordCountController _wordCountController;
  ScrollSnapshot _lastScrollSnapshot = const ScrollSnapshot(
    offset: 0,
    progress: 0,
  );
  final ReaderLayoutCache _layoutCache = ReaderLayoutCache();
  double _readerViewportWidth = 0;
  double _readerViewportHeight = 0;
  EdgeInsets _readerViewPadding = EdgeInsets.zero;
  TextScaler _readerTextScaler = TextScaler.noScaling;

  ReaderEpubLayout get _epubLayout {
    final activeHeight = _simulationViewportLock ?? _readerViewportHeight;
    return ReaderEpubLayout(
      textScaler: _readerTextScaler,
      resolveSimulationLineExtent: _resolvedSimulationLineExtent,
      onOpenLink: _handleEpubLink,
      linkRegistry: _epubLinkRegistry,
      maxImageHeight: activeHeight > 0
          ? math.max(200.0, activeHeight - 80.0)
          : 560.0,
      locale: _readerLocale,
    );
  }

  GlobalKey _continuousKeyFor(int chapterIndex) =>
      _continuousChapterKeys.putIfAbsent(chapterIndex, () => GlobalKey());

  void _prefetchChapters(Iterable<int> indices) {
    for (final index in indices) {
      if (index < 0 || index >= _book.chapters.length) continue;
      final chapter = _book.chapters[index];
      if (chapter is LazyChapter && !chapter.store.isCached(index)) {
        unawaited(
          chapter.store.prefetch(index).then((_) {
            if (!mounted ||
                _settings.readingMode != ReaderReadingMode.continuous ||
                !chapter.store.isCached(index) ||
                index < _continuousWindowStart ||
                index > _continuousWindowEnd ||
                _prefetchRefreshScheduled) {
              return;
            }
            _prefetchRefreshScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _prefetchRefreshScheduled = false;
              if (mounted &&
                  _settings.readingMode == ReaderReadingMode.continuous) {
                setState(() {});
              }
            });
          }),
        );
      }
    }
  }

  void _resetContinuousWindowAround(
    int anchorIndex, {
    bool recreateView = false,
  }) {
    final count = _book.chapters.length;
    if (count == 0) {
      _continuousAnchorChapterIndex = 0;
      _continuousWindowStart = 0;
      _continuousWindowEnd = -1;
      _continuousChapterKeys.clear();
      if (recreateView) _continuousViewGeneration++;
      return;
    }
    final clamped = anchorIndex.clamp(0, count - 1);
    _continuousAnchorChapterIndex = clamped;
    _continuousWindowStart = math.max(0, clamped - 1);
    _continuousWindowEnd = math.min(count - 1, clamped + 2);
    _continuousChapterKeys.removeWhere(
      (index, _) =>
          index < _continuousWindowStart || index > _continuousWindowEnd,
    );
    if (recreateView) _continuousViewGeneration++;
  }

  @override
  void initState() {
    super.initState();
    _storage = widget.repository ?? StorageService();
    _fontService = FontService(_storage);
    _chapterEditingController = ChapterEditingController(_storage);
    _book = widget.book;
    _chapterIndex = 0;
    _settings = const ReaderSettings();
    _resetContinuousWindowAround(0);
    _wordCountController = ReaderWordCountController(_storage, _book);
    _scrollController = _createScrollController();
    _selectionController.active.addListener(
      _handleTextSelectionActivityChanged,
    );
    WidgetsBinding.instance.addObserver(this);
    _windowController.addListener(_handleWindowMetrics);
    _windowReady = _windowController.initialize();
    // Keep screen on while reading — the user should not have to tap to
    // prevent the device from sleeping mid-paragraph.
    _ignorePlatformFuture(
      ReaderWindowController.setKeepScreenOn(this, true),
      'enable keep screen on',
    );
    if (_book.isPrivate) {
      _ignorePlatformFuture(
        ReaderWindowController.setSecure(this, true),
        'enable private reader secure flag',
      );
    }
    // Keep the shelf stable while the book-opening route is still revealing
    // it underneath. The reader hides the status bar only after the opening
    // animation has fully settled.
    _showLibrarySystemBars();
    _hideStatusBarTimer = Timer(AppMotion.bookOpen, _hideStatusBarForReader);
    MotionService.holdFor(AppMotion.bookOpen);
    _pageDragOffsetNotifier.addListener(_holdPageMotion);
    MotionService.powerSaveMode.addListener(_handlePowerSaveModeChanged);
    _pageTurnController =
        AnimationController(vsync: this, duration: AppMotion.pageTurn)
          ..addListener(() {
            final animation = _pageTurnAnimation;
            if (animation == null) return;
            final lift = _pageCurlLiftAnimation;
            if (lift != null) _pageCurlLiftNotifier.value = lift.value;
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
      _windowController.showChrome(false),
      'hide reader status bar',
    );
  }

  void _showStatusBar() {
    if (!mounted) return;
    _applySystemBarStyle();
    _ignorePlatformFuture(
      _windowController.showChrome(true),
      'show status bar',
    );
  }

  void _showLibrarySystemBars() {
    _applySystemBarStyle();
    _ignorePlatformFuture(
      _windowController.showChrome(true),
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

  void _handleWindowMetrics() {
    if (mounted) setState(() {});
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
    MotionService.holdFor(AppMotion.bookClose);
    Navigator.of(context).pop();
  }

  Future<void> _deleteDamagedBook() async {
    await _storage.deleteBook(_book.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _loadInitialState() async {
    await _windowReady;
    if (!mounted) return;
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
    // Marks and notes are auxiliary. Loading them separately keeps a failure
    // from discarding the settings and reading position fetched above.
    try {
      _notes = await _storage.getNotes(_book.id);
      _rebuildNotesIndex(_notes);
      _bookmarks = await _storage.getBookmarks(_book.id);
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to load reader notes and bookmarks: $error');
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
    final launchAnchor = widget.initialAnchor;
    if (_book.chapters.isNotEmpty) {
      if (launchAnchor != null) {
        _chapterIndex = launchAnchor.chapterIndex.clamp(
          0,
          _book.chapters.length - 1,
        );
      } else if (savedProgress != null) {
        _chapterIndex = savedProgress.chapterIndex.clamp(
          0,
          _book.chapters.length - 1,
        );
      }
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
    _resetContinuousWindowAround(_chapterIndex, recreateView: true);
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
      _prefetchChapters([
        for (
          var i = _continuousWindowStart;
          i <= _continuousWindowEnd;
          i++
        )
          i,
      ]);
      _requestContinuousRestore(
        hasSavedProgressRatio ? safeRestoredProgress : 0,
        offset: launchAnchor != null ? null : safeRestoredOffset,
        textAnchor: launchAnchor,
      );
    } else {
      _prefetchChapters([_chapterIndex - 1, _chapterIndex + 1]);
      _scheduleAdjacentWarmup();
      _requestScrollRestore(
        offset: launchAnchor != null ? 0 : safeRestoredOffset,
        progress: launchAnchor != null
            ? null
            : (hasSavedProgressRatio ? safeRestoredProgress : null),
        preferProgress: launchAnchor == null && hasSavedProgressRatio,
        textAnchor: launchAnchor,
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

  void _beginReadingModeReload() {
    _reloadingGuardTimer?.cancel();
    _reloadingGuardTimer = Timer(
      const Duration(milliseconds: 900),
      _finishReadingModeReload,
    );
    if (!_readingModeReloading && mounted) {
      setState(() => _readingModeReloading = true);
    }
  }

  void _finishReadingModeReload() {
    _reloadingGuardTimer?.cancel();
    _reloadingGuardTimer = null;
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
    _continuousRecenterScheduled = false;
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
    _resetContinuousWindowAround(_chapterIndex);
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
      if (extent == null || !extent.isFinite || extent < 0) {
        if (attempt < 20) {
          _restoreContinuousPosition(serial, attempt + 1);
        } else {
          _clearPendingContinuousRestore(serial);
        }
        return;
      }
      final viewport = _scrollController.position.viewportDimension;
      final chapterMax = math.max(0.0, extent - 1.0);
      final readableExtent = math.max(0.0, extent - viewport);
      final textAnchor = _pendingContinuousTextAnchor;
      final anchoredOffset = textAnchor == null
          ? null
          : _scrollOffsetForTextAnchor(
              textAnchor,
              settings: _settings,
              mode: ReaderReadingMode.continuous,
              viewportDimension: viewport,
              maxExtent: chapterMax,
            );
      final requestedOffset = anchoredOffset ?? _pendingContinuousOffset;
      final target =
          (requestedOffset != null
                  ? requestedOffset.clamp(0.0, chapterMax).toDouble()
                  : _pendingContinuousProgress! * readableExtent)
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
      _refreshContinuousMetrics(updateActiveChapter: false);
      final snapshot = _continuousSnapshotForChapter(_chapterIndex);
      _recordCurrentChapterPosition(snapshot);
      _prefetchChapters([
        for (var i = _continuousWindowStart; i <= _continuousWindowEnd; i++) i,
      ]);
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

  void _scheduleContinuousIdleRecenter() {
    if (_continuousRecenterScheduled ||
        _settings.readingMode != ReaderReadingMode.continuous ||
        (_chapterIndex - _continuousAnchorChapterIndex).abs() < 4) {
      return;
    }
    _continuousRecenterScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _continuousRecenterScheduled = false;
      if (!mounted ||
          _settings.readingMode != ReaderReadingMode.continuous ||
          _closingReader ||
          _readerModalOpen ||
          _selectionController.active.value ||
          _pendingContinuousProgress != null ||
          (_chapterIndex - _continuousAnchorChapterIndex).abs() < 4 ||
          !_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions ||
          _scrollController.position.isScrollingNotifier.value) {
        return;
      }
      final currentIndex = _chapterIndex;
      final start = _continuousChapterStarts[currentIndex];
      final extent = _continuousChapterExtents[currentIndex];
      if (start == null || extent == null || !extent.isFinite) return;
      final localOffset = _scrollController.offset - start;
      // Preserve the exact screen y-position when promoting the active chapter
      // to be the CustomScrollView's center sliver: the center chapter uses
      // `viewPadding.top + AppSpacing.lg` at its top while non-anchor chapters
      // use `AppSpacing.xxl`.
      final oldTop = currentIndex == _continuousAnchorChapterIndex
          ? _readerViewPadding.top + AppSpacing.lg
          : AppSpacing.xxl;
      final newTop = _readerViewPadding.top + AppSpacing.lg;
      final adjustedOffset = localOffset + (newTop - oldTop);

      final previousController = _scrollController;
      previousController.removeListener(_scheduleProgressSave);
      _resetContinuousWindowAround(currentIndex, recreateView: true);
      _continuousChapterStarts
        ..clear()
        ..[currentIndex] = 0.0;
      _continuousChapterExtents.clear();
      final nextController = _createScrollController(
        adjustedOffset.isFinite ? adjustedOffset : 0.0,
      );
      _setReaderState(() => _scrollController = nextController);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousController.dispose();
        if (!mounted ||
            !identical(_scrollController, nextController) ||
            !nextController.hasClients ||
            !nextController.position.hasContentDimensions) {
          return;
        }
        final clamped = adjustedOffset
            .clamp(
              nextController.position.minScrollExtent,
              nextController.position.maxScrollExtent,
            )
            .toDouble();
        if ((nextController.offset - clamped).abs() > 0.5) {
          nextController.jumpTo(clamped);
        }
        _refreshContinuousMetrics(updateActiveChapter: false);
        _prefetchChapters([
          for (var i = _continuousWindowStart; i <= _continuousWindowEnd; i++)
            i,
        ]);
      });
    });
  }

  void _refreshContinuousMetrics({required bool updateActiveChapter}) {
    if (_book.chapters.isEmpty || _continuousWindowEnd < _continuousWindowStart) {
      return;
    }
    final anchor = _continuousAnchorChapterIndex.clamp(
      _continuousWindowStart,
      _continuousWindowEnd,
    );
    _continuousAnchorChapterIndex = anchor;
    for (
      var index = _continuousWindowStart;
      index <= _continuousWindowEnd;
      index++
    ) {
      final renderObject = _continuousChapterKeys[index]?.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderSliver) continue;
      final extent = renderObject.geometry?.scrollExtent;
      if (extent != null && extent.isFinite && extent >= 0) {
        _continuousChapterExtents[index] = extent;
      }
    }

    _continuousChapterStarts
      ..clear()
      ..[anchor] = 0.0;
    for (var index = anchor + 1; index <= _continuousWindowEnd; index++) {
      final prevStart = _continuousChapterStarts[index - 1];
      final prevExtent = _continuousChapterExtents[index - 1];
      if (prevStart == null || prevExtent == null) break;
      _continuousChapterStarts[index] = prevStart + prevExtent;
    }
    for (var index = anchor - 1; index >= _continuousWindowStart; index--) {
      final nextStart = _continuousChapterStarts[index + 1];
      final extent = _continuousChapterExtents[index];
      if (nextStart == null || extent == null) break;
      _continuousChapterStarts[index] = nextStart - extent;
    }

    if (!updateActiveChapter ||
        !_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions ||
        _pendingContinuousProgress != null) {
      return;
    }
    final probeOffset = _scrollController.offset <= 0.5
        ? _scrollController.offset + 0.5
        : _scrollController.offset +
              _visualTopInsetForMode(ReaderReadingMode.continuous) +
              0.5;
    var activeIndex = _chapterIndex.clamp(
      _continuousWindowStart,
      _continuousWindowEnd,
    );
    var activeStart = double.negativeInfinity;
    for (final entry in _continuousChapterStarts.entries) {
      if (entry.key < _continuousWindowStart ||
          entry.key > _continuousWindowEnd) {
        continue;
      }
      if (entry.value <= probeOffset && entry.value >= activeStart) {
        activeIndex = entry.key;
        activeStart = entry.value;
      }
    }
    activeIndex = activeIndex.clamp(0, _book.chapters.length - 1);

    var desiredStart = _continuousWindowStart;
    var desiredEnd = _continuousWindowEnd;
    if (activeIndex <= _continuousWindowStart + 1 &&
        _continuousWindowStart > 0) {
      desiredStart = math.max(0, activeIndex - 2);
    }
    if (activeIndex >= _continuousWindowEnd - 1 &&
        _continuousWindowEnd < _book.chapters.length - 1) {
      desiredEnd = math.min(_book.chapters.length - 1, activeIndex + 2);
    }
    final safeMin = math.max(0, math.min(anchor, activeIndex) - 2);
    final safeMax = math.min(
      _book.chapters.length - 1,
      math.max(anchor, activeIndex) + 2,
    );
    if (desiredStart < safeMin) desiredStart = safeMin;
    if (desiredEnd > safeMax) desiredEnd = safeMax;
    if (desiredStart > anchor) desiredStart = anchor;
    if (desiredEnd < anchor) desiredEnd = anchor;

    final windowChanged =
        desiredStart != _continuousWindowStart ||
        desiredEnd != _continuousWindowEnd;
    final chapterChanged = activeIndex != _chapterIndex;
    if (chapterChanged) {
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
    }
    if (windowChanged || chapterChanged) {
      final newlyAdded = <int>[
        for (var i = desiredStart; i < _continuousWindowStart; i++) i,
        for (var i = _continuousWindowEnd + 1; i <= desiredEnd; i++) i,
      ];
      _continuousWindowStart = desiredStart;
      _continuousWindowEnd = desiredEnd;
      _continuousChapterKeys.removeWhere(
        (index, _) => index < desiredStart || index > desiredEnd,
      );
      _continuousChapterExtents.removeWhere(
        (index, _) => index < desiredStart || index > desiredEnd,
      );
      _continuousChapterStarts.removeWhere(
        (index, _) => index < desiredStart || index > desiredEnd,
      );
      setState(() {
        if (chapterChanged) _chapterIndex = activeIndex;
      });
      if (newlyAdded.isNotEmpty) {
        _prefetchChapters(newlyAdded);
      }
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
    final rawLocal = _scrollController.offset - start;
    final readableExtent = math.max(0.0, extent - viewport);
    final localOffset = rawLocal
        .clamp(0.0, math.max(0.0, extent - 1.0))
        .toDouble();
    return ScrollSnapshot(
      offset: localOffset,
      progress: readableExtent > 0
          ? (rawLocal / readableExtent).clamp(0.0, 1.0).toDouble()
          : 0,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ignorePlatformFuture(
      ReaderWindowController.setKeepScreenOn(this, false),
      'disable keep screen on',
    );
    if (_book.isPrivate) {
      _ignorePlatformFuture(
        ReaderWindowController.setSecure(this, false),
        'disable private reader secure flag',
      );
    }
    _hideStatusBarTimer?.cancel();
    _saveTimer?.cancel();
    _settingsApplyTimer?.cancel();
    _reloadingGuardTimer?.cancel();
    if (!_closingReader) unawaited(_saveProgress());
    _discardPageTurnSnapshot();
    _discardReversePageTurnSnapshot();
    _wordCountController.dispose();
    MotionService.powerSaveMode.removeListener(_handlePowerSaveModeChanged);
    MotionService.release(_touchMotion);
    MotionService.release(_pageMotion);
    _pageTurnController.dispose();
    _pageDragOffsetNotifier.dispose();
    _pageCurlLiftNotifier.dispose();
    _selectionController.active.removeListener(
      _handleTextSelectionActivityChanged,
    );
    _selectionController.dispose();
    _searchController.dispose();
    _layoutCache.clear();
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
    _windowController.removeListener(_handleWindowMetrics);
    _windowController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _ignorePlatformFuture(
      ReaderWindowController.setKeepScreenOn(
        this,
        state == AppLifecycleState.resumed,
      ),
      'update reader keep screen on',
    );
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
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

  List<String> _paragraphsFor(Chapter chapter) =>
      _layoutCache.paragraphs(chapter);

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
        current.importedFontPath != next.importedFontPath ||
        current.pageMargin != next.pageMargin ||
        current.paragraphSpacing != next.paragraphSpacing ||
        current.readingMode != next.readingMode;
  }

  double _visualTopInsetForMode(ReaderReadingMode mode) => switch (mode) {
    ReaderReadingMode.simulation => 0.0,
    ReaderReadingMode.chapter ||
    ReaderReadingMode.continuous => _readerViewPadding.top + AppSpacing.lg,
  };

  /// [topBias] shifts the probe down the page before the anchor is resolved.
  /// The reader almost always clips its first line, so passing half a line lets
  /// callers anchor on the first line that is actually whole on screen.
  ReadingTextAnchor? _captureReadingTextAnchor(
    ScrollSnapshot snapshot, {
    double topBias = 0,
  }) {
    if (_readerViewportWidth <= 0 || _book.chapters.isEmpty) return null;
    final paragraphs = _paragraphsFor(_currentChapter);
    if (paragraphs.isEmpty) return null;
    if (topBias == 0 && snapshot.offset <= 0.5) {
      return ReadingTextAnchor(
        chapterIndex: _chapterIndex,
        paragraphIndex: 0,
        characterOffset: 0,
        isChapterTop: true,
      );
    }
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
    final visualY =
        snapshot.offset + _visualTopInsetForMode(settings.readingMode) + topBias;
    if (topBias == 0 && visualY < bodyStart) {
      return ReadingTextAnchor(
        chapterIndex: _chapterIndex,
        paragraphIndex: 0,
        characterOffset: 0,
        isChapterTop: true,
      );
    }
    if (_currentChapter.hasRichEpubContent) {
      return _captureRichEpubTextAnchor(
        chapter: _currentChapter,
        bodyOffset: visualY - bodyStart,
        settings: settings,
        mode: settings.readingMode,
        width: width,
      );
    }
    final bodyY = math.max(0.0, visualY - bodyStart);
    final simulation = settings.readingMode == ReaderReadingMode.simulation;
    final lineExtent = _resolvedSimulationOrNaturalLineExtent(
      settings,
      settings.readingMode,
    );
    final paragraphGap =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? lineExtent
        : 0.0;
    const boundaryEpsilon = 0.5;
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
        final paragraphHeight = simulation
            ? painter.computeLineMetrics().length * lineExtent
            : painter.height;
        if (index < paragraphs.length - 1 &&
            bodyY >= cursor + paragraphHeight - boundaryEpsilon) {
          if (bodyY <
              cursor + paragraphHeight + paragraphGap - boundaryEpsilon) {
            return ReadingTextAnchor(
              chapterIndex: _chapterIndex,
              paragraphIndex: index + 1,
              characterOffset: 0,
            );
          }
          cursor += paragraphHeight + paragraphGap;
          continue;
        }
        final double probeY;
        if (painter.height <= 0) {
          probeY = 0;
        } else if (simulation && lineExtent > 0) {
          final lineCount = math.max(1, painter.computeLineMetrics().length);
          final targetLine = (((bodyY - cursor) + boundaryEpsilon) / lineExtent)
              .floor()
              .clamp(0, lineCount - 1);
          probeY = ((targetLine + 0.5) * lineExtent)
              .clamp(0.0, math.max(0.0, painter.height - 0.01))
              .toDouble();
        } else {
          final rawLocalY = math.max(0.0, bodyY - cursor);
          probeY = (rawLocalY + math.min(lineExtent * 0.25, 4.0))
              .clamp(0.0, math.max(0.0, painter.height - 0.01))
              .toDouble();
        }
        final position = painter.height <= 0
            ? 0
            : painter.getPositionForOffset(Offset(0, probeY)).offset;
        return ReadingTextAnchor(
          chapterIndex: _chapterIndex,
          paragraphIndex: index,
          characterOffset: position.clamp(0, paragraph.length),
        );
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
    if (anchor.isChapterTop) return 0;
    final chapter = _book.chapters[anchor.chapterIndex];
    final paragraphs = _paragraphsFor(chapter);
    if (paragraphs.isEmpty) return 0;
    final width = math.max(
      1.0,
      _readerViewportWidth - settings.pageMargin.horizontalPadding * 2,
    );
    final bodyStart = _bodyStartOffset(
      chapter,
      settings: settings,
      mode: mode,
      width: width,
    );
    if (chapter.hasRichEpubContent) {
      final bodyOffset = _richEpubOffsetForAnchor(
        chapter: chapter,
        anchor: anchor,
        settings: settings,
        mode: mode,
        width: width,
      );
      final contentY = bodyStart + bodyOffset;
      if (mode == ReaderReadingMode.simulation && viewportDimension > 0) {
        final pageOffset =
            ((contentY + 0.01) / viewportDimension).floor() *
            viewportDimension;
        return _alignSimulationOffset(
          pageOffset,
          pageExtent: viewportDimension,
          maxExtent: maxExtent,
        );
      }
      final rawOffset = contentY - _visualTopInsetForMode(mode);
      return rawOffset.clamp(0.0, maxExtent).toDouble();
    }
    final targetIndex = anchor.paragraphIndex.clamp(0, paragraphs.length - 1);
    final simulation = mode == ReaderReadingMode.simulation;
    final lineExtent = _resolvedSimulationOrNaturalLineExtent(settings, mode);
    final paragraphGap =
        settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? lineExtent
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
          if (simulation && lineExtent > 0) {
            final lineIndex = ((caretOffset.dy + 0.01) / lineExtent).floor();
            bodyOffset += lineIndex * lineExtent;
          } else {
            bodyOffset += caretOffset.dy;
          }
        } else {
          final paragraphHeight = simulation
              ? painter.computeLineMetrics().length * lineExtent
              : painter.height;
          bodyOffset += paragraphHeight + paragraphGap;
        }
      } finally {
        painter.dispose();
      }
    }
    final contentY = bodyStart + bodyOffset;
    if (mode == ReaderReadingMode.simulation && viewportDimension > 0) {
      final pageOffset =
          ((contentY + 0.01) / viewportDimension).floor() * viewportDimension;
      return _alignSimulationOffset(
        pageOffset,
        pageExtent: viewportDimension,
        maxExtent: maxExtent,
      );
    }
    final rawOffset = contentY - _visualTopInsetForMode(mode);
    return rawOffset.clamp(0.0, maxExtent).toDouble();
  }

  double _resolvedSimulationOrNaturalLineExtent(
    ReaderSettings settings,
    ReaderReadingMode mode,
  ) => mode == ReaderReadingMode.simulation
      ? _resolvedSimulationLineExtent(settings)
      : settings.fontSize * settings.lineHeight;

  double _resolvedSimulationLineExtent(ReaderSettings settings) =>
      _layoutCache.lineExtent(
        SimulationLayoutSignature(
          contentWidth: 0,
          settings: settings,
          mode: ReaderReadingMode.simulation,
          locale: _readerLocale,
        ),
        () => _measureSimulationLineExtent(settings),
      );

  double _measureSimulationLineExtent(ReaderSettings settings) {
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
      locale: _readerLocale,
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
        chapter.index == _continuousAnchorChapterIndex
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
      locale: _readerLocale,
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
      locale: _readerLocale,
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

  double _epubAnchorProbeY(
    TextPainter painter,
    double rawLocalY, {
    required bool simulation,
    required double naturalLineExtent,
  }) {
    if (painter.height <= 0) return 0;
    const boundaryEpsilon = 0.5;
    if (simulation) {
      final metrics = painter.computeLineMetrics();
      if (metrics.isNotEmpty) {
        var lineTop = 0.0;
        for (final line in metrics) {
          final lineHeight = line.height > 0 ? line.height : naturalLineExtent;
          final lineBottom = lineTop + lineHeight;
          if (lineBottom > rawLocalY + boundaryEpsilon) {
            return (lineTop + lineHeight * 0.5)
                .clamp(0.0, math.max(0.0, painter.height - 0.01))
                .toDouble();
          }
          lineTop = lineBottom;
        }
        final last = metrics.last;
        final lastHeight = last.height > 0 ? last.height : naturalLineExtent;
        return math.max(0.0, painter.height - lastHeight * 0.5);
      }
    }
    return (rawLocalY + math.min(naturalLineExtent * 0.25, 4.0))
        .clamp(0.0, math.max(0.0, painter.height - 0.01))
        .toDouble();
  }

  ReadingTextAnchor _captureRichEpubTextAnchor({
    required Chapter chapter,
    required double bodyOffset,
    required ReaderSettings settings,
    required ReaderReadingMode mode,
    required double width,
  }) {
    const boundaryEpsilon = 0.5;
    final safeOffset = math.max(0.0, bodyOffset);
    final simulation = mode == ReaderReadingMode.simulation;
    final naturalLineExtent = _resolvedSimulationOrNaturalLineExtent(
      settings,
      mode,
    );
    var lastTextBlockIndex = -1;
    for (var i = 0; i < chapter.epubBlocks.length; i++) {
      final candidate = chapter.epubBlocks[i];
      if (candidate.isText && candidate.text.trim().isNotEmpty) {
        lastTextBlockIndex = i;
      }
    }
    var cursor = 0.0;
    var paragraphIndex = 0;
    var lastParagraphIndex = 0;
    for (var blockIdx = 0; blockIdx < chapter.epubBlocks.length; blockIdx++) {
      final block = chapter.epubBlocks[blockIdx];
      final metrics = _epubLayout.blockMetrics(
        block,
        settings: settings,
        mode: mode,
        width: width,
      );
      final extent = metrics.total;
      if (!block.isText || block.text.trim().isEmpty) {
        if (safeOffset < cursor + extent - boundaryEpsilon) {
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
      if (safeOffset < cursor + extent - boundaryEpsilon ||
          blockIdx == lastTextBlockIndex) {
        final innerPadTop = _epubLayout.blockInnerPadding(block).top;
        final textTop = cursor + metrics.leading + innerPadTop;
        final rawLocalY = safeOffset - textTop;
        final row = _epubLayout.layoutTableRow(
          block,
          settings: settings,
          mode: mode,
          width: width,
        );
        if (row != null) {
          // A directory row has two columns of different heights. The reading
          // position is the left cell's line under the viewport's top edge;
          // offsets past its end clamp to its last line.
          try {
            final contentBottom = textTop + row.contentHeight;
            if (blockIdx < lastTextBlockIndex &&
                safeOffset >= contentBottom - boundaryEpsilon) {
              return ReadingTextAnchor(
                chapterIndex: chapter.index,
                paragraphIndex: paragraphIndex + 1,
                characterOffset: 0,
              );
            }
            if (rawLocalY <= boundaryEpsilon) {
              return ReadingTextAnchor(
                chapterIndex: chapter.index,
                paragraphIndex: paragraphIndex,
                characterOffset: 0,
              );
            }
            final leftHeight = row.leftPainter.height;
            final leftY = _epubAnchorProbeY(
              row.leftPainter,
              rawLocalY,
              simulation: simulation,
              naturalLineExtent: naturalLineExtent,
            );
            final leftOffset = leftHeight <= 0
                ? 0
                : row.leftPainter.getPositionForOffset(Offset(0, leftY)).offset;
            return ReadingTextAnchor(
              chapterIndex: chapter.index,
              paragraphIndex: paragraphIndex,
              characterOffset: row.clampLeftOffset(leftOffset),
            );
          } finally {
            row.dispose();
          }
        }
        final painter = _epubLayout.layoutTextBlock(
          block,
          settings: settings,
          mode: mode,
          width: width,
        );
        try {
          final contentBottom = textTop + painter.height;
          if (blockIdx < lastTextBlockIndex &&
              safeOffset >= contentBottom - boundaryEpsilon) {
            return ReadingTextAnchor(
              chapterIndex: chapter.index,
              paragraphIndex: paragraphIndex + 1,
              characterOffset: 0,
            );
          }
          if (rawLocalY <= boundaryEpsilon) {
            return ReadingTextAnchor(
              chapterIndex: chapter.index,
              paragraphIndex: paragraphIndex,
              characterOffset: 0,
            );
          }
          final probeY = _epubAnchorProbeY(
            painter,
            rawLocalY,
            simulation: simulation,
            naturalLineExtent: naturalLineExtent,
          );
          final position = painter.height <= 0
              ? 0
              : painter.getPositionForOffset(Offset(0, probeY)).offset;
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
          final innerPadTop = _epubLayout.blockInnerPadding(block).top;
          final row = _epubLayout.layoutTableRow(
            block,
            settings: settings,
            mode: mode,
            width: width,
          );
          if (row != null) {
            // The offset lands in the left cell, the right cell, or the
            // separator between them; the row maps each to its own column.
            try {
              final paragraph = _epubLayout.formatParagraph(block);
              return cursor +
                  metrics.leading +
                  innerPadTop +
                  row.caretDyForOffset(
                    anchor.characterOffset.clamp(0, paragraph.length),
                  );
            } finally {
              row.dispose();
            }
          }
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
            return cursor + metrics.leading + innerPadTop + caret.dy;
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

  void _setReaderState(VoidCallback fn) => setState(fn);

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
        child: AppOverlayTheme(colors: themeColors, child: content),
      );
    }

    final fontFamily = _settings.effectiveFontFamily;
    _readerLocale = Localizations.maybeLocaleOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final contentInsets = _windowController.contentInsets(viewPadding);
    final chromeInsets = _windowController.chromeInsets(viewPadding);
    final stableTopInset = math.max(chromeInsets.top, contentInsets.top);
    final horizontalPadding = _settings.pageMargin.horizontalPadding;
    _headerChromeInset = stableTopInset;
    _footerChromeInset = viewPadding.bottom + AppSpacing.sm;
    // Font, margin or window changes move the lines under the visible bars.
    if (_showOverlay) _scheduleChromeAlignment();

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
          key: _readerStackKey,
          children: [
            // ── Stable reader background ─────────────
            // The book-opening route draws the visible shared-element
            // choreography. This layer simply guarantees an opaque reading
            // surface once the transition has expanded to full screen.
            Positioned.fill(child: ColoredBox(color: themeColors.background)),

            // ── Reading content ─────────────────────
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _pinnedReadingAnchor = null;
                } else if (notification is UserScrollNotification &&
                    notification.direction != ScrollDirection.idle) {
                  _pinnedReadingAnchor = null;
                } else if (notification is ScrollEndNotification) {
                  if (_showOverlay) _scheduleChromeAlignment();
                  if (_settings.readingMode == ReaderReadingMode.continuous) {
                    _scheduleContinuousIdleRecenter();
                  }
                }
                return false;
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth - contentInsets.horizontal;
                  final reportedHeight = constraints.maxHeight;
                  final stableViewPadding = contentInsets;
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
                          _settings.readingMode ==
                              ReaderReadingMode.simulation &&
                          _simulationViewportLock != null
                      ? _simulationViewportLock!
                      : reportedHeight;
                  return Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _handleReadingPointerDown,
                    onPointerMove: (event) =>
                        _handleReadingPointerMove(event, width, readerHeight),
                    onPointerUp: (event) =>
                        _handleReadingPointerUp(event, width),
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
                          : (details) =>
                                _handleHorizontalDragEnd(details, width),
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
                            // Pages parked beside the current one stay out of
                            // the side insets, where a camera or a navigation
                            // bar would otherwise show their first lines.
                            Padding(
                              padding: EdgeInsets.only(
                                left: contentInsets.left,
                                right: contentInsets.right,
                              ),
                              child: ClipRect(
                                key: _readingSurfaceKey,
                                child: MediaQuery(
                                  data: MediaQuery.of(context).copyWith(
                                    textScaler: TextScaler.noScaling,
                                    boldText: false,
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
            ),

            _buildReaderHeaderBar(
              themeColors: themeColors,
              stableTopInset: stableTopInset,
              contentInsets: contentInsets,
            ),
            _buildReaderBottomBar(
              themeColors: themeColors,
              viewPadding: viewPadding,
              contentInsets: contentInsets,
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
}
