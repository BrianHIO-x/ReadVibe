import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../controllers/library_maintenance_controller.dart';
import '../controllers/library_selection_controller.dart';
import '../controllers/library_update_controller.dart';
import '../controllers/private_shelf_controller.dart';
import '../models/book.dart';
import '../models/library_filter.dart';
import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';
import '../services/android_book_picker.dart';
import '../services/book_export_service.dart';
import '../services/book_import_coordinator.dart';
import '../services/book_import_format.dart';
import '../services/chinese_text.dart';
import '../services/font_service.dart';
import '../services/incoming_file_service.dart';
import '../services/library_backup_service.dart';
import '../services/private_shelf_lock.dart';
import '../services/storage_service.dart';
import '../services/update_service.dart';
import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_sheet.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_card.dart';
import '../widgets/global_settings_sheet.dart';
import '../widgets/library_backup_sheet.dart';
import '../widgets/library_batch_bar.dart';
import '../widgets/library_group_bar.dart';
import '../widgets/library_reorder_grid.dart';
import '../widgets/library_search_controls.dart';
import '../widgets/side_drawer.dart';
import 'pdf_reader_screen.dart';
import 'reader_screen.dart';

/// Library / bookshelf screen
class LibraryScreen extends StatefulWidget {
  final LibraryRepository? repository;
  final UpdateChecker? updateChecker;
  final BookExporter? exporter;
  final PrivateShelfLock? privateShelfLock;

