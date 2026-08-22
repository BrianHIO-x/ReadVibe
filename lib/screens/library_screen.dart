import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../services/font_service.dart';
import '../services/storage_service.dart';
import '../services/txt_parser.dart';
import '../services/epub_parser.dart';
import '../services/pdf_import_service.dart';
import '../services/pdf_renderer_service.dart';
import '../services/book_search_service.dart';
import '../services/word_parser.dart';
import '../services/update_service.dart';
import '../services/incoming_file_service.dart';
import '../services/mobi_parser.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_update_dialog.dart';
import '../widgets/book_card.dart';
import '../widgets/global_settings_sheet.dart';
import 'reader_screen.dart';
import 'pdf_reader_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Library / bookshelf screen
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

enum _BookAction { rename, move, delete }

enum _ShelfFilter { all, recent, unread, txt, epub, kindle, word, pdf }

extension _ShelfFilterInfo on _ShelfFilter {
  String get label => switch (this) {
    _ShelfFilter.all => '全部',
    _ShelfFilter.recent => '最近阅读',
    _ShelfFilter.unread => '未读',
    _ShelfFilter.txt => 'TXT',
    _ShelfFilter.epub => 'EPUB',
    _ShelfFilter.kindle => 'MOBI/AZW',
    _ShelfFilter.word => 'Word',
    _ShelfFilter.pdf => 'PDF',
  };
}

Offset _centerDragAnchorStrategy(
  Draggable<Object> draggable,
  BuildContext context,
  Offset position,
) {
  final renderBox = context.findRenderObject()! as RenderBox;
  return renderBox.size.center(Offset.zero);
}

