import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, ScrollCacheExtent, SelectedContent;
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/font_service.dart';
import '../services/storage_service.dart';
import '../widgets/chapter_list.dart';
import '../widgets/reader_settings_sheet.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/reading_progress_bar.dart';

/// Reader screen — displays book content with settings overlay
class ReaderScreen extends StatefulWidget {
  final Book book;

  const ReaderScreen({super.key, required this.book});

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
  bool _closingReader = false;
  double _viewPaddingTop = 0;
  ReadingProgress? _currentProgress;
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
  ui.Image? _pageTurnSnapshot;
  int _pageTurnSnapshotSerial = 0;
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

  ScrollController _controllerForAdjacentChapter(int chapterIndex) {
    final existing = _adjacentScrollControllers[chapterIndex];
    if (existing != null) {
      _scheduleAdjacentScrollRestore(chapterIndex, existing);
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
    _scheduleAdjacentScrollRestore(chapterIndex, controller);
    return controller;
  }

  void _scheduleAdjacentScrollRestore(
    int chapterIndex,
    ScrollController controller, [
    int attempt = 0,
  ]) {
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
          _scheduleAdjacentScrollRestore(chapterIndex, controller, attempt + 1);
        }
        return;
      }

      final maxExtent = controller.position.maxScrollExtent;
      final savedProgress = _currentProgress?.chapterProgress[chapterIndex];
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
    _ignorePlatformFuture(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
      'show status bar',
    );
  }

  void _showLibrarySystemBars() {
    _ignorePlatformFuture(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
      'restore library system bars',
    );
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
      ]);
      savedSettings = results[0] as ReaderSettings;
      savedProgress = results[1] as ReadingProgress?;
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
    _scheduleAdjacentWarmup();
    _requestScrollRestore(
      offset: safeRestoredOffset,
      progress: hasSavedProgressRatio ? safeRestoredProgress : null,
      preferProgress: hasSavedProgressRatio,
    );
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
      final offset = _preferPendingScrollProgress && progress != null
          ? progress * maxExtent
          : requested.clamp(0.0, maxExtent).toDouble();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ignorePlatformFuture(WakelockPlus.disable(), 'disable wakelock');
    _hideStatusBarTimer?.cancel();
    _saveTimer?.cancel();
    _settingsApplyTimer?.cancel();
    if (!_closingReader) unawaited(_saveProgress());
    _discardPageTurnSnapshot();
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

  void _scheduleProgressSave() {
    if (!_settingsLoaded || _closingReader) return;
    if (_pageDragOffset == 0 && !_pageTurnController.isAnimating) {
      _discardPageTurnSnapshot();
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
    return updated;
  }

  _ScrollSnapshot _currentScrollSnapshot() {
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

  Future<void> _capturePageTurnSnapshot() async {
    if (!mounted ||
        _settings.pageTurnMode != ReaderPageTurnMode.book ||
        _pageDragOffset != 0) {
      return;
    }

    final serial = ++_pageTurnSnapshotSerial;
    final expectedChapterIndex = _chapterIndex;
    try {
      var boundary = _currentPageBoundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return;
      if (boundary.debugNeedsPaint) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || serial != _pageTurnSnapshotSerial) return;
        boundary = _currentPageBoundaryKey.currentContext?.findRenderObject();
        if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
          return;
        }
      }

      final pixelRatio = math.min(MediaQuery.devicePixelRatioOf(context), 2.0);
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      if (!mounted ||
          serial != _pageTurnSnapshotSerial ||
          expectedChapterIndex != _chapterIndex ||
          _settings.pageTurnMode != ReaderPageTurnMode.book) {
        image.dispose();
        return;
      }

      final previousImage = _pageTurnSnapshot;
      _pageTurnSnapshot = image;
      previousImage?.dispose();
      if (_pageDragOffset != 0) setState(() {});
    } on Object {
      // Snapshot capture is a visual enhancement. If the render layer is
      // being rebuilt at the same moment, the page still turns normally and
      // the next gesture captures a fresh frame.
    }
  }

  void _discardPageTurnSnapshot() {
    _pageTurnSnapshotSerial++;
    final image = _pageTurnSnapshot;
    _pageTurnSnapshot = null;
    image?.dispose();
  }

  void _resetPageDrag({bool rebuild = true}) {
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
  }

  void _scheduleAdjacentWarmup() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _warmAdjacentPages) return;
      setState(() => _warmAdjacentPages = true);
    });
  }

  void _queueSettingsApply(ReaderSettings newSettings) {
    _pendingSettingsApply = newSettings;
    _settingsApplyTimer?.cancel();
    _settingsApplyTimer = Timer(AppMotion.settingApplyDelay, () {
      if (!mounted) return;
      final pending = _pendingSettingsApply;
      _pendingSettingsApply = null;
      _settingsApplyTimer = null;
      if (pending == null) return;
      final snapshot = _currentScrollSnapshot();
      _discardPageTurnSnapshot();
      if (_currentProgress != null) {
        _currentProgress = _currentProgress!.recordPosition(
          _chapterIndex,
          snapshot.offset,
          progress: snapshot.progress,
        );
      }
      setState(() {
        _settings = pending;
        _pageDragTargetIndex = null;
      });
      _setPageDragOffset(0);
      // Font size, line height, font family, margin and paragraph spacing all
      // change the document's pixel height. Restore the same normalized
      // reading position after reflow instead of retaining a stale pixel or
      // letting the rebuilt list fall back to its top.
      _requestScrollRestore(
        offset: snapshot.offset,
        progress: snapshot.progress,
        preferProgress: true,
      );
    });
  }

  void _openChapter(int index) {
    _switchChapter(index, startAtTop: true);
  }

  void _switchChapter(int index, {required bool startAtTop}) {
    if (index == _chapterIndex || index < 0 || index >= _book.chapters.length) {
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

    final previousController = _scrollController;
    previousController.removeListener(_scheduleProgressSave);
    final nextController = _createScrollController(targetOffset);
    final previousAdjacentControllers = _adjacentScrollControllers.values
        .toSet();
    _adjacentScrollControllers.clear();
    _adjacentScrollRestoreSerials.clear();

    setState(() {
      _chapterIndex = index;
      _scrollController = nextController;
      _warmAdjacentPages = false;
      _pageDragTargetIndex = null;
      _pageTurnAnimation = null;
      _commitPageTurnWhenSettled = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
      for (final controller in previousAdjacentControllers) {
        controller.dispose();
      }
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
  }

  void _toggleOverlay() {
    if (_pageDragOffset != 0) return;
    _discardPageTurnSnapshot();
    final expectedChapter = _chapterIndex;
    final controller = _scrollController;
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
      final maxExtent = controller.position.maxScrollExtent;
      final target = snapshot.offset.clamp(0.0, maxExtent).toDouble();
      if ((controller.offset - target).abs() > 0.5) {
        controller.jumpTo(target);
      }
      _lastScrollSnapshot = _ScrollSnapshot(
        offset: target,
        progress: maxExtent > 0 ? target / maxExtent : 0,
      );
    });
  }

  void _handleReadingPointerDown(PointerDownEvent event) {
    if (_readingTapPointer != null) return;
    _readingTapPointer = event.pointer;
    _readingTapOrigin = event.position;
    _readingTapStartedAt = event.timeStamp;
    _readingTapMoved = false;
    if (_settings.pageTurnMode == ReaderPageTurnMode.book) {
      unawaited(_capturePageTurnSnapshot());
    }
  }

  void _handleReadingPointerMove(PointerMoveEvent event) {
    if (event.pointer != _readingTapPointer || _readingTapMoved) return;
    final origin = _readingTapOrigin;
    if (origin == null) return;
    if ((event.position - origin).distance > _readingTapSlop) {
      _readingTapMoved = true;
    }
  }

  void _handleReadingPointerUp(PointerUpEvent event) {
    if (event.pointer != _readingTapPointer) return;
    final startedAt = _readingTapStartedAt;
    final elapsed = startedAt == null
        ? _readingTapTimeout + const Duration(milliseconds: 1)
        : event.timeStamp - startedAt;
    final shouldToggle = !_readingTapMoved && elapsed <= _readingTapTimeout;
    _clearReadingTap();
    if (shouldToggle) _toggleOverlay();
  }

  void _handleReadingPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _readingTapPointer) _clearReadingTap();
  }

  void _clearReadingTap() {
    _readingTapPointer = null;
    _readingTapOrigin = null;
    _readingTapStartedAt = null;
    _readingTapMoved = false;
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    _pageCurlAnchorY = details.localPosition.dy;
    if (_pageTurnController.isAnimating) {
      final targetIndex = _pageDragTargetIndex;
      final shouldFinish =
          _commitPageTurnWhenSettled &&
          targetIndex != null &&
          _pageDragOffset.abs() > 1;
      _pageTurnSerial++;
      _pageTurnController.stop();
      _pageTurnAnimation = null;
      if (shouldFinish) {
        _finishPageTurn(targetIndex);
        return;
      }
    }
    _pageTurnController.stop();
    _pageTurnAnimation = null;
    if (_settings.pageTurnMode == ReaderPageTurnMode.book &&
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
    if (width <= 0) return;
    _pageCurlAnchorY = details.localPosition.dy;
    final proposed = (_pageDragOffset + details.delta.dx).clamp(-width, width);
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

  void _handleHorizontalDragEnd(DragEndDetails details, double width) {
    final targetIndex = _pageDragTargetIndex;
    if (targetIndex == null || width <= 0) {
      _animatePageDragTo(0, commit: false);
      return;
    }

    final velocity = details.primaryVelocity ?? 0;
    final progress = (_pageDragOffset.abs() / width).clamp(0.0, 1.0);
    final velocityCommits =
        (targetIndex > _chapterIndex && velocity < -260) ||
        (targetIndex < _chapterIndex && velocity > 260);
    final shouldCommit = progress > 0.16 || velocityCommits;
    final endOffset = shouldCommit
        ? (targetIndex > _chapterIndex ? -width : width)
        : 0.0;
    _animatePageDragTo(endOffset, commit: shouldCommit);
  }

  void _handleHorizontalDragCancel() {
    if (_pageDragOffset == 0 && _pageDragTargetIndex == null) return;
    _animatePageDragTo(0, commit: false);
  }

  void _animatePageDragTo(double endOffset, {required bool commit}) {
    final targetIndex = _pageDragTargetIndex;
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
      if (_commitPageTurnWhenSettled && targetIndex != null) {
        _finishPageTurn(targetIndex);
      } else {
        _resetPageDrag();
      }
    });
  }

  void _finishPageTurn(int targetIndex) {
    _switchChapter(targetIndex, startAtTop: false);
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
          onSelect: (index) {
            _openChapter(index);
          },
        ),
      ),
    );
  }

  void _showSettings() {
    var sheetSettings = _settings;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: AnimationStyle(
        duration: AppMotion.sheet,
        reverseDuration: AppMotion.normal,
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final themeColors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );

    if (_book.chapters.isEmpty) {
      return Scaffold(
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

    return PopScope(
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
                  onPointerMove: _handleReadingPointerMove,
                  onPointerUp: _handleReadingPointerUp,
                  onPointerCancel: _handleReadingPointerCancel,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: _handleHorizontalDragStart,
                    onHorizontalDragUpdate: (details) =>
                        _handleHorizontalDragUpdate(details, width),
                    onHorizontalDragEnd: (details) =>
                        _handleHorizontalDragEnd(details, width),
                    onHorizontalDragCancel: _handleHorizontalDragCancel,
                    child: AnimatedContainer(
                      duration: AppMotion.normal,
                      curve: AppMotion.standard,
                      color: themeColors.background,
                      child: ClipRect(
                        child: _buildPageTurnView(
                          width: width,
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
                controller: _scrollController,
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
                              child: Text(
                                _book.title,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: themeColors.text,
                                ),
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
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
  }

  Widget _buildPageTurnView({
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
        if (_settings.pageTurnMode == ReaderPageTurnMode.book) {
          return _buildBookTurnPages(
            width: width,
            dragOffset: offset,
            currentPage: currentPage,
            previousPage: previousPage,
            nextPage: nextPage,
            themeColors: themeColors,
          );
        }

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

  Widget _buildBookTurnPages({
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
    final clipProgress = hasTarget ? progress : 0.0;
    final currentTranslation = hasTarget ? 0.0 : dragOffset * 0.18;

    return Stack(
      children: [
        if (previousPage != null)
          KeyedSubtree(
            key: const ValueKey('previous-page'),
            child: Transform.translate(
              offset: Offset(hasTarget && !goingNext ? 0 : -width, 0),
              child: _inactivePage(previousPage),
            ),
          ),
        if (nextPage != null)
          KeyedSubtree(
            key: const ValueKey('next-page'),
            child: Transform.translate(
              offset: Offset(hasTarget && goingNext ? 0 : width, 0),
              child: _inactivePage(nextPage),
            ),
          ),
        KeyedSubtree(
          key: const ValueKey('current-page'),
          child: Transform.translate(
            offset: Offset(currentTranslation, 0),
            child: ClipPath(
              clipper: _BookPageClipper(
                progress: clipProgress,
                goingNext: goingNext,
                curlAnchorY: _pageCurlAnchorY,
              ),
              child: currentPage,
            ),
          ),
        ),
        if (hasTarget)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _BookCurlPainter(
                  progress: progress,
                  goingNext: goingNext,
                  backgroundColor: themeColors.background,
                  curlAnchorY: _pageCurlAnchorY,
                  pageSnapshot: _pageTurnSnapshot,
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
  }) {
    final paragraphs = _paragraphsFor(chapter);
    final paragraphGap =
        _settings.paragraphSpacing == ReaderParagraphSpacing.blankLine
        ? _settings.fontSize * _settings.lineHeight
        : 0.0;
    final itemCount = paragraphs.length + 2;
    final scrollView = ListView.builder(
      key: ValueKey<String>(
        'chapter-${identityHashCode(chapter)}-${controller != null}',
      ),
      controller: controller,
      primary: false,
      scrollCacheExtent: const ScrollCacheExtent.pixels(900),
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        viewPadding.top + AppSpacing.lg,
        horizontalPadding,
        viewPadding.bottom + 80,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl),
            child: AnimatedDefaultTextStyle(
              duration: AppMotion.normal,
              curve: AppMotion.standard,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: themeColors.text,
                height: 1.5,
              ),
              child: Text(_formatChapterTitle(chapter.title)),
            ),
          );
        }
        if (index == itemCount - 1) {
          return const SizedBox(height: AppSpacing.xxl);
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
              fontWeight: _settings.fontWeight.value,
              height: _settings.lineHeight,
              color: themeColors.text,
              letterSpacing: 0.2,
            ),
            child: Text(paragraphs[paragraphIndex]),
          ),
        );
      },
    );

    return RepaintBoundary(
      key: repaintBoundaryKey,
      child: ColoredBox(
        color: themeColors.background,
        // Keep the reading subtree identical while menus open and close.
        // Reparenting this ListView used to detach its ScrollPosition and
        // recreate it at the controller's initial offset.
        child: _DoubleTapFilteredSelectionArea(child: scrollView),
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

  const _DoubleTapFilteredSelectionArea({required this.child});

  @override
  State<_DoubleTapFilteredSelectionArea> createState() =>
      _DoubleTapFilteredSelectionAreaState();
}

class _DoubleTapFilteredSelectionAreaState
    extends State<_DoubleTapFilteredSelectionArea> {
  static const _tapSlop = 18.0;
  static const _doubleTapSlop = 100.0;
  static const _doubleTapTimeout = Duration(milliseconds: 300);

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
    if (content == null || !_suppressSelection || _clearScheduled) return;
    _clearScheduled = true;
    scheduleMicrotask(() {
      _clearScheduled = false;
      if (!mounted || !_suppressSelection) return;
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    });
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

class _ScrollSnapshot {
  final double offset;
  final double progress;

  const _ScrollSnapshot({required this.offset, required this.progress});
}

class _BookPageClipper extends CustomClipper<Path> {
  final double progress;
  final bool goingNext;
  final double curlAnchorY;

  const _BookPageClipper({
    required this.progress,
    required this.goingNext,
    required this.curlAnchorY,
  });

  @override
  Path getClip(Size size) {
    return _BookCurlGeometry.calculate(
      size: size,
      progress: progress,
      goingNext: goingNext,
      curlAnchorY: curlAnchorY,
    ).frontPath;
  }

  @override
  bool shouldReclip(covariant _BookPageClipper oldClipper) {
    return oldClipper.progress != progress ||
        oldClipper.goingNext != goingNext ||
        oldClipper.curlAnchorY != curlAnchorY;
  }
}

class _BookCurlPainter extends CustomPainter {
  final double progress;
  final bool goingNext;
  final Color backgroundColor;
  final double curlAnchorY;
  final ui.Image? pageSnapshot;

  const _BookCurlPainter({
    required this.progress,
    required this.goingNext,
    required this.backgroundColor,
    required this.curlAnchorY,
    required this.pageSnapshot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final p = progress.clamp(0.0, 1.0).toDouble();
    if (p <= 0) return;
    final curlStrength = math.sin(math.pi * p).clamp(0.0, 1.0);
    final geometry = _BookCurlGeometry.calculate(
      size: size,
      progress: p,
      goingNext: goingNext,
      curlAnchorY: curlAnchorY,
    );

    _paintTargetPageShadow(canvas, size, geometry, curlStrength);
    _paintFrontPageShade(canvas, size, geometry, curlStrength);

    if (curlStrength > 0.001) {
      canvas.drawShadow(
        geometry.backPath,
        Colors.black.withValues(alpha: 0.28 * curlStrength),
        8 + 12 * curlStrength,
        false,
      );
      _paintPaperBack(canvas, size, geometry, curlStrength);
    }
  }

  void _paintTargetPageShadow(
    Canvas canvas,
    Size size,
    _BookCurlGeometry geometry,
    double strength,
  ) {
    if (strength <= 0) return;
    final shadowWidth = (size.width * (0.10 + 0.12 * strength)).clamp(
      24.0,
      120.0,
    );
    final center = geometry.creaseCenter.clamp(0.0, size.width).toDouble();
    final rect = goingNext
        ? Rect.fromLTRB(
            center,
            0,
            (center + shadowWidth).clamp(0.0, size.width).toDouble(),
            size.height,
          )
        : Rect.fromLTRB(
            (center - shadowWidth).clamp(0.0, size.width).toDouble(),
            0,
            center,
            size.height,
          );
    if (rect.width <= 0) return;
    final opacity = 0.26 * math.pow(strength, 0.72).toDouble();
    final gradient = LinearGradient(
      begin: goingNext ? Alignment.centerLeft : Alignment.centerRight,
      end: goingNext ? Alignment.centerRight : Alignment.centerLeft,
      colors: [
        Colors.black.withValues(alpha: opacity),
        Colors.black.withValues(alpha: opacity * 0.36),
        Colors.transparent,
      ],
      stops: const [0.0, 0.36, 1.0],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
  }

  void _paintFrontPageShade(
    Canvas canvas,
    Size size,
    _BookCurlGeometry geometry,
    double strength,
  ) {
    if (strength <= 0) return;
    final center = geometry.creaseCenter.clamp(0.0, size.width).toDouble();
    final shadeWidth = (size.width * 0.10 * strength).clamp(10.0, 54.0);
    final rect = goingNext
        ? Rect.fromLTRB(
            (center - shadeWidth).clamp(0.0, size.width).toDouble(),
            0,
            center,
            size.height,
          )
        : Rect.fromLTRB(
            center,
            0,
            (center + shadeWidth).clamp(0.0, size.width).toDouble(),
            size.height,
          );
    if (rect.width <= 0) return;
    final gradient = LinearGradient(
      begin: goingNext ? Alignment.centerLeft : Alignment.centerRight,
      end: goingNext ? Alignment.centerRight : Alignment.centerLeft,
      colors: [
        Colors.transparent,
        Colors.black.withValues(alpha: 0.11 * strength),
      ],
    );
    canvas
      ..save()
      ..clipPath(geometry.frontPath)
      ..drawRect(rect, Paint()..shader = gradient.createShader(rect))
      ..restore();
  }

  void _paintPaperBack(
    Canvas canvas,
    Size size,
    _BookCurlGeometry geometry,
    double strength,
  ) {
    final bounds = geometry.backPath.getBounds();
    if (bounds.width <= 0.1 || bounds.height <= 0.1) return;

    final paper = Color.lerp(backgroundColor, Colors.white, 0.045)!;
    canvas.drawPath(geometry.backPath, Paint()..color = paper);

    final snapshot = pageSnapshot;
    if (snapshot != null) {
      // Reflect the exact visible reading surface around the crease. This
      // makes the folded sheet show the current title, paragraphs, selected
      // font and theme on its reverse side instead of a generic line pattern.
      final creaseOrigin = Offset(geometry.creaseCenter, size.height / 2);
      canvas
        ..save()
        ..clipPath(geometry.backPath)
        ..translate(creaseOrigin.dx, creaseOrigin.dy)
        ..rotate(geometry.creaseAngle)
        ..scale(1, -1)
        ..rotate(-geometry.creaseAngle)
        ..translate(-creaseOrigin.dx, -creaseOrigin.dy)
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
            ..filterQuality = FilterQuality.medium
            ..color = Colors.white.withValues(alpha: 0.52 + 0.16 * strength),
        )
        ..restore();
    }

    final lightingGradient = LinearGradient(
      begin: goingNext ? Alignment.centerLeft : Alignment.centerRight,
      end: goingNext ? Alignment.centerRight : Alignment.centerLeft,
      colors: [
        Colors.black.withValues(alpha: 0.12 * strength),
        Colors.white.withValues(alpha: 0.16 * strength),
        Colors.transparent,
        Colors.black.withValues(alpha: 0.18 * strength),
      ],
      stops: const [0.0, 0.34, 0.70, 1.0],
    );

    canvas
      ..save()
      ..clipPath(geometry.backPath)
      ..drawRect(
        bounds,
        Paint()..shader = lightingGradient.createShader(bounds),
      )
      ..restore();

    canvas.drawPath(
      geometry.backEdgePath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.16 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.drawPath(
      geometry.creasePath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.30 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15,
    );
    canvas.drawPath(
      geometry.creasePath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.10 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );
  }

  @override
  bool shouldRepaint(covariant _BookCurlPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.goingNext != goingNext ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.curlAnchorY != curlAnchorY ||
        oldDelegate.pageSnapshot != pageSnapshot;
  }
}

class _BookCurlGeometry {
  final Path frontPath;
  final Path backPath;
  final Path creasePath;
  final Path backEdgePath;
  final double creaseCenter;
  final double creaseAngle;

  const _BookCurlGeometry({
    required this.frontPath,
    required this.backPath,
    required this.creasePath,
    required this.backEdgePath,
    required this.creaseCenter,
    required this.creaseAngle,
  });

  factory _BookCurlGeometry.calculate({
    required Size size,
    required double progress,
    required bool goingNext,
    required double curlAnchorY,
  }) {
    final width = size.width;
    final height = size.height;
    final p = progress.clamp(0.0, 1.0).toDouble();
    final strength = math.sin(math.pi * p).clamp(0.0, 1.0);
    final direction = goingNext ? 1.0 : -1.0;
    final creaseBase = goingNext ? width * (1 - p) : width * p;
    final normalizedAnchor = height > 0 && curlAnchorY.isFinite
        ? (curlAnchorY / height).clamp(0.08, 0.92).toDouble()
        : 0.62;
    final tilt = width * 0.105 * (normalizedAnchor - 0.5) * strength;
    final curveDepth = width * 0.055 * strength;

    double clampX(double value) => value.clamp(0.0, width).toDouble();

    final creaseTop = clampX(creaseBase - tilt);
    final creaseBottom = clampX(creaseBase + tilt);
    final creaseControlTop = clampX(
      creaseBase + direction * (curveDepth + tilt * 0.18),
    );
    final creaseControlBottom = clampX(
      creaseBase + direction * (curveDepth - tilt * 0.18),
    );

    final frontPath = Path();
    if (goingNext) {
      frontPath
        ..moveTo(0, 0)
        ..lineTo(creaseTop, 0)
        ..cubicTo(
          creaseControlTop,
          height * 0.30,
          creaseControlBottom,
          height * 0.70,
          creaseBottom,
          height,
        )
        ..lineTo(0, height)
        ..close();
    } else {
      frontPath
        ..moveTo(creaseTop, 0)
        ..lineTo(width, 0)
        ..lineTo(width, height)
        ..lineTo(creaseBottom, height)
        ..cubicTo(
          creaseControlBottom,
          height * 0.70,
          creaseControlTop,
          height * 0.30,
          creaseTop,
          0,
        )
        ..close();
    }

    final backWidth = width * 0.40 * math.pow(strength, 0.82).toDouble();
    final backTop = clampX(creaseTop - direction * backWidth * 0.88);
    final backBottom = clampX(creaseBottom - direction * backWidth);
    final backBase = creaseBase - direction * backWidth * 0.94;
    final backCurveDepth = curveDepth * 0.30;
    final backControlTop = clampX(
      backBase + direction * (backCurveDepth - tilt * 0.10),
    );
    final backControlBottom = clampX(
      backBase + direction * (backCurveDepth + tilt * 0.10),
    );

    final creasePath = Path()
      ..moveTo(creaseTop, 0)
      ..cubicTo(
        creaseControlTop,
        height * 0.30,
        creaseControlBottom,
        height * 0.70,
        creaseBottom,
        height,
      );
    final backEdgePath = Path()
      ..moveTo(backTop, 0)
      ..cubicTo(
        backControlTop,
        height * 0.30,
        backControlBottom,
        height * 0.70,
        backBottom,
        height,
      );
    final backPath = Path()
      ..moveTo(creaseTop, 0)
      ..cubicTo(
        creaseControlTop,
        height * 0.30,
        creaseControlBottom,
        height * 0.70,
        creaseBottom,
        height,
      )
      ..lineTo(backBottom, height)
      ..cubicTo(
        backControlBottom,
        height * 0.70,
        backControlTop,
        height * 0.30,
        backTop,
        0,
      )
      ..close();

    return _BookCurlGeometry(
      frontPath: frontPath,
      backPath: backPath,
      creasePath: creasePath,
      backEdgePath: backEdgePath,
      creaseCenter: (creaseTop + creaseBottom) / 2,
      creaseAngle: math.atan2(height, creaseBottom - creaseTop),
    );
  }
}