  const LibraryScreen({
    super.key,
    this.repository,
    this.updateChecker,
    this.exporter,
    this.privateShelfLock,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

enum _BookAction {
  rename,
  groups,
  multiSelect,
  move,
  togglePrivate,
  delete,
  exportFile,
}

const _importStallLimit = Duration(seconds: 100);
const _importSilentStepLimit = Duration(minutes: 12);
const _incomingImportQueueLimit = Duration(minutes: 10);

class _LibraryScreenState extends State<LibraryScreen>
    with TickerProviderStateMixin {
  late final LibraryRepository _storage;
  late final FontService _fontService;
  late final BookImportCoordinator _bookImporter;
  late final BookExporter _bookExporter;
  late final LibraryBackupService _backupService;
  late final LibraryMaintenanceController _maintenance;
  late final LibraryUpdateController _updateController;
  late final PrivateShelfController _privateShelf;
  final _selection = LibrarySelectionController();

  List<Book> _books = [];
  Map<String, ReadingProgress> _progressMap = {};
  Map<String, BookAvailability> _availabilityMap = {};
  List<String> _shelfGroups = const <String>[];
  String? _selectedGroup;
  ReaderSettings _settings = const ReaderSettings();

  bool _loading = true;
  bool _importing = false;
  BookImportProgress? _importProgress;
  int _importBatchIndex = 0;
  int _importBatchTotal = 0;
  bool _exporting = false;
  bool _openingBook = false;
  bool _settingsOpen = false;
  int _loadSerial = 0;

  final _librarySearchController = TextEditingController();
  final _librarySearchFocus = FocusNode();
  bool _librarySearchVisible = false;
  ShelfFilter _shelfFilter = ShelfFilter.all;

  late final AnimationController _gridEntranceController;
  late final AnimationController _emptyIconController;
  bool? _floatedEmptyShelf;

  final _gridScrollController = ScrollController();
  final _reorderScrollController = ScrollController();
  bool _reorderShelfFits = false;
  bool _gridScrolled = false;
  Offset? _shelfPointerStart;
  DateTime? _shelfPointerStartTime;
  bool _reorderMode = false;
  String? _reorderFocusBookId;
  Timer? _reorderFocusTimer;
  String? _draggingBookId;
  bool _bookOrderChanged = false;
  String? _lastReorderTargetId;
  DateTime? _lastReorderTargetAt;

  @override
  void initState() {
    super.initState();
    _storage = widget.repository ?? StorageService();
    _fontService = FontService(_storage);
    _bookImporter = BookImportCoordinator(_storage);
    _bookExporter = widget.exporter ?? BookExportService();
    final checker = widget.updateChecker ?? UpdateService();
    _backupService = LibraryBackupService(
      _storage is StorageService ? _storage : StorageService(),
      readAppVersion: checker.currentVersion,
    );
    _updateController = LibraryUpdateController(
      updateChecker: checker,
      contextProvider: () => context,
      isMounted: () => mounted,
      isAutomaticEnabled: () => _settings.automaticUpdateChecks,
      canPromptAutomaticUpdate: () =>
          (ModalRoute.of(context)?.isCurrent == true || _settingsOpen) &&
          !_openingBook &&
          !_importing,
      colorsProvider: () => _feedbackColors,
      onMessage: _showMessage,
      onError: _showError,
      onVersionUpdated: () {
        if (mounted) setState(() {});
      },
    );
    _privateShelf = PrivateShelfController(
      lock: widget.privateShelfLock ?? PrivateShelfLock(),
      storage: _storage,
      contextProvider: () => context,
      isMounted: () => mounted,
      isOpeningBook: () => _openingBook,
      allBooksProvider: () => _books,
      colorsProvider: () => _feedbackColors,
      onPrivateModeChanged: _handlePrivateModeChanged,
      onConfigChanged: () {
        if (mounted) setState(() {});
      },
      onReloadLibrary: _loadData,
      onMessage: _showMessage,
      onError: _showError,
      onAppResume: _updateController.syncAutomaticUpdateCheck,
    );
    _maintenance = LibraryMaintenanceController(
      repository: _storage,
      books: () => _books,
      canRun: () =>
          mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          !_importing &&
          !_exporting &&
          !_openingBook &&
          !_settingsOpen &&
          !_reorderMode,
      onAvailability: (values) {
        if (mounted) setState(() => _availabilityMap.addAll(values));
      },
      onError: (error, stack) {
        debugPrint('Storage maintenance failed: $error');
        debugPrintStack(stackTrace: stack);
      },
    );
    _gridEntranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _emptyIconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _gridScrollController.addListener(_handleGridScroll);
    _selection.addListener(_handleSelectionChanged);
    unawaited(_updateController.loadApplicationVersion());
    unawaited(_privateShelf.loadConfig());
    _loadData();
    unawaited(
      IncomingFileService.start(_importIncomingBook, onError: _showError),
    );
  }

  void _handleSelectionChanged() {
    if (_selection.isSelecting) {
      _librarySearchFocus.unfocus();
    }
    if (mounted) setState(() {});
  }

  void _handlePrivateModeChanged(bool private) {
    _selection.exit();
    _librarySearchController.clear();
    _librarySearchFocus.unfocus();
    _reorderFocusTimer?.cancel();
    setState(() {
      _shelfFilter = ShelfFilter.all;
      _selectedGroup = null;
      _librarySearchVisible = false;
      _reorderMode = false;
      _reorderFocusBookId = null;
      _draggingBookId = null;
    });
    _rewindShelfScroll(_gridScrollController);
    _gridEntranceController.reset();
    _syncShelfAnimations();
    unawaited(_reloadShelfGroups());
  }

  ReaderThemeColors get _feedbackColors => AppTheme.getReaderTheme(
    _settings.theme,
    systemBrightness: MediaQuery.platformBrightnessOf(context),
  );

  void _handleGridScroll() {
    var scrolled = false;
    for (final position in List<ScrollPosition>.of(
      _gridScrollController.positions,
    )) {
      if (position.hasPixels && position.pixels > 4) {
        scrolled = true;
        break;
      }
    }
    if (scrolled != _gridScrolled) {
      setState(() => _gridScrolled = scrolled);
    }
  }

  @override
  void dispose() {
    _loadSerial++;
    _updateController.dispose();
    _privateShelf.dispose();
    _maintenance.dispose();
    _selection.removeListener(_handleSelectionChanged);
    _selection.dispose();
    _reorderFocusTimer?.cancel();
    _librarySearchController.dispose();
    _librarySearchFocus.dispose();
    IncomingFileService.stop();
    _gridScrollController.removeListener(_handleGridScroll);
    _gridScrollController.dispose();
    _reorderScrollController.dispose();
    _gridEntranceController.dispose();
    _emptyIconController.dispose();
    super.dispose();
  }

  bool get _privateMode => _privateShelf.isOpen;

  List<Book> get _shelfBooks => _books
      .where((book) => book.isPrivate == _privateMode)
      .toList(growable: false);

  List<Book> get _visibleBooks {
    final query = foldFullWidth(
      _librarySearchController.text,
    ).trim().toLowerCase();
    final filtered = _shelfBooks
        .where((book) {
          if (_selectedGroup != null && !book.groups.contains(_selectedGroup)) {
            return false;
          }
          final matchesQuery =
              query.isEmpty ||
              foldFullWidth(book.title).toLowerCase().contains(query) ||
              foldFullWidth(book.author).toLowerCase().contains(query) ||
              book.format.name.toLowerCase().contains(query);
          if (!matchesQuery) return false;
          return switch (_shelfFilter) {
            ShelfFilter.all => true,
            ShelfFilter.recent => _progressMap.containsKey(book.id),
            ShelfFilter.unread => !_progressMap.containsKey(book.id),
            ShelfFilter.txt => book.format == BookFormat.txt,
            ShelfFilter.epub => book.format == BookFormat.epub,
            ShelfFilter.kindle =>
              book.format == BookFormat.mobi ||
                  book.format == BookFormat.azw ||
                  book.format == BookFormat.azw3,
            ShelfFilter.word =>
              book.format == BookFormat.doc || book.format == BookFormat.docx,
            ShelfFilter.pdf => book.format == BookFormat.pdf,
          };
        })
        .toList(growable: false);
    if (_shelfFilter == ShelfFilter.recent) {
      filtered.sort((first, second) {
        final firstDate = _progressMap[first.id]?.lastReadDate;
        final secondDate = _progressMap[second.id]?.lastReadDate;
        if (firstDate == null && secondDate == null) return 0;
        if (firstDate == null) return 1;
        if (secondDate == null) return -1;
        return secondDate.compareTo(firstDate);
      });
    }
    return filtered;
  }

  bool get _hasShelfQueryOrFilter =>
      _librarySearchController.text.trim().isNotEmpty ||
      _shelfFilter != ShelfFilter.all;

  bool get _hasAnyShelfConstraint =>
      _hasShelfQueryOrFilter || _selectedGroup != null;

  void _clearShelfQueryAndFilter() {
    _librarySearchController.clear();
    setState(() {
      _shelfFilter = ShelfFilter.all;
      _selectedGroup = null;
      _librarySearchVisible = false;
    });
  }

  Future<void> _reloadShelfGroups() async {
    final private = _privateMode;
    try {
      final groups = await _storage.getShelfGroups(private: private);
      if (!mounted || _privateMode != private) return;
      setState(() {
        _shelfGroups = groups;
        if (_selectedGroup != null && !groups.contains(_selectedGroup)) {
          _selectedGroup = null;
        }
      });
    } on Object {
      // Keep existing group chips on transient read failure.
    }
  }

  Future<void> _loadData() async {
    final serial = ++_loadSerial;
    final private = _privateMode;
    try {
      final results = await Future.wait<Object>([
        _storage.getBookSummaries(),
        _storage.getSettings(),
        _storage.getShelfGroups(private: private),
      ]);
      final books = results[0] as List<Book>;
      final storedSettings = results[1] as ReaderSettings;
      final groups = results[2] as List<String>;
      final settings = await _fontService.ensureImportedFontLoaded(
        storedSettings,
      );
      if (settings.fontFamily != storedSettings.fontFamily) {
        _persistSettings(settings);
      }
      final shelfState = await Future.wait<Object>([
        Future.wait(books.map(_storage.getShelfProgress)),
        Future.wait(books.map(_storage.checkBookAvailability)),
      ]);
      final progressValues = shelfState[0] as List<ReadingProgress?>;
      final availabilityValues = shelfState[1] as List<BookAvailability>;
      final pMap = <String, ReadingProgress>{};
      final availabilityMap = <String, BookAvailability>{};
      for (var i = 0; i < books.length; i++) {
        final progress = progressValues[i];
        if (progress != null) pMap[books[i].id] = progress;
        availabilityMap[books[i].id] = availabilityValues[i];
      }
      if (mounted && serial == _loadSerial) {
        setState(() {
          _books = books;
          _progressMap = pMap;
          _availabilityMap = availabilityMap;
          if (_privateMode == private) {
            _shelfGroups = groups;
            if (_selectedGroup != null && !groups.contains(_selectedGroup)) {
              _selectedGroup = null;
            }
          }
          _settings = settings;
          _loading = false;
        });
        _selection.retainValid(<String>{
          for (final book in _shelfBooks) book.id,
        });
        _syncShelfAnimations();
        _updateController.syncAutomaticUpdateCheck();
        _maintenance.schedule();
      }
    } catch (e) {
      debugPrint('Failed to load library: $e');
      if (mounted && serial == _loadSerial) {
        setState(() => _loading = false);
        _showError('书架加载失败，请重新打开应用后重试');
      }
    }
  }

  void _syncShelfAnimations() {
    if (_shelfBooks.isNotEmpty) {
      _emptyIconController.stop();
      _floatedEmptyShelf = null;
      if (_gridEntranceController.status == AnimationStatus.dismissed) {
        _gridEntranceController.forward();
      }
    } else {
      _gridEntranceController.reset();
      _floatEmptyIcon();
    }
  }

  void _floatEmptyIcon() {
    if (_floatedEmptyShelf == _privateMode) return;
    _floatedEmptyShelf = _privateMode;
    if (MediaQuery.disableAnimationsOf(context)) {
      _emptyIconController.value = 0;
      return;
    }
    unawaited(
      _emptyIconController.repeat(reverse: true, count: 4).then((_) {
        if (mounted) _emptyIconController.value = 0;
      }),
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

  Future<void> _importBook() async {
    if (_importing || _exporting) return;
    final private = _privateMode;
    final pickedPaths = <String>[];
    var startedImport = false;
    try {
      final batch = await _privateShelf.runWithSystemDialog(
        AndroidBookPicker.pickBooks,
      );
      if (batch == null || !mounted) return;
      for (final file in batch.files) {
        if (file.deleteAfterImport) pickedPaths.add(file.path);
      }
      if (batch.files.isEmpty) {
        if (batch.errors.isNotEmpty) {
          _showError(batch.errors.first);
        }
        return;
      }

      startedImport = true;
      setState(() {
        _importing = true;
        _importProgress = null;
        _importBatchIndex = 0;
        _importBatchTotal = batch.files.length;
      });
      var importedCount = 0;
      final errors = <String>[...batch.errors];
      for (var i = 0; i < batch.files.length; i++) {
        if (!mounted) break;
        setState(() {
          _importBatchIndex = i + 1;
          _importProgress = null;
        });
        final file = batch.files[i];
        try {
          await _importBookPath(file.path, file.name, private: private);
          importedCount++;
        } on Object catch (error) {
          errors.add(
            error is FormatException && error.message.trim().isNotEmpty
                ? '「${file.name}」${error.message}'
                : '「${file.name}」导入失败',
          );
        }
      }
      if (mounted) {
        if (errors.isNotEmpty && importedCount == 0) {
          _showError(errors.first);
        } else if (errors.isNotEmpty) {
          _showMessage('已导入 $importedCount 本，${errors.length} 个文件失败：${errors.first}');
        } else if (batch.files.length > 1 && importedCount > 1) {
          _showMessage('已导入 $importedCount 本书');
        }
      }
    } on FormatException catch (error) {
      if (mounted) {
        _showError(
          error.message.trim().isNotEmpty ? error.message : '导入失败，请确认文件未损坏后重试',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) _showError(describeFilePickerFailure(error));
    } on FileSystemException {
      if (mounted) _showError('无法读取所选文件');
    } finally {
      for (final materializedPath in pickedPaths) {
        try {
          final temporary = File(materializedPath);
          if (await temporary.exists()) await temporary.delete();
        } on FileSystemException {
          // Picker cache cleanup is best-effort.
        }
      }
      if (startedImport && mounted) {
        setState(() {
          _importing = false;
          _importProgress = null;
          _importBatchIndex = 0;
          _importBatchTotal = 0;
        });
      }
    }
  }

  Future<void> _importIncomingBook(IncomingBookFile file) async {
    final waitUntil = DateTime.now().add(_incomingImportQueueLimit);
    while (mounted && (_importing || _loading || _exporting)) {
      if (DateTime.now().isAfter(waitUntil)) {
        if (mounted) _showError('书架正忙，未能导入「${file.name}」，请稍后重试');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
    if (!mounted) return;
    setState(() {
      _importing = true;
      _importProgress = null;
      _importBatchIndex = 1;
      _importBatchTotal = 1;
    });
    try {
      await _importBookPath(file.path, file.name, private: _privateMode);
    } finally {
      try {
        final temporary = File(file.path);
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Native cache maintenance retries stale external-file copies later.
      }
      if (mounted) {
        setState(() {
          _importing = false;
          _importProgress = null;
          _importBatchIndex = 0;
          _importBatchTotal = 0;
        });
      }
    }
  }

  Future<void> _importBookPath(
    String path,
    String fileName, {
    bool private = false,
  }) async {
    var active = true;
    try {
      final importedBook = await _withoutStalling<Book?>(
        (beat) async {
          final book = await _bookImporter.importFile(
            path: path,
            fileName: fileName,
            requestPdfPassword: () async {
              if (!active || !mounted) return null;
              beat(const Duration(days: 1));
              try {
                return await _requestPdfPassword(fileName);
              } finally {
                beat(_importSilentStepLimit);
              }
            },
            isCancelled: () => !active || !mounted,
            isPrivate: private,
            onProgress: (progress) {
              beat(_stepLimit(progress.stage));
              if (active && mounted && _importing) {
                setState(() => _importProgress = progress);
              }
            },
          );
          beat(_importStallLimit);
          if (book != null && mounted) await _loadData();
          return book;
        },
        _importSilentStepLimit,
        onStalled: () => active = false,
      );
      if (importedBook == null) return;
      if (_importBatchTotal <= 1) {
        _showMessage(
          private
              ? '「${importedBook.title}」已导入隐私书架'
              : '「${importedBook.title}」已导入书架',
        );
      }
    } catch (error, stack) {
      if (error is! FormatException) {
        debugPrint('Book import failed for $fileName: $error');
        debugPrintStack(stackTrace: stack);
      }
      final message = error is FormatException && error.message.trim().isNotEmpty
          ? error.message
          : '导入失败于「${_importProgress?.label ?? '读取文件'}」，请确认文件未损坏后重试';
      if (_importBatchTotal > 1) {
        throw FormatException(message);
      }
      _showError(message);
    } finally {
      active = false;
    }
  }

  Future<T> _withoutStalling<T>(
    Future<T> Function(void Function(Duration within) beat) body,
    Duration firstStep, {
    VoidCallback? onStalled,
  }) {
    final result = Completer<T>();
    Timer? watchdog;
    void beat(Duration within) {
      if (result.isCompleted) return;
      watchdog?.cancel();
      watchdog = Timer(within, () {
        if (result.isCompleted) return;
        onStalled?.call();
        final step = _importProgress?.label ?? '读取文件';
        result.completeError(
          FormatException('「$step」长时间没有响应，已停止等待。请重试，或换一个文件'),
        );
      });
    }

    beat(firstStep);
    body(beat)
        .then(
          (value) {
            if (!result.isCompleted) result.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            if (!result.isCompleted) result.completeError(error, stack);
          },
        )
        .whenComplete(() => watchdog?.cancel());
    return result.future;
  }

  Duration _stepLimit(BookImportStage stage) => switch (stage) {
    BookImportStage.saving => _importStallLimit,
    BookImportStage.inspecting ||
    BookImportStage.parsing => _importSilentStepLimit,
  };

  String _importLabel({required bool compact}) {
    final progress = _importProgress;
    if (_importBatchTotal > 1 && _importBatchIndex > 0) {
      final batchTag = '$_importBatchIndex/$_importBatchTotal';
      if (compact) return '导入 $batchTag';
      final fraction = progress?.fraction;
      if (fraction == null) return '正在导入 $batchTag...';
      return '${progress!.label} ($batchTag) ${(fraction * 100).round()}%';
    }
    if (progress == null) return '导入中...';
    final fraction = progress.fraction;
    if (fraction == null) return compact ? '导入中...' : '${progress.label}...';
    final percent = (fraction * 100).round();
    return compact ? '导入 $percent%' : '${progress.label} $percent%';
  }

  Future<String?> _requestPdfPassword(String fileName) async {
    if (!mounted) return null;
    final controller = TextEditingController();
    var obscure = true;
    final password = await showAppDialog<String>(
      context: context,
      colors: _feedbackColors,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AppDialog(
          title: const Text('输入 PDF 密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '「$fileName」受密码保护，请输入解锁密码：',
                style: TextStyle(fontSize: 13, color: _feedbackColors.secondary),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                obscureText: obscure,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: '密码',
                  suffixIcon: IconButton(
                    tooltip: obscure ? '显示密码' : '隐藏密码',
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                ),
                onSubmitted: (_) {
                  if (controller.text.isNotEmpty) {
                    Navigator.pop(dialogContext, controller.text);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: controller.text.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, controller.text),
              child: const Text('解锁并导入'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return password;
  }

  void _showError(String message) {
    if (!mounted) return;
    AppToast.error(context, message, colors: _feedbackColors);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    AppToast.success(context, message, colors: _feedbackColors);
  }

  void _handleShelfPointerDown(PointerDownEvent event) {
    if (_reorderMode || _selection.isSelecting) return;
    _shelfPointerStart = event.position;
    _shelfPointerStartTime = DateTime.now();
  }

  void _handleShelfPointerCancel(PointerCancelEvent event) {
    _shelfPointerStart = null;
    _shelfPointerStartTime = null;
  }

  void _handleShelfPointerUp(PointerUpEvent event) {
    if (_reorderMode || _selection.isSelecting) {
      _shelfPointerStart = null;
      _shelfPointerStartTime = null;
      return;
    }
    final start = _shelfPointerStart;
    final startTime = _shelfPointerStartTime;
    _shelfPointerStart = null;
    _shelfPointerStartTime = null;
    if (start == null || startTime == null) return;

    final delta = event.position - start;
    final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
    final mostlyHorizontal = delta.dx.abs() > delta.dy.abs() * 1.6;
    final intentionalRightSwipe =
        delta.dx > 96 && mostlyHorizontal && elapsedMs < 900;
    if (intentionalRightSwipe) {
      _showGlobalSettings();
    }
  }

  void _enterReorderMode(String bookId) {
    _selection.exit();
    _reorderFocusTimer?.cancel();
    setState(() {
      _reorderMode = true;
      _reorderFocusBookId = bookId;
      _draggingBookId = null;
      _bookOrderChanged = false;
    });
    unawaited(HapticFeedback.mediumImpact());
    _reorderFocusTimer = Timer(const Duration(milliseconds: 560), () {
      if (!mounted || _reorderFocusBookId != bookId) return;
      setState(() => _reorderFocusBookId = null);
    });
  }

  void _exitReorderMode() {
    if (!_reorderMode || _draggingBookId != null) return;
    _reorderFocusTimer?.cancel();
    setState(() {
      _reorderMode = false;
      _reorderFocusBookId = null;
      _lastReorderTargetId = null;
      _lastReorderTargetAt = null;
    });
    unawaited(HapticFeedback.lightImpact());
  }

  void _startBookDrag(Book book) {
    _shelfPointerStart = null;
    _shelfPointerStartTime = null;
    _reorderFocusTimer?.cancel();
    setState(() {
      _draggingBookId = book.id;
      _reorderFocusBookId = null;
      _bookOrderChanged = false;
      _lastReorderTargetId = null;
      _lastReorderTargetAt = null;
    });
    unawaited(HapticFeedback.mediumImpact());
  }

  void _updateBookDrag(DragUpdateDetails details) {
    if (_reorderShelfFits || !_reorderScrollController.hasClients) return;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final y = details.globalPosition.dy;
    var delta = 0.0;
    if (y < 150) {
      delta = -10;
    } else if (y > screenHeight - 90) {
      delta = 10;
    }
    if (delta == 0) return;
    final position = _reorderScrollController.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() > 0.1) {
      _reorderScrollController.jumpTo(target);
    }
  }

  void _moveDraggedBook(String targetBookId) {
    final sourceBookId = _draggingBookId;
    if (sourceBookId == null || sourceBookId == targetBookId) return;
    final now = DateTime.now();
    if (_lastReorderTargetId == targetBookId &&
        _lastReorderTargetAt != null &&
        now.difference(_lastReorderTargetAt!).inMilliseconds < 90) {
      return;
    }
    final sourceIndex = _books.indexWhere((book) => book.id == sourceBookId);
    final targetIndex = _books.indexWhere((book) => book.id == targetBookId);
    if (sourceIndex < 0 || targetIndex < 0 || sourceIndex == targetIndex) {
      return;
    }

    setState(() {
      final moved = _books.removeAt(sourceIndex);
      _books.insert(targetIndex, moved);
      _bookOrderChanged = true;
      _lastReorderTargetId = targetBookId;
      _lastReorderTargetAt = now;
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _finishBookDrag(Book book) {
    final shouldPersistOrder = _bookOrderChanged;
    setState(() {
      _draggingBookId = null;
      _bookOrderChanged = false;
      _reorderFocusBookId = book.id;
      _lastReorderTargetId = null;
      _lastReorderTargetAt = null;
    });
    if (shouldPersistOrder) {
      unawaited(_persistBookOrder());
    }
    _reorderFocusTimer?.cancel();
    _reorderFocusTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted || _reorderFocusBookId != book.id) return;
      setState(() => _reorderFocusBookId = null);
    });
  }

  Future<void> _persistBookOrder() async {
    try {
      await _storage.saveBookOrder(_books.map((book) => book.id).toList());
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to save shelf order: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showError('书架顺序保存失败，已恢复上次顺序');
      await _loadData();
    }
  }

  void _showGlobalSettings() {
    if (_settingsOpen) return;
    _settingsOpen = true;
    var sheetSettings = _settings;
    final dialog = showSideDrawer<void>(
      context: context,
      barrierLabel: '关闭设置',
      barrierColor: Colors.black.withValues(alpha: 0.14),
      builder: (_) => Material(
        color: Colors.transparent,
        child: StatefulBuilder(
          builder: (context, setSheetState) {
            final colors = AppTheme.getReaderTheme(
              sheetSettings.theme,
              systemBrightness: MediaQuery.platformBrightnessOf(context),
            );
            return AppOverlayTheme(
              colors: colors,
              child: GlobalSettingsSheet(
                settings: sheetSettings,
                colors: colors,
                onChange: (newSettings) {
                  setSheetState(() => sheetSettings = newSettings);
                  if (mounted) setState(() => _settings = newSettings);
                  _updateController.syncAutomaticUpdateCheck();
                  _persistSettings(newSettings);
                },
                onImportFont: () async {
                  try {
                    final picked = await _privateShelf.runWithSystemDialog(
                      () => _fontService.pickAndInstallFont(sheetSettings),
                    );
                    if (picked == null) return;
                    if (!context.mounted || !mounted) return;
                    setSheetState(() => sheetSettings = picked);
                    if (mounted) setState(() => _settings = picked);
                    await _storage.saveSettings(picked);
                    _showMessage('字体已导入并应用');
                  } catch (e) {
                    _showError(
                      e is FormatException
                          ? e.message
                          : '字体导入失败，请选择 .ttf 或 .otf 文件',
                    );
                  }
                },
                onCheckUpdate: () async {
                  Navigator.of(context).pop();
                  await _updateController.checkUpdateManually();
                },
                onMeasureStorage: _storage.measureStorageUsage,
                onClearCaches: _storage.clearTemporaryCaches,
                applicationVersion: _updateController.applicationVersion,
                privateShelfConfigured: _privateShelf.configured,
                privateShelfOpen: _privateMode,
                onPrivateShelf: () {
                  Navigator.of(context).pop();
                  unawaited(_privateShelf.handlePrivateShelfEntry());
                },
                onPrivateShelfSettings: () {
                  Navigator.of(context).pop();
                  unawaited(_privateShelf.managePrivateShelf());
                },
                onOpenBackup: () {
                  Navigator.of(context).pop();
                  unawaited(_openBackupSheet());
                },
              ),
            );
          },
        ),
      ),
    );
    unawaited(dialog.whenComplete(() => _settingsOpen = false));
  }

  Future<void> _openBackupSheet() {
    return showLibraryBackupSheet(
      context,
      backupService: _backupService,
      privateShelf: _privateShelf,
      colors: _feedbackColors,
      onRestored: _loadData,
    );
  }

  Future<void> _openGroupManager() {
    return showShelfGroupManagerSheet(
      context,
      storage: _storage,
      colors: _feedbackColors,
      private: _privateMode,
      onChanged: _loadData,
    );
  }

  List<Book> get _selectedBooks {
    final ids = _selection.selectedIds;
    return <Book>[
      for (final book in _shelfBooks)
        if (ids.contains(book.id)) book,
    ];
  }

  Future<void> _assignGroups(List<Book> targets) async {
    if (targets.isEmpty) return;
    final saved = await showAssignBookGroupsSheet(
      context,
      storage: _storage,
      colors: _feedbackColors,
      private: _privateMode,
      targets: targets,
      onApplied: _loadData,
    );
    if (saved && mounted) {
      _showMessage(targets.length > 1 ? '已更新选中书籍的分组' : '分组设置已保存');
    }
  }

  Future<void> _moveBooksToShelf(
    List<Book> books, {
    required bool private,
  }) async {
    if (books.isEmpty) return;
    if (private &&
        !_privateShelf.configured &&
        !await _privateShelf.ensureConfigured()) {
      return;
    }
    try {
      await _storage.setBooksPrivate(
        books.map((book) => book.id),
        private: private,
      );
      if (!mounted) return;
      _selection.exit();
      await _loadData();
      if (!mounted) return;
      if (books.length == 1) {
        final book = books.first;
        _showMessage(
          private ? '「${book.title}」已移入隐私书架' : '「${book.title}」已移回普通书架',
        );
      } else {
        _showMessage(
          private
              ? '已将 ${books.length} 本书移入隐私书架'
              : '已将 ${books.length} 本书移回普通书架',
        );
      }
    } on Object catch (error, stack) {
      debugPrint('Failed to move books between shelves: $error');
      debugPrintStack(stackTrace: stack);
      _showError('移动失败，请稍后重试');
    }
  }

  Future<void> _confirmDeleteBooks(List<Book> books) async {
    if (books.isEmpty) return;
    final singleTitle = books.length == 1 ? books.first.title : null;
    final confirmed = await showAppDialog<bool>(
      context: context,
      colors: _feedbackColors,
      builder: (dialogContext) => AppDialog(
        title: const Text('删除书籍'),
        content: Text(
          singleTitle != null
              ? '确定要删除「$singleTitle」吗？'
              : '确定要删除选中的 ${books.length} 本书吗？删除后无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          AppDestructiveButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _storage.deleteBooks(books.map((book) => book.id));
      _selection.exit();
      await _loadData();
      if (mounted && books.length > 1) {
        _showMessage('已删除 ${books.length} 本书');
      }
    } on Object {
      _showError('删除失败，请稍后重试');
    }
  }

  Future<void> _showBookActions(Book book) async {
    if (_exporting) return;
    _librarySearchFocus.unfocus();
    final colors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final action = await showAppSheet<_BookAction>(
      context: context,
      colors: colors,
      builder: (sheetContext) => AppActionSheet(
        colors: colors,
        title: book.title,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('修改信息'),
            subtitle: const Text('修改书名和作者'),
            onTap: () => Navigator.pop(sheetContext, _BookAction.rename),
          ),
          ListTile(
            leading: const Icon(Icons.label_outline_rounded),
            title: const Text('设置分组'),
            subtitle: Text(
              book.groups.isEmpty
                  ? '归类到自定义分组，便于筛选'
                  : '当前分组：${book.groups.join('、')}',
            ),
            onTap: () => Navigator.pop(sheetContext, _BookAction.groups),
          ),
          ListTile(
            leading: const Icon(Icons.checklist_rounded),
            title: const Text('多选管理'),
            subtitle: const Text('批量分组、移入隐私或删除'),
            onTap: () => Navigator.pop(sheetContext, _BookAction.multiSelect),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt_rounded),
            title: const Text('导出文件'),
            subtitle: Text(
              book.isPdf ? '导出当前 PDF 副本' : '导出 UTF-8 TXT，包含已保存的编辑内容',
            ),
            onTap: () => Navigator.pop(sheetContext, _BookAction.exportFile),
          ),
          ListTile(
            leading: const Icon(Icons.open_with_rounded),
            title: const Text('移动'),
            onTap: () => Navigator.pop(sheetContext, _BookAction.move),
          ),
          ListTile(
            leading: Icon(
              book.isPrivate
                  ? Icons.lock_open_rounded
                  : Icons.lock_outline_rounded,
            ),
            title: Text(book.isPrivate ? '移回普通书架' : '移入隐私书架'),
            subtitle: Text(book.isPrivate ? '移回后在普通书架显示' : '移入后只在隐私书架显示'),
            onTap: () => Navigator.pop(sheetContext, _BookAction.togglePrivate),
          ),
          ListTile(
            leading: Icon(
              Icons.delete_outline_rounded,
              color: AppOverlayTheme.danger(colors),
            ),
            title: Text(
              '删除',
              style: TextStyle(color: AppOverlayTheme.danger(colors)),
            ),
            onTap: () => Navigator.pop(sheetContext, _BookAction.delete),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _BookAction.exportFile:
        await _exportBook(book);
      case _BookAction.rename:
        await _renameBook(book);
      case _BookAction.groups:
        await _assignGroups(<Book>[book]);
      case _BookAction.multiSelect:
        _selection.enter(book.id);
      case _BookAction.move:
        _enterReorderMode(book.id);
      case _BookAction.togglePrivate:
        await _moveBooksToShelf(<Book>[book], private: !book.isPrivate);
      case _BookAction.delete:
        await _confirmDeleteBooks(<Book>[book]);
    }
  }

  Future<void> _exportBook(Book summary) async {
    if (_exporting || _importing || _openingBook) return;
    setState(() => _exporting = true);
    AppToast.loading(context, '正在准备导出文件…', colors: _feedbackColors);
    try {
      final book = await _storage.getBook(summary.id);
      if (!mounted) return;
      if (book == null) throw const FormatException('书籍已不存在或正文无法读取');
      final saved = await _privateShelf.runWithSystemDialog(
        () => _bookExporter.exportBook(book),
      );
      if (!mounted) return;
      AppToast.hide(context);
      _showMessage(saved ? '「${book.title}」已导出' : '已取消导出');
    } on Object catch (error, stackTrace) {
      debugPrint('Book export failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        AppToast.hide(context);
        _showError(
          error is FormatException
              ? error.message.toString()
              : error is PlatformException && error.message != null
              ? error.message!
              : '导出失败，请检查存储空间与保存位置',
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _renameBook(Book book) async {
    final titleController = TextEditingController(text: book.title);
    final authorController = TextEditingController(text: book.author);
    final formKey = GlobalKey<FormState>();
    final colors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final edited = await showAppDialog<({String title, String author})>(
      context: context,
      colors: _feedbackColors,
      builder: (dialogContext) => AppDialog(
        title: const Text('修改书籍信息'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: titleController,
                autofocus: true,
                maxLength: 120,
                maxLines: 2,
                textInputAction: TextInputAction.next,
                style: TextStyle(color: colors.text),
                decoration: InputDecoration(
                  labelText: '书名',
                  hintText: '请输入书籍名称',
                  hintStyle: TextStyle(color: colors.secondary),
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '书籍名称不能为空' : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: authorController,
                maxLength: 120,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                style: TextStyle(color: colors.text),
                decoration: InputDecoration(
                  labelText: '作者（可留空）',
                  hintText: 'TXT 无元数据时可在这里补充',
                  hintStyle: TextStyle(color: colors.secondary),
                ),
                onFieldSubmitted: (_) {
                  if (formKey.currentState?.validate() == true) {
                    Navigator.pop(dialogContext, (
                      title: titleController.text.trim(),
                      author: authorController.text.trim(),
                    ));
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('取消', style: TextStyle(color: colors.secondary)),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() == true) {
                Navigator.pop(dialogContext, (
                  title: titleController.text.trim(),
                  author: authorController.text.trim(),
                ));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    titleController.dispose();
    authorController.dispose();
    if (!mounted || edited == null) return;
    if (edited.title == book.title && edited.author == book.author) return;
    try {
      await _storage.updateBookDetails(
        book.id,
        title: edited.title,
        author: edited.author,
      );
      if (!mounted) return;
      final index = _books.indexWhere((item) => item.id == book.id);
      if (index >= 0) {
        setState(
          () => _books[index] = _books[index].copyWith(
            title: edited.title,
            author: edited.author,
          ),
        );
      }
      _showMessage('书籍信息已修改');
    } on Object catch (error) {
      _showError(error is FormatException ? error.message : '修改名称失败，请稍后重试');
    }
  }

  Rect? _rectForKey(GlobalKey key) {
    final cardContext = key.currentContext;
    final renderObject = cardContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Future<void> _openBook(
    Book book, {
    Rect? sourceRect,
    ui.Image? coverImage,
  }) async {
    var readableBook = book;
    try {
      if (readableBook.chapters.isEmpty) {
        final loaded = await _storage.getBook(readableBook.id);
        if (loaded == null) {
          _showError('这本书的正文数据为空或已损坏，请删除后重新导入');
          return;
        }
        readableBook = loaded;
      }
      if (!mounted) return;

      if (readableBook.isPdf) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PdfReaderScreen(book: readableBook),
          ),
        );
        return;
      }
      final transitionColors = ValueNotifier<ReaderThemeColors>(
        AppTheme.getReaderTheme(
          _settings.theme,
          systemBrightness: MediaQuery.platformBrightnessOf(context),
        ),
      );
      void syncReaderSettings(ReaderSettings settings) {
        if (!mounted) return;
        final needsShelfRebuild =
            _settings.theme != settings.theme ||
            _settings.effectiveFontFamily != settings.effectiveFontFamily;
        final colors = AppTheme.getReaderTheme(
          settings.theme,
          systemBrightness: MediaQuery.platformBrightnessOf(context),
        );
        if (!identical(transitionColors.value, colors)) {
          transitionColors.value = colors;
        }
        if (needsShelfRebuild) {
          setState(() => _settings = settings);
        } else {
          _settings = settings;
        }
      }

      try {
        final readerRoute = buildFadeScaleRoute<void>(
          (_) => ReaderScreen(
            book: readableBook,
            transitionColors: transitionColors,
            onSettingsChanged: syncReaderSettings,
          ),
          sourceRect: sourceRect,
          coverImage: coverImage,
          transitionColors: transitionColors,
        );
        await Navigator.of(context).push(readerRoute);
        await readerRoute.completed;
      } catch (error, stackTrace) {
        debugPrint('Book opening animation failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        if (!mounted) return;
        final fallbackRoute = MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(
            book: readableBook,
            transitionColors: transitionColors,
            onSettingsChanged: syncReaderSettings,
          ),
        );
        await Navigator.of(context).push(fallbackRoute);
        await fallbackRoute.completed;
      } finally {
        transitionColors.dispose();
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to load book content: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showError('无法读取书籍正文，请稍后重试');
    } finally {
      coverImage?.dispose();
      if (mounted) await _loadData();
    }
  }

  Future<void> _showUnavailableBookDialog(
    Book book,
    BookAvailability availability,
  ) async {
    final delete = await showAppDialog<bool>(
      context: context,
      colors: _feedbackColors,
      builder: (dialogContext) => AppDialog(
        title: Text(availability.label),
        content: Text(
          availability == BookAvailability.sourceMissing
              ? '「${book.title}」的 PDF 私有源文件已经丢失，无法继续阅读。'
              : '「${book.title}」的章节载荷缺失或写入不完整，无法继续阅读。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('保留'),
          ),
          AppDestructiveButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('从书架删除'),
          ),
        ],
      ),
    );
    if (delete != true) return;
    await _storage.deleteBook(book.id);
    if (mounted) await _loadData();
  }

  Future<void> _openBookFromCover(Book book, GlobalKey coverKey) async {
    if (_openingBook || _exporting) return;
    final availability =
        _availabilityMap[book.id] ?? BookAvailability.available;
    if (availability.blocksOpening) {
      await _showUnavailableBookDialog(book, availability);
      return;
    }
    if (availability == BookAvailability.resourceMissing) {
      _showError('这本 EPUB 的图片资源已丢失，正文仍可继续阅读');
    }
    _openingBook = true;
    try {
      final sourceRect = _rectForKey(coverKey);
      ui.Image? coverImage;
      try {
        final repaintBoundary = coverKey.currentContext?.findRenderObject();
        if (repaintBoundary is RenderRepaintBoundary) {
          coverImage = await repaintBoundary.toImage(
            pixelRatio: math.min(View.of(context).devicePixelRatio, 2.0),
          );
        }
      } on Object {
        // Snapshot is a visual enhancement; failure shouldn't block opening.
      }
      if (!mounted) {
        coverImage?.dispose();
        return;
      }
      await _openBook(book, sourceRect: sourceRect, coverImage: coverImage);
    } finally {
      _openingBook = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final selectedBooks = _selectedBooks;
    final content = DefaultTextStyle.merge(
      style: TextStyle(fontFamily: _settings.effectiveFontFamily),
      child: Scaffold(
        backgroundColor: colors.background,
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handleShelfPointerDown,
          onPointerUp: _handleShelfPointerUp,
          onPointerCancel: _handleShelfPointerCancel,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: AppMotion.normal,
                  curve: AppMotion.standard,
                  decoration: BoxDecoration(
                    color: colors.background,
                    boxShadow: _gridScrolled
                        ? [
                            BoxShadow(
                              color: colors.text.withValues(alpha: 0.06),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : const [],
                  ),
                  child: _buildLibraryHeader(colors),
                ),
                Expanded(child: _buildShelfContent(colors)),
                if (_selection.isSelecting)
                  LibraryBatchBar(
                    colors: colors,
                    selectedCount: selectedBooks.length,
                    privateMode: _privateMode,
                    onAssignGroups: () => _assignGroups(selectedBooks),
                    onTogglePrivate: () => _moveBooksToShelf(
                      selectedBooks,
                      private: !_privateMode,
                    ),
                    onDelete: () => _confirmDeleteBooks(selectedBooks),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return PopScope<void>(
      canPop: !_reorderMode && !_selection.isSelecting && !_privateMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_reorderMode) {
          _exitReorderMode();
        } else if (_selection.isSelecting) {
          _selection.exit();
        } else if (_privateMode) {
          _privateShelf.setPrivateMode(false);
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemUiOverlayStyle(colors),
        child: content,
      ),
    );
  }

  Widget _buildLibraryHeader(ReaderThemeColors colors) {
    final selecting = _selection.isSelecting;
    final visibleIds = <String>[for (final book in _visibleBooks) book.id];
    final allSelected = _selection.isAllSelected(visibleIds);

    return Padding(
      padding: _reorderMode
          ? const EdgeInsets.fromLTRB(12, 2, 12, 2)
          : const EdgeInsets.fromLTRB(16, AppSpacing.lg, 16, AppSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _reorderMode
                    ? _exitReorderMode
                    : selecting
                    ? _selection.exit
                    : _showGlobalSettings,
                tooltip: _reorderMode
                    ? '退出移动'
                    : selecting
                    ? '退出多选'
                    : '设置',
                icon: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  switchInCurve: AppMotion.standard,
                  switchOutCurve: AppMotion.exitOf(AppMotion.standard),
                  child: Icon(
                    (_reorderMode || selecting)
                        ? Icons.close_rounded
                        : Icons.menu,
                    key: ValueKey('$_reorderMode-$selecting'),
                    color: colors.secondary,
                  ),
                ),
              ),
              SizedBox(width: selecting ? AppSpacing.xs : AppSpacing.sm),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  switchInCurve: AppMotion.standard,
                  switchOutCurve: AppMotion.exitOf(AppMotion.standard),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...previous, ?current],
                  ),
                  transitionBuilder: (child, animation) => SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.18),
                      end: Offset.zero,
                    ).animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Text(
                    _reorderMode
                        ? '调整顺序'
                        : selecting
                        ? '已选 ${_selection.count} 本'
                        : _privateMode
                        ? '隐私书架'
                        : '书架',
                    key: ValueKey(
                      '$_reorderMode-$selecting-${_selection.count}-$_privateMode',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: selecting ? 16 : (_reorderMode ? 20 : 24),
                      fontWeight: selecting ? FontWeight.w600 : FontWeight.w700,
                      color: colors.text,
                      letterSpacing: selecting ? 0 : -0.3,
                    ),
                  ),
                ),
              ),
              if (!_reorderMode && !selecting) ...[
                IconButton(
                  tooltip: '搜索书架',
                  onPressed: () {
                    setState(
                      () => _librarySearchVisible = !_librarySearchVisible,
                    );
                    if (_librarySearchVisible) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _librarySearchVisible) {
                          _librarySearchFocus.requestFocus();
                        }
                      });
                    } else {
                      _librarySearchFocus.unfocus();
                    }
                  },
                  icon: Icon(
                    _librarySearchVisible
                        ? Icons.search_off_rounded
                        : Icons.search_rounded,
                    color: colors.secondary,
                  ),
                ),
                if (_shelfBooks.isNotEmpty)
                  IconButton(
                    tooltip: '多选管理',
                    onPressed: _selection.enter,
                    icon: Icon(
                      Icons.checklist_rounded,
                      color: colors.secondary,
                    ),
                  ),
                LibraryFilterButton(
                  filter: _shelfFilter,
                  colors: colors,
                  onSelected: (value) => setState(() => _shelfFilter = value),
                ),
              ],
              if (selecting) ...[
                TextButton(
                  onPressed: visibleIds.isEmpty
                      ? null
                      : () => _selection.selectAll(visibleIds),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                    ),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
                const SizedBox(width: AppSpacing.xs),
                TextButton(
                  onPressed: _selection.exit,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                    ),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('完成'),
                ),
              ] else
                AnimatedSwitcher(
                  duration: AppMotion.fast,
                  switchInCurve: AppMotion.standard,
                  switchOutCurve: AppMotion.exitOf(AppMotion.standard),
                  child: _reorderMode
                      ? FilledButton.icon(
                          key: const ValueKey('reorder-done'),
                          onPressed: _draggingBookId == null
                              ? _exitReorderMode
                              : null,
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: const Text('完成'),
                          style: FilledButton.styleFrom(
                            backgroundColor: colors.accent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                              vertical: 6,
                            ),
                          ),
                        )
                      : ElevatedButton.icon(
                          key: const ValueKey('import-book'),
                          onPressed: _importing || _exporting
                              ? null
                              : _importBook,
                          icon: Icon(
                            _importing ? Icons.hourglass_empty : Icons.add,
                            size: 18,
                          ),
                          label: Text(
                            _importing ? _importLabel(compact: true) : '导入',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colors.accent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.pill),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                              vertical: AppSpacing.sm,
                            ),
                          ),
                        ),
                ),
            ],
          ),
          AnimatedSize(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            child: _reorderMode
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      0,
                      AppSpacing.sm,
                      2,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.touch_app_rounded,
                          size: 14,
                          color: colors.secondary,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          '拖动书籍调整位置',
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          AnimatedSize(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            child: _privateMode && !_reorderMode && !selecting
                ? Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 14,
                          color: colors.accent,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            '离开应用以后，隐私书架会自动锁上',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _privateShelf.setPrivateMode(false),
                          icon: const Icon(Icons.lock_rounded, size: 16),
                          label: const Text('锁上'),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.accent,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          AnimatedSize(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            child:
                !_reorderMode &&
                    !selecting &&
                    (_librarySearchVisible || _hasShelfQueryOrFilter)
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.sm,
                      AppSpacing.sm,
                      0,
                    ),
                    child: LibrarySearchControls(
                      controller: _librarySearchController,
                      focusNode: _librarySearchFocus,
                      filter: _shelfFilter,
                      colors: colors,
                      onChanged: () => setState(() {}),
                      onClearFilter: () =>
                          setState(() => _shelfFilter = ShelfFilter.all),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          AnimatedSize(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            child:
                !_reorderMode &&
                    !selecting &&
                    (_shelfBooks.isNotEmpty || _shelfGroups.isNotEmpty)
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: LibraryGroupBar(
                      colors: colors,
                      groups: _shelfGroups,
                      selectedGroup: _selectedGroup,
                      onSelected: (group) =>
                          setState(() => _selectedGroup = group),
                      onManageGroups: _openGroupManager,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ReaderThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _emptyIconController,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(_emptyIconController.value);
              return Transform.translate(
                offset: Offset(0, t * -6),
                child: child,
              );
            },
            child: Icon(
              Icons.menu_book_outlined,
              size: 64,
              color: colors.secondary.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            _privateMode ? '隐私书架还没有书籍' : '还没有书籍',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              _privateMode
                  ? '长按普通书架里的书籍可以移动到这里，也可以直接导入新书'
                  : '点击下方按钮，导入 TXT、EPUB、MOBI/AZW、PDF 或 Word 文档',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: colors.secondary),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          ElevatedButton.icon(
            onPressed: _importing ? null : _importBook,
            icon: Icon(
              _importing ? Icons.hourglass_empty : Icons.add,
              size: 18,
            ),
            label: Text(_importing ? _importLabel(compact: false) : '导入书籍'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl,
                vertical: AppSpacing.md,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoShelfResults(ReaderThemeColors colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 48, color: colors.secondary),
            const SizedBox(height: AppSpacing.md),
            Text(
              '没有符合条件的书籍',
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton(
              onPressed: _hasAnyShelfConstraint
                  ? _clearShelfQueryAndFilter
                  : null,
              child: const Text('清除搜索和筛选'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShelfContent(ReaderThemeColors colors) {
    if (_loading) {
      return const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_shelfBooks.isEmpty) {
      return KeyedSubtree(
        key: ValueKey('empty-$_privateMode'),
        child: _buildEmptyState(colors),
      );
    }
    if (!_reorderMode && _visibleBooks.isEmpty) {
      return KeyedSubtree(
        key: const ValueKey('no-shelf-results'),
        child: _buildNoShelfResults(colors),
      );
    }
    return KeyedSubtree(
      key: const ValueKey('library-grid'),
      child: _buildBookGrid(colors),
    );
  }

  Widget _buildBookGrid(ReaderThemeColors colors) {
    if (_reorderMode) {
      return LibraryReorderGrid(
        books: _shelfBooks,
        progressMap: _progressMap,
        availabilityMap: _availabilityMap,
        colors: colors,
        scrollController: _reorderScrollController,
        openingBook: _openingBook,
        reorderFocusBookId: _reorderFocusBookId,
        onBooksFitChanged: (fits) => _reorderShelfFits = fits,
        onPinOffsetWhenFits: _pinShelfOffsetWhenItFits,
        onMoveDraggedBook: _moveDraggedBook,
        onDragStarted: _startBookDrag,
        onDragUpdate: _updateBookDrag,
        onDragEnd: _finishBookDrag,
      );
    }
    final books = _visibleBooks;
    final selecting = _selection.isSelecting;

    return LayoutBuilder(
      builder: (context, constraints) {
        final booksFit = _shelfBooksFitViewport(
          screenWidth: MediaQuery.sizeOf(context).width,
          viewportWidth: constraints.maxWidth,
          viewportHeight: constraints.maxHeight,
          bookCount: books.length,
          topPadding: AppSpacing.md,
          horizontalPadding: AppSpacing.md,
          gestureInset: selecting ? 0 : MediaQuery.paddingOf(context).bottom,
          paintedHeight: (cellWidth) =>
              BookCard.paintedHeight(context, cellWidth),
        );
        _pinShelfOffsetWhenItFits(_gridScrollController, booksFit);
        return RefreshIndicator(
          onRefresh: _loadData,
          color: colors.accent,
          child: NotificationListener<OverscrollIndicatorNotification>(
            onNotification: (notification) {
              if (booksFit) notification.disallowIndicator();
              return false;
            },
            child: GridView.builder(
              controller: _gridScrollController,
              physics: booksFit ? const PinnedShelfScrollPhysics() : null,
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                booksFit
                    ? 0
                    : AppSpacing.md +
                          (selecting
                              ? AppSpacing.md
                              : MediaQuery.paddingOf(context).bottom),
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: computeShelfGridMetrics(
                  MediaQuery.sizeOf(context).width,
                ).columns,
                childAspectRatio: 0.52,
                crossAxisSpacing: AppSpacing.xs,
                mainAxisSpacing: AppSpacing.sm,
              ),
              itemCount: books.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final index = books.indexWhere((book) => book.id == key.value);
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                final book = books[index];
                final cardKey = GlobalObjectKey('book-card-${book.id}');
                final coverKey = GlobalObjectKey(
                  'book-cover-source-${book.id}',
                );
                final card = RepaintBoundary(
                  key: cardKey,
                  child: BookCard(
                    book: book,
                    progress: _progressMap[book.id],
                    availability:
                        _availabilityMap[book.id] ?? BookAvailability.available,
                    colors: colors,
                    coverKey: coverKey,
                    selectionMode: selecting,
                    selected: selecting && _selection.isSelected(book.id),
                    onTap: selecting
                        ? () => _selection.toggle(book.id)
                        : () => _openBookFromCover(book, coverKey),
                    onLongPress: selecting
                        ? () => _selection.toggle(book.id)
                        : () => _showBookActions(book),
                  ),
                );

                final staggerIndex = math.min(index, 11);
                final start = (staggerIndex * 0.04).clamp(0.0, 0.6);
                final interval = Interval(
                  start,
                  (start + 0.4).clamp(0.0, 1.0),
                  curve: AppMotion.standard,
                );
                return AnimatedBuilder(
                  key: ValueKey<String>(book.id),
                  animation: _gridEntranceController,
                  builder: (context, child) {
                    final value = interval.transform(
                      _gridEntranceController.value,
                    );
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, (1 - value) * 16),
                        child: child,
                      ),
                    );
                  },
                  child: card,
                );
              },
            ),
          ),
        );
      },
    );
  }

  static bool _shelfBooksFitViewport({
    required double screenWidth,
    required double viewportWidth,
    required double viewportHeight,
    required int bookCount,
    required double topPadding,
    required double horizontalPadding,
    required double gestureInset,
    required double Function(double cellWidth) paintedHeight,
  }) {
    if (bookCount <= 0) return true;
    if (!viewportWidth.isFinite || !viewportHeight.isFinite) return false;
    final columns = computeShelfGridMetrics(screenWidth).columns;
    final innerWidth = math.max(0.0, viewportWidth - horizontalPadding * 2);
    final cardWidth = columns <= 1
        ? innerWidth
        : math.max(0.0, (innerWidth - AppSpacing.xs * (columns - 1)) / columns);
    final cardHeight = cardWidth / 0.52;
    final rows = (bookCount / columns).ceil();
    final lastRowHeight = math.min(cardHeight, paintedHeight(cardWidth));
    final contentHeight =
        (rows - 1) * (cardHeight + AppSpacing.sm) + lastRowHeight;
    final visibleHeight = math.max(0.0, viewportHeight - gestureInset);
    return topPadding + contentHeight <= visibleHeight + 0.5;
  }

  void _rewindShelfScroll(ScrollController controller) {
    if (!controller.hasClients) return;
    for (final position in List<ScrollPosition>.of(controller.positions)) {
      if (!position.hasPixels ||
          !position.hasContentDimensions ||
          position.pixels == 0) {
        continue;
      }
      position.jumpTo(0);
    }
  }

  void _pinShelfOffsetWhenItFits(ScrollController controller, bool booksFit) {
    if (!booksFit || !controller.hasClients) return;
    var parked = false;
    for (final position in List<ScrollPosition>.of(controller.positions)) {
      if (position.hasPixels && position.pixels != 0) {
        parked = true;
        break;
      }
    }
    if (!parked) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rewindShelfScroll(controller);
    });
  }
}