class _LibraryScreenState extends State<LibraryScreen>
    with TickerProviderStateMixin {
  final _storage = StorageService();
  late final _fontService = FontService(_storage);
  List<Book> _books = [];
  Map<String, ReadingProgress> _progressMap = {};
  Map<String, BookAvailability> _availabilityMap = {};
  ReaderSettings _settings = const ReaderSettings();
  bool _loading = true;
  bool _importing = false;
  bool _openingBook = false;
  bool _settingsOpen = false;
  int _loadSerial = 0;
  Timer? _automaticUpdateTimer;
  Timer? _storageMaintenanceTimer;
  bool _automaticUpdateAttempted = false;
  bool _storageMaintenanceScheduled = false;
  final _librarySearchController = TextEditingController();
  bool _librarySearchVisible = false;
  _ShelfFilter _shelfFilter = _ShelfFilter.all;

  late final AnimationController _gridEntranceController;
  late final AnimationController _emptyIconController;

  final _gridScrollController = ScrollController();
  final _reorderScrollController = ScrollController();
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
    _gridEntranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _emptyIconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _gridScrollController.addListener(_handleGridScroll);
    _loadData();
    unawaited(
      IncomingFileService.start(_importIncomingBook, onError: _showError),
    );
  }

  /// Silent GitHub release check once the shelf has settled. A dismissed
  /// version stays quiet for three days so offline reading is never nagged.
  void _syncAutomaticUpdateCheck() {
    if (!_settings.automaticUpdateChecks) {
      _automaticUpdateTimer?.cancel();
      _automaticUpdateTimer = null;
      return;
    }
    if (_automaticUpdateAttempted || _automaticUpdateTimer != null) return;
    _automaticUpdateTimer = Timer(const Duration(seconds: 2), () async {
      _automaticUpdateTimer = null;
      _automaticUpdateAttempted = true;
      if (!mounted) return;
      final result = await UpdateService().checkForUpdate();
      final info = result.info;
      if (!mounted || !_settings.automaticUpdateChecks || info == null) return;
      final prefs = await SharedPreferences.getInstance();
      final dismissedKey = 'update_dismissed_${info.version}';
      final dismissedAt = prefs.getInt(dismissedKey) ?? 0;
      final quietDays = DateTime.now().millisecondsSinceEpoch - dismissedAt;
      if (quietDays < const Duration(days: 3).inMilliseconds) return;
      if (!mounted) return;
      await _showUpdateDialog(info);
      unawaited(
        prefs.setInt(dismissedKey, DateTime.now().millisecondsSinceEpoch),
      );
    });
  }

  void _scheduleStorageMaintenance() {
    if (_storageMaintenanceScheduled) return;
    _storageMaintenanceScheduled = true;
    _storageMaintenanceTimer = Timer(const Duration(seconds: 30), () async {
      _storageMaintenanceTimer = null;
      try {
        await BookSearchService.removeObsoleteData(_storage);
        final result = await _storage.collectOrphanedData();
        if (result.removedEntries > 0) {
          debugPrint(
            'Storage maintenance removed ${result.removedFiles} files and '
            '${result.removedDirectories} directories.',
          );
        }
        final snapshot = List<Book>.from(_books);
        final deepAvailability = <String, BookAvailability>{};
        for (final book in snapshot) {
          if (!mounted) return;
          deepAvailability[book.id] = await _storage.checkBookAvailability(
            book,
            deep: true,
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        if (mounted) {
          setState(() {
            for (final entry in deepAvailability.entries) {
              if (_books.any((book) => book.id == entry.key)) {
                _availabilityMap[entry.key] = entry.value;
              }
            }
          });
        }
      } on Object catch (error, stackTrace) {
        debugPrint('Storage maintenance failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    });
  }

  /// Manual check from the global settings sheet. Reports every outcome —
  /// new version, up to date, or unreachable — and ignores the three-day
  /// dismiss window because the user explicitly asked.
  Future<void> _checkUpdateManually() async {
    AppToast.loading(context, '正在检查更新…');
    final result = await UpdateService().checkForUpdate();
    if (!mounted) return;
    AppToast.hide(context);
    final info = result.info;
    if (info != null) {
      await _showUpdateDialog(info);
      return;
    }
    if (result.failed) {
      _showError('检查更新失败，请检查网络后重试');
      return;
    }
    _showMessage('当前已是最新版本');
  }

  Future<void> _showUpdateDialog(AppUpdateInfo info) {
    final colors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '取消',
      barrierColor: Colors.black54,
      transitionDuration: AppMotion.normal,
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return AppUpdateDialog(info: info, colors: colors);
      },
    );
  }

  void _handleGridScroll() {
    final scrolled =
        _gridScrollController.hasClients && _gridScrollController.offset > 4;
    if (scrolled != _gridScrolled) {
      setState(() => _gridScrolled = scrolled);
    }
  }

  @override
  void dispose() {
    _loadSerial++;
    _automaticUpdateTimer?.cancel();
    _storageMaintenanceTimer?.cancel();
    _reorderFocusTimer?.cancel();
    _librarySearchController.dispose();
    IncomingFileService.stop();
    _gridScrollController.removeListener(_handleGridScroll);
    _gridScrollController.dispose();
    _reorderScrollController.dispose();
    _gridEntranceController.dispose();
    _emptyIconController.dispose();
    super.dispose();
  }

  List<Book> get _visibleBooks {
    final query = _librarySearchController.text.trim().toLowerCase();
    final filtered = _books
        .where((book) {
          final matchesQuery =
              query.isEmpty ||
              book.title.toLowerCase().contains(query) ||
              book.author.toLowerCase().contains(query) ||
              book.format.name.toLowerCase().contains(query);
          if (!matchesQuery) return false;
          return switch (_shelfFilter) {
            _ShelfFilter.all => true,
            _ShelfFilter.recent => _progressMap.containsKey(book.id),
            _ShelfFilter.unread => !_progressMap.containsKey(book.id),
            _ShelfFilter.txt => book.format == BookFormat.txt,
            _ShelfFilter.epub => book.format == BookFormat.epub,
            _ShelfFilter.kindle =>
              book.format == BookFormat.mobi ||
                  book.format == BookFormat.azw ||
                  book.format == BookFormat.azw3,
            _ShelfFilter.word =>
              book.format == BookFormat.doc || book.format == BookFormat.docx,
            _ShelfFilter.pdf => book.format == BookFormat.pdf,
          };
        })
        .toList(growable: false);
    if (_shelfFilter == _ShelfFilter.recent) {
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
      _shelfFilter != _ShelfFilter.all;

  void _clearShelfQueryAndFilter() {
    _librarySearchController.clear();
    setState(() {
      _shelfFilter = _ShelfFilter.all;
      _librarySearchVisible = false;
    });
  }

  Future<void> _loadData() async {
    final serial = ++_loadSerial;
    try {
      final results = await Future.wait<Object>([
        _storage.getBookSummaries(),
        _storage.getSettings(),
      ]);
      final books = results[0] as List<Book>;
      final storedSettings = results[1] as ReaderSettings;
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
          _settings = settings;
          _loading = false;
        });
        if (books.isNotEmpty) {
          _emptyIconController.stop();
          if (_gridEntranceController.status == AnimationStatus.dismissed) {
            _gridEntranceController.forward();
          }
        } else {
          _gridEntranceController.reset();
          if (!_emptyIconController.isAnimating) {
            _emptyIconController.repeat(reverse: true);
          }
        }
        _syncAutomaticUpdateCheck();
        _scheduleStorageMaintenance();
      }
    } catch (e) {
      debugPrint('Failed to load library: $e');
      if (mounted && serial == _loadSerial) {
        setState(() => _loading = false);
        _showError('书架加载失败，请重新打开应用后重试');
      }
    }
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
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'txt',
          'epub',
          'mobi',
          'azw',
          'azw3',
          'docx',
          'doc',
          'pdf',
        ],
      );

      if (result == null || result.files.isEmpty || !mounted) return;

      final file = result.files.first;
      final path = file.path;
      if (path == null) {
        _showError('无法获取文件路径');
        return;
      }

      await _importBookPath(path, file.name);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importIncomingBook(IncomingBookFile file) async {
    while (mounted && (_importing || _loading)) {
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
    if (!mounted) return;
    setState(() => _importing = true);
    try {
      await _importBookPath(file.path, file.name);
    } finally {
      try {
        final temporary = File(file.path);
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Native cache maintenance retries stale external-file copies later.
      }
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importBookPath(String path, String fileName) async {
    Book? importedBook;
    var metadataSaved = false;
    try {
      final ext = fileName.toLowerCase();
      if (ext.endsWith('.epub')) {
        importedBook = await parseEpub(path, fileName, _storage);
      } else if (ext.endsWith('.pdf')) {
        try {
          importedBook = await importPdf(path, fileName, _storage);
        } on PdfPasswordRequiredException {
          final password = await _requestPdfPassword(fileName);
          if (password == null) return;
          try {
            importedBook = await importPdf(
              path,
              fileName,
              _storage,
              password: password,
            );
          } on PdfPasswordRequiredException {
            throw const FormatException('PDF 密码不正确');
          }
        }
      } else if (ext.endsWith('.txt')) {
        importedBook = await parseTxt(path, fileName);
      } else if (ext.endsWith('.mobi') ||
          ext.endsWith('.azw') ||
          ext.endsWith('.azw3')) {
        importedBook = await parseKindleBook(path, fileName);
      } else if (ext.endsWith('.docx') || ext.endsWith('.doc')) {
        importedBook = await parseWordDocument(path, fileName, _storage);
      } else {
        throw const FormatException(
          '不支持的文件格式，请选择 TXT、EPUB、MOBI、AZW、AZW3、PDF、DOCX 或 DOC',
        );
      }
      await _storage.saveBook(importedBook);
      metadataSaved = true;
      await _loadData();
      _showMessage('「${importedBook.title}」已导入书架');
    } catch (error) {
      if (!metadataSaved && importedBook != null) {
        try {
          await _storage.discardImportedBook(importedBook);
        } on Object catch (cleanupError, cleanupStack) {
          debugPrint('Failed to clean an interrupted import: $cleanupError');
          debugPrintStack(stackTrace: cleanupStack);
        }
      }
      _showError(
        error is FormatException && error.message.trim().isNotEmpty
            ? error.message
            : '导入失败，请确认文件未损坏后重试',
      );
    }
  }

  Future<String?> _requestPdfPassword(String fileName) async {
    if (!mounted) return null;
    final controller = TextEditingController();
    var obscure = true;
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('PDF 需要密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscure,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  labelText: '打开密码',
                  suffixIcon: IconButton(
                    tooltip: obscure ? '显示密码' : '隐藏密码',
                    onPressed: () => setDialogState(() => obscure = !obscure),
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                onSubmitted: (value) {
                  if (value.isNotEmpty) Navigator.pop(dialogContext, value);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                '密码只在本次导入时使用。应用会在本地保存一个已解锁副本，不会保存或上传密码。',
                style: TextStyle(fontSize: 12),
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
    AppToast.error(context, message);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    AppToast.success(context, message);
  }

  void _handleShelfPointerDown(PointerDownEvent event) {
    if (_reorderMode) return;
    _shelfPointerStart = event.position;
    _shelfPointerStartTime = DateTime.now();
  }

  void _handleShelfPointerCancel(PointerCancelEvent event) {
    _shelfPointerStart = null;
    _shelfPointerStartTime = null;
  }

  void _handleShelfPointerUp(PointerUpEvent event) {
    if (_reorderMode) {
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
    if (!_reorderScrollController.hasClients) return;
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
    final dialog = showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭设置',
      barrierColor: Colors.black.withValues(alpha: 0.14),
      transitionDuration: AppMotion.drawer,
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final width = math.min(MediaQuery.sizeOf(ctx).width * 0.86, 360.0);
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: width,
            height: double.infinity,
            child: GestureDetector(
              // Swipe left (towards the left edge, i.e. negative dx) on the
              // settings panel itself dismisses the drawer.
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity != null &&
                    details.primaryVelocity! < -200) {
                  Navigator.of(ctx).pop();
                }
              },
              child: Material(
                color: Colors.transparent,
                child: StatefulBuilder(
                  builder: (context, setSheetState) {
                    final colors = AppTheme.getReaderTheme(
                      sheetSettings.theme,
                      systemBrightness: MediaQuery.platformBrightnessOf(
                        context,
                      ),
                    );
                    return GlobalSettingsSheet(
                      settings: sheetSettings,
                      colors: colors,
                      onChange: (newSettings) {
                        setSheetState(() => sheetSettings = newSettings);
                        if (mounted) setState(() => _settings = newSettings);
                        _syncAutomaticUpdateCheck();
                        _persistSettings(newSettings);
                      },
                      onImportFont: () async {
                        try {
                          final newSettings = await _fontService
                              .pickAndInstallFont(sheetSettings);
                          if (newSettings == null) return;
                          if (!context.mounted || !mounted) return;
                          setSheetState(() => sheetSettings = newSettings);
                          if (mounted) setState(() => _settings = newSettings);
                          await _storage.saveSettings(newSettings);
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
                        // Close the sheet first so the result dialog or
                        // snackbar lands on the shelf instead of the sheet.
                        Navigator.of(context).pop();
                        await _checkUpdateManually();
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.standard,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
    unawaited(dialog.whenComplete(() => _settingsOpen = false));
  }

  Future<void> _showBookActions(Book book) async {
    final colors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final action = await showModalBottomSheet<_BookAction>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.34),
      builder: (sheetContext) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(AppSpacing.md),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.headerBg,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: colors.border),
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: colors.accent),
                title: Text('修改书籍名称', style: TextStyle(color: colors.text)),
                subtitle: Text(
                  '只修改书架显示名称，不改动原文件',
                  style: TextStyle(color: colors.secondary),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                onTap: () => Navigator.pop(sheetContext, _BookAction.rename),
              ),
              const SizedBox(height: AppSpacing.xs),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Row(
                  children: [
                    _compactBookAction(
                      sheetContext: sheetContext,
                      action: _BookAction.move,
                      icon: Icons.open_with_rounded,
                      label: '移动',
                      color: colors.accent,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _compactBookAction(
                      sheetContext: sheetContext,
                      action: _BookAction.delete,
                      icon: Icons.delete_outline_rounded,
                      label: '删除',
                      color: Color.lerp(
                        colors.accent,
                        const Color(0xFFD83B32),
                        0.72,
                      )!,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _BookAction.rename:
        await _renameBook(book);
      case _BookAction.move:
        _enterReorderMode(book.id);
      case _BookAction.delete:
        _confirmDeleteBook(book);
    }
  }

  Widget _compactBookAction({
    required BuildContext sheetContext,
    required _BookAction action,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: () => Navigator.pop(sheetContext, action),
            child: Container(
              height: 66,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: color.withValues(alpha: 0.20)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1,
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

  Future<void> _renameBook(Book book) async {
    final titleController = TextEditingController(text: book.title);
    final authorController = TextEditingController(text: book.author);
    final formKey = GlobalKey<FormState>();
    final colors = AppTheme.getReaderTheme(
      _settings.theme,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final edited = await showDialog<({String title, String author})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.headerBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text('修改书籍信息', style: TextStyle(color: colors.text)),
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
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colors.accent, width: 1.5),
                  ),
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
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colors.accent, width: 1.5),
                  ),
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
            style: FilledButton.styleFrom(backgroundColor: colors.accent),
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

  void _confirmDeleteBook(Book book) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '取消',
      barrierColor: Colors.black54,
      transitionDuration: AppMotion.normal,
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final dialogColors = AppTheme.getReaderTheme(
          _settings.theme,
          systemBrightness: MediaQuery.platformBrightnessOf(ctx),
        );
        return AlertDialog(
          backgroundColor: dialogColors.headerBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: Text('删除书籍', style: TextStyle(color: dialogColors.text)),
          content: Text(
            '确定要删除「${book.title}」吗？',
            style: TextStyle(color: dialogColors.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                '取消',
                style: TextStyle(color: dialogColors.secondary),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  await _storage.deleteBook(book.id);
                  await _loadData();
                } on Object {
                  _showError('删除失败，请稍后重试');
                }
              },
              child: Text('删除', style: TextStyle(color: dialogColors.accent)),
            ),
          ],
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.emphasized,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: curved, child: child),
        );
      },
    );
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
        // Navigator.push completes as soon as pop is requested, before the
        // reverse transition has even started. The route still paints the
        // cover snapshot and listens to transitionColors while closing, so
        // both resources must stay alive until the overlay is truly removed.
        await readerRoute.completed;
      } catch (error, stackTrace) {
        // The custom book-opening route is an enhancement, not a reason a
        // reader should fail to open. Fall back to a normal Material route.
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
    final delete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('从书架删除'),
          ),
        ],
      ),
    );
    if (delete != true) return;
    await _storage.deleteBook(book.id);
    if (mounted) await _loadData();
  }

  Future<void> _openBookFromCover(Book book, GlobalKey coverKey) async {
    if (_openingBook) return;
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
      // Snapshot the cover image for use by the page-curl route transition.
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
            child: Column(
              children: [
                // Header — gains a subtle drop shadow once the grid below has
                // scrolled past a few pixels, so it reads as sitting above the
                // content rather than just being the first item in a column.
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

                // Content
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.topCenter,
                      fit: StackFit.expand,
                      children: [...previousChildren, ?currentChild],
                    ),
                    child: _loading
                        ? const Center(
                            key: ValueKey('loading'),
                            child: CircularProgressIndicator(),
                          )
                        : _books.isEmpty
                        ? KeyedSubtree(
                            key: const ValueKey('empty'),
                            child: _buildEmptyState(colors),
                          )
                        : !_reorderMode && _visibleBooks.isEmpty
                        ? KeyedSubtree(
                            key: const ValueKey('no-shelf-results'),
                            child: _buildNoShelfResults(colors),
                          )
                        : KeyedSubtree(
                            key: ValueKey(
                              _reorderMode
                                  ? 'reorder-grid'
                                  : 'library-grid-${_shelfFilter.name}-${_librarySearchController.text}',
                            ),
                            child: _buildBookGrid(colors),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return PopScope<void>(
      canPop: !_reorderMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _reorderMode) _exitReorderMode();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemUiOverlayStyle(colors),
        child: content,
      ),
    );
  }

  Widget _buildLibraryHeader(ReaderThemeColors colors) {
    return Padding(
      padding: _reorderMode
          ? const EdgeInsets.fromLTRB(12, 2, 12, 2)
          : const EdgeInsets.fromLTRB(20, AppSpacing.lg, 20, AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _reorderMode
                    ? _exitReorderMode
                    : _showGlobalSettings,
                tooltip: _reorderMode ? '退出移动' : '设置',
                icon: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  child: Icon(
                    _reorderMode ? Icons.close_rounded : Icons.menu,
                    key: ValueKey(_reorderMode),
                    color: colors.secondary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AnimatedSwitcher(
                duration: AppMotion.fast,
                transitionBuilder: (child, animation) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.18),
                    end: Offset.zero,
                  ).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Text(
                  _reorderMode ? '调整顺序' : '书架',
                  key: ValueKey(_reorderMode),
                  style: TextStyle(
                    fontSize: _reorderMode ? 20 : 24,
                    fontWeight: FontWeight.w700,
                    color: colors.text,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const Spacer(),
              if (!_reorderMode) ...[
                IconButton(
                  tooltip: '搜索书架',
                  onPressed: () {
                    setState(
                      () => _librarySearchVisible = !_librarySearchVisible,
                    );
                  },
                  icon: Icon(
                    _librarySearchVisible
                        ? Icons.search_off_rounded
                        : Icons.search_rounded,
                    color: colors.secondary,
                  ),
                ),
                PopupMenuButton<_ShelfFilter>(
                  tooltip: '筛选书架',
                  initialValue: _shelfFilter,
                  onSelected: (value) => setState(() => _shelfFilter = value),
                  icon: Icon(
                    _shelfFilter == _ShelfFilter.all
                        ? Icons.filter_list_rounded
                        : Icons.filter_list_alt,
                    color: _shelfFilter == _ShelfFilter.all
                        ? colors.secondary
                        : colors.accent,
                  ),
                  itemBuilder: (_) => [
                    for (final filter in _ShelfFilter.values)
                      PopupMenuItem<_ShelfFilter>(
                        value: filter,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              child: filter == _shelfFilter
                                  ? Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: colors.accent,
                                    )
                                  : null,
                            ),
                            Text(filter.label),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              AnimatedSwitcher(
                duration: AppMotion.fast,
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
                        onPressed: _importing ? null : _importBook,
                        icon: Icon(
                          _importing ? Icons.hourglass_empty : Icons.add,
                          size: 18,
                        ),
                        label: Text(_importing ? '导入中...' : '导入'),
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
            child:
                !_reorderMode &&
                    (_librarySearchVisible || _shelfFilter != _ShelfFilter.all)
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.sm,
                      AppSpacing.sm,
                      0,
                    ),
                    child: TextField(
                      controller: _librarySearchController,
                      autofocus: _librarySearchVisible,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(color: colors.text, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索书名、作者或格式',
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          color: colors.secondary,
                        ),
                        suffixIcon: _librarySearchController.text.isEmpty
                            ? (_shelfFilter == _ShelfFilter.all
                                  ? null
                                  : Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Chip(
                                        label: Text(_shelfFilter.label),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ))
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () {
                                  _librarySearchController.clear();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                        filled: true,
                        fillColor: colors.headerBg,
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          borderSide: BorderSide(color: colors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          borderSide: BorderSide(color: colors.border),
                        ),
                      ),
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
            '还没有书籍',
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
              '点击下方按钮，导入 TXT、EPUB、MOBI/AZW、PDF 或 Word 文档',
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
            label: Text(_importing ? '导入中...' : '导入书籍'),
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
              onPressed: _hasShelfQueryOrFilter
                  ? _clearShelfQueryAndFilter
                  : null,
              child: const Text('清除搜索和筛选'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookGrid(ReaderThemeColors colors) {
    if (_reorderMode) return _buildReorderBookGrid(colors);
    final books = _visibleBooks;

    return RefreshIndicator(
      onRefresh: _loadData,
      color: colors.accent,
      child: GridView.builder(
        controller: _gridScrollController,
        padding: const EdgeInsets.all(AppSpacing.md),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
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
          final coverKey = GlobalObjectKey('book-cover-source-${book.id}');
          final card = RepaintBoundary(
            key: cardKey,
            child: BookCard(
              book: book,
              progress: _progressMap[book.id],
              availability:
                  _availabilityMap[book.id] ?? BookAvailability.available,
              colors: colors,
              coverKey: coverKey,
              onTap: () => _openBookFromCover(book, coverKey),
              onLongPress: () => _showBookActions(book),
            ),
          );

          // Staggered entrance: cap how many items participate in the
          // stagger so a long shelf doesn't push later cards' start time
          // past 1.0 (Interval asserts 0 <= begin <= end <= 1).
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
              final value = interval.transform(_gridEntranceController.value);
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
    );
  }

  Widget _buildReorderBookGrid(ReaderThemeColors colors) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPadding = AppSpacing.md;
        const columnCount = 3;
        const horizontalGap = AppSpacing.xs;
        const verticalGap = AppSpacing.sm;
        final gridWidth = math.max(
          0.0,
          constraints.maxWidth - horizontalPadding * 2,
        );
        final cardWidth = math.max(
          0.0,
          (gridWidth - horizontalGap * (columnCount - 1)) / columnCount,
        );
        final cardHeight = cardWidth / 0.52;
        final rowCount = (_books.length / columnCount).ceil();
        final contentHeight = rowCount == 0
            ? 0.0
            : rowCount * cardHeight + (rowCount - 1) * verticalGap;

        return SingleChildScrollView(
          key: const ValueKey('reorder-grid'),
          controller: _reorderScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            horizontalPadding,
          ),
          child: SizedBox(
            width: gridWidth,
            height: contentHeight,
            child: Stack(
              alignment: Alignment.topLeft,
              clipBehavior: Clip.none,
              children: [
                for (var index = 0; index < _books.length; index++)
                  _buildReorderBookItem(
                    book: _books[index],
                    index: index,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    horizontalGap: horizontalGap,
                    verticalGap: verticalGap,
                    colors: colors,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildReorderBookItem({
    required Book book,
    required int index,
    required double cardWidth,
    required double cardHeight,
    required double horizontalGap,
    required double verticalGap,
    required ReaderThemeColors colors,
  }) {
    const columnCount = 3;
    final column = index % columnCount;
    final row = index ~/ columnCount;
    final left = column * (cardWidth + horizontalGap);
    final top = row * (cardHeight + verticalGap);

    return AnimatedPositioned(
      key: ValueKey<String>(book.id),
      duration: AppMotion.shelfReorder,
      curve: AppMotion.shelfReorderCurve,
      left: left,
      top: top,
      width: cardWidth,
      height: cardHeight,
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) => details.data != book.id,
        onMove: (_) => _moveDraggedBook(book.id),
        builder: (context, candidateData, rejectedData) {
          final isTarget = candidateData.any((id) => id != book.id);
          final isFocused = _reorderFocusBookId == book.id;
          final card = _buildReorderCard(book, colors);
          return Semantics(
            label: '拖动移动《${book.title}》',
            hint: '按住并拖动到新的书架位置',
            child: AnimatedScale(
              scale: isTarget ? 0.965 : (isFocused ? 1.035 : 1.0),
              duration: isTarget ? AppMotion.quick : AppMotion.shelfLift,
              curve: AppMotion.shelfReorderCurve,
              child: AnimatedContainer(
                duration: AppMotion.shelfLift,
                curve: AppMotion.shelfReorderCurve,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(
                    color: isTarget || isFocused
                        ? colors.accent.withValues(alpha: 0.42)
                        : Colors.transparent,
                    width: 1.2,
                  ),
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: colors.accent.withValues(alpha: 0.16),
                            blurRadius: 18,
                            offset: const Offset(0, 7),
                          ),
                        ]
                      : const [],
                ),
                child: Draggable<String>(
                  data: book.id,
                  maxSimultaneousDrags: _openingBook ? 0 : 1,
                  dragAnchorStrategy: _centerDragAnchorStrategy,
                  onDragStarted: () => _startBookDrag(book),
                  onDragUpdate: _updateBookDrag,
                  onDragEnd: (_) => _finishBookDrag(book),
                  feedback: _buildLiftedBookFeedback(
                    book: book,
                    width: cardWidth,
                    height: cardHeight,
                    colors: colors,
                  ),
                  childWhenDragging: _buildReorderPlaceholder(card, colors),
                  child: card,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildReorderCard(Book book, ReaderThemeColors colors) {
    return BookCard(
      book: book,
      progress: _progressMap[book.id],
      availability: _availabilityMap[book.id] ?? BookAvailability.available,
      colors: colors,
      onTap: () {},
    );
  }

  Widget _buildReorderPlaceholder(Widget card, ReaderThemeColors colors) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: colors.accent.withValues(alpha: 0.18),
          width: 1,
        ),
      ),
      child: Opacity(opacity: 0.12, child: card),
    );
  }

  Widget _buildLiftedBookFeedback({
    required Book book,
    required double width,
    required double height,
    required ReaderThemeColors colors,
  }) {
    return IgnorePointer(
      child: Material(
        color: Colors.transparent,
        elevation: 18,
        shadowColor: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Transform.scale(
          scale: 1.055,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.headerBg.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.42),
                width: 1.2,
              ),
            ),
            child: SizedBox(
              width: width,
              height: height,
              child: _buildReorderCard(book, colors),
            ),
          ),
        ),
      ),
    );
  }
}
