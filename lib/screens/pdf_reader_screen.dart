import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';
import '../services/pdf_renderer_service.dart';
import '../models/search_match.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../widgets/book_search_sheet.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_sheet.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_popup_menu.dart';

class PdfReaderScreen extends StatefulWidget {
  final Book book;
  final PdfReaderRepository? repository;
  final PdfRendererGateway? renderer;

  const PdfReaderScreen({
    super.key,
    required this.book,
    this.repository,
    this.renderer,
  });

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  late final PdfReaderRepository _storage;
  late final PdfRendererGateway _renderer;
  final Map<String, Future<String>> _renderTasks = <String, Future<String>>{};
  final Map<int, TransformationController> _transformControllers =
      <int, TransformationController>{};
  final Set<int> _zoomedPages = <int>{};
  PageController? _pageController;
  int _currentPage = 0;
  bool _ready = false;
  bool _chromeVisible = true;
  bool _deleting = false;
  Set<int> _bookmarks = <int>{};
  Map<int, String> _notes = <int, String>{};
  PdfDisplayTheme _displayTheme = PdfDisplayTheme.original;
  int? _sliderPage;
  String? _fatalError;
  Timer? _autoHideTimer;

  ReaderThemeColors get _overlayColors =>
      AppTheme.getReaderTheme(switch (_displayTheme) {
        PdfDisplayTheme.original => ReaderThemeMode.light,
        PdfDisplayTheme.paper => ReaderThemeMode.warm,
        PdfDisplayTheme.dark => ReaderThemeMode.dark,
      });

  int get _pageCount => widget.book.pageCount ?? 0;
  String? get _sourcePath => widget.book.sourcePath;

  @override
  void initState() {
    super.initState();
    _storage = widget.repository ?? StorageService();
    _renderer = widget.renderer ?? const PlatformPdfRendererGateway();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_setWakelock(true));
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    final sourcePath = _sourcePath;
    if (sourcePath == null || !await File(sourcePath).exists()) {
      if (!mounted) return;
      setState(() {
        _pageController = PageController();
        _fatalError = 'PDF 源文件已丢失';
        _ready = true;
      });
      return;
    }
    PdfReadingProgress? progress;
    Set<int> bookmarks = <int>{};
    Map<int, String> notes = <int, String>{};
    var displayTheme = PdfDisplayTheme.original;
    try {
      final values = await Future.wait<Object?>([
        _storage.getPdfProgress(widget.book.id, pageCount: _pageCount),
        _storage.getPdfBookmarks(widget.book.id, _pageCount),
        _storage.getPdfNotes(widget.book.id, _pageCount),
        _storage.getPdfDisplayTheme(widget.book.id),
        _renderer
            .getTextAnnotations(sourcePath)
            .catchError(
              (Object _, StackTrace _) => const <PdfTextAnnotation>[],
            ),
      ]);
      progress = values[0] as PdfReadingProgress?;
      bookmarks = values[1] as Set<int>;
      notes = values[2] as Map<int, String>;
      displayTheme = values[3] as PdfDisplayTheme;
      final embeddedAnnotations = values[4] as List<PdfTextAnnotation>;
      for (final annotation in embeddedAnnotations) {
        if (annotation.pageIndex < 0 || annotation.pageIndex >= _pageCount) {
          continue;
        }
        final existing = notes[annotation.pageIndex];
        if (existing == null || existing.isEmpty) {
          notes[annotation.pageIndex] = annotation.contents;
        } else if (!existing.contains(annotation.contents) &&
            !annotation.annotationId.startsWith('ReadVibe:')) {
          notes[annotation.pageIndex] = '$existing\n${annotation.contents}';
        }
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to load PDF state: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    final page = _pageCount > 0
        ? (progress?.pageIndex ?? 0).clamp(0, _pageCount - 1)
        : 0;
    if (!mounted) return;
    setState(() {
      _currentPage = page;
      _bookmarks = bookmarks;
      _notes = notes;
      _displayTheme = displayTheme;
      _pageController = PageController(initialPage: page);
      _ready = true;
    });
    _scheduleChromeAutoHide();
  }

  Future<void> _setWakelock(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } on Object catch (error, stackTrace) {
      debugPrint(
        'Failed to ${enabled ? 'enable' : 'disable'} PDF wakelock: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Novel reader parity: a tap on the page toggles the chrome, and the bar
  /// hides itself shortly after opening so reading starts undistracted.
  void _scheduleChromeAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _setChromeVisible(false);
    });
  }

  void _setChromeVisible(bool visible) {
    if (_chromeVisible == visible) return;
    setState(() => _chromeVisible = visible);
    SystemChrome.setEnabledSystemUIMode(
      visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _toggleChrome() {
    _autoHideTimer?.cancel();
    final visible = !_chromeVisible;
    _setChromeVisible(visible);
    if (visible) _scheduleChromeAutoHide();
  }

  Future<void> _savePage(int page) async {
    try {
      final progress = PdfReadingProgress(
        bookId: widget.book.id,
        pageIndex: page,
        pageCount: _pageCount,
        lastReadDate: DateTime.now(),
      );
      await _storage.savePdfProgress(progress);
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to save PDF progress: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _goToPage(int page, {bool animate = true}) async {
    final controller = _pageController;
    if (controller == null || _pageCount <= 0) return;
    final target = page.clamp(0, _pageCount - 1);
    _transformControllers[_currentPage]?.value = Matrix4.identity();
    if (animate && controller.hasClients) {
      await controller.animateToPage(
        target,
        duration: AppMotion.normal,
        curve: AppMotion.standard,
      );
    } else if (controller.hasClients) {
      controller.jumpToPage(target);
    }
    if (mounted) setState(() => _sliderPage = null);
  }

  Future<void> _showPageJumpDialog() async {
    _autoHideTimer?.cancel();
    final controller = TextEditingController(text: '${_currentPage + 1}');
    final page = await showAppDialog<int>(
      context: context,
      colors: _overlayColors,
      builder: (dialogContext) => AppDialog(
        title: const Text('跳转页码'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: InputDecoration(hintText: '1 - $_pageCount'),
          onSubmitted: (value) {
            final parsed = int.tryParse(value);
            if (parsed != null && parsed >= 1 && parsed <= _pageCount) {
              Navigator.of(dialogContext).pop(parsed - 1);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text);
              if (parsed != null && parsed >= 1 && parsed <= _pageCount) {
                Navigator.of(dialogContext).pop(parsed - 1);
              }
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (page != null && mounted) await _goToPage(page);
    if (mounted && _chromeVisible) _scheduleChromeAutoHide();
  }

  void _toggleBookmark() {
    setState(() {
      if (!_bookmarks.add(_currentPage)) _bookmarks.remove(_currentPage);
    });
    unawaited(
      _storage.savePdfBookmarks(widget.book.id, _bookmarks, _pageCount),
    );
  }

  Future<void> _showBookmarks() async {
    _autoHideTimer?.cancel();
    final pages = <int>{..._bookmarks, ..._notes.keys}.toList()..sort();
    final colors = _overlayColors;
    final selected = await showAppSheet<int>(
      context: context,
      colors: colors,
      builder: (sheetContext) => AppSheetSurface(
        colors: colors,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: math.min(
              MediaQuery.sizeOf(sheetContext).height * 0.65,
              520.0,
            ),
            child: Column(
              children: [
                const AppSheetHeader(title: 'PDF 书签与笔记'),
                const Divider(),
                Expanded(
                  child: pages.isEmpty
                      ? Center(
                          child: Text(
                            '还没有书签或笔记',
                            style: TextStyle(color: colors.secondary),
                          ),
                        )
                      : ListView.builder(
                          itemCount: pages.length,
                          itemBuilder: (context, index) {
                            final page = pages[index];
                            final note = _notes[page];
                            return ListTile(
                              leading: Icon(
                                _bookmarks.contains(page)
                                    ? Icons.bookmark_rounded
                                    : Icons.note_alt_outlined,
                                color: colors.accent,
                              ),
                              title: Text('第 ${page + 1} 页'),
                              subtitle: note == null
                                  ? null
                                  : Text(
                                      note,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => Navigator.of(sheetContext).pop(page),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _goToPage(selected);
    if (mounted && _chromeVisible) _scheduleChromeAutoHide();
  }

  Future<void> _editPageNote() async {
    _autoHideTimer?.cancel();
    final controller = TextEditingController(text: _notes[_currentPage] ?? '');
    final note = await showAppDialog<String?>(
      context: context,
      colors: _overlayColors,
      builder: (dialogContext) => AppDialog(
        title: Text('第 ${_currentPage + 1} 页笔记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 4,
          maxLines: 8,
          maxLength: 4000,
          decoration: const InputDecoration(hintText: '输入本地笔记'),
        ),
        actions: [
          if (_notes.containsKey(_currentPage))
            AppDestructiveButton(
              filled: false,
              onPressed: () => Navigator.of(dialogContext).pop(''),
              child: const Text('删除笔记'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null || !mounted) return;
    setState(() {
      final normalized = note.trim();
      if (normalized.isEmpty) {
        _notes.remove(_currentPage);
      } else {
        _notes[_currentPage] = normalized;
      }
    });
    await _storage.savePdfNotes(widget.book.id, _notes, _pageCount);
    final sourcePath = _sourcePath;
    if (sourcePath != null) {
      try {
        await _renderer.syncTextNote(
          filePath: sourcePath,
          pageIndex: _currentPage,
          noteId: 'ReadVibe:${widget.book.id}:$_currentPage',
          contents: note.trim(),
        );
        _renderTasks.clear();
        if (mounted) setState(() {});
      } on Object catch (error, stackTrace) {
        debugPrint('Failed to embed PDF text annotation: $error');
        debugPrintStack(stackTrace: stackTrace);
        if (mounted) {
          AppToast.error(
            context,
            '本地笔记已保存，但写入 PDF 批注失败',
            colors: _overlayColors,
          );
        }
      }
    }
    if (mounted && _chromeVisible) _scheduleChromeAutoHide();
  }

  Future<List<PdfTextSearchResult>> _searchPdf(String query) async {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return const <PdfTextSearchResult>[];
    return _renderer.searchText(filePath: sourcePath, query: query);
  }

  Future<List<PdfTextSearchResult>> _searchPdfWithOcr(String rawQuery) async {
    final sourcePath = _sourcePath;
    final query = _normalizeOcrText(rawQuery).toLowerCase();
    if (sourcePath == null || query.isEmpty) {
      return const <PdfTextSearchResult>[];
    }
    final results = <PdfTextSearchResult>[];
    for (var pageIndex = 0; pageIndex < _pageCount; pageIndex++) {
      final source = await _renderer.recognizePageText(
        filePath: sourcePath,
        pageIndex: pageIndex,
      );
      final normalized = _normalizeOcrText(source);
      final searchable = normalized.toLowerCase();
      var offset = searchable.indexOf(query);
      while (offset >= 0 && results.length < maxDocumentSearchResults) {
        final end = offset + query.length;
        final snippetStart = math.max(0, offset - 30);
        final snippetEnd = math.min(normalized.length, end + 48);
        final leading = snippetStart > 0;
        final trailing = snippetEnd < normalized.length;
        final snippet =
            '${leading ? '…' : ''}${normalized.substring(snippetStart, snippetEnd)}${trailing ? '…' : ''}';
        final matchStart = (leading ? 1 : 0) + offset - snippetStart;
        results.add(
          PdfTextSearchResult(
            pageIndex: pageIndex,
            isOcr: true,
            snippet: snippet,
            matchedText: normalized.substring(offset, end),
            snippetMatchStart: matchStart,
            snippetMatchEnd: matchStart + end - offset,
          ),
        );
        offset = searchable.indexOf(query, end);
      }
      if (results.length >= maxDocumentSearchResults) break;
    }
    return results;
  }

  String _normalizeOcrText(String value) => value
      .replaceAll(
        RegExp(
          r'[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+',
        ),
        ' ',
      )
      .trim();

  Future<void> _showPdfSearch({bool useOcr = false}) async {
    _autoHideTimer?.cancel();
    final colors = _overlayColors;
    final selected = await showAppSheet<PdfTextSearchResult>(
      context: context,
      colors: _overlayColors,
      builder: (sheetContext) => AnimatedPadding(
        duration: AppMotion.normal,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: 0.88,
          child: BookSearchSheet<PdfTextSearchResult>(
            colors: colors,
            onSearch: useOcr ? _searchPdfWithOcr : _searchPdf,
            onSelect: (result) =>
                Navigator.of(sheetContext).pop<PdfTextSearchResult>(result),
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _goToPage(selected.pageIndex);
    if (mounted && _chromeVisible) _scheduleChromeAutoHide();
  }

  Future<void> _recognizeCurrentPage() async {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return;
    _autoHideTimer?.cancel();
    var text = '';
    try {
      text = await _renderer.recognizePageText(
        filePath: sourcePath,
        pageIndex: _currentPage,
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to OCR PDF page: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      colors: _overlayColors,
      builder: (dialogContext) => AppDialog(
        title: Text('第 ${_currentPage + 1} 页识别文字'),
        content: SizedBox(
          width: double.maxFinite,
          child: text.isEmpty
              ? const Text('这一页没有识别到文字。')
              : SelectableText(text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (mounted && _chromeVisible) _scheduleChromeAutoHide();
  }

  Future<void> _showDisplayThemeSheet() async {
    _autoHideTimer?.cancel();
    final selected = await showAppSheet<PdfDisplayTheme>(
      context: context,
      colors: _overlayColors,
      builder: (sheetContext) => AppActionSheet(
        colors: _overlayColors,
        title: 'PDF 显示主题',
        subtitle: 'PDF 是固定版式；字号由原文件决定，可用双指缩放阅读。',
        children: [
          for (final theme in PdfDisplayTheme.values)
            ListTile(
              leading: Icon(
                theme == _displayTheme
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: theme == _displayTheme
                    ? _overlayColors.accent
                    : _overlayColors.secondary,
              ),
              title: Text(theme.label),
              onTap: () => Navigator.pop(sheetContext, theme),
            ),
        ],
      ),
    );
    if (selected != null && selected != _displayTheme && mounted) {
      setState(() => _displayTheme = selected);
      await _storage.savePdfDisplayTheme(widget.book.id, selected);
    }
    if (mounted && _chromeVisible) _scheduleChromeAutoHide();
  }

  Future<void> _showPdfOutline() async {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return;
    _autoHideTimer?.cancel();
    final colors = _overlayColors;
    final outline = _renderer.getOutline(sourcePath);
    final selected = await showAppSheet<int>(
      context: context,
      colors: colors,
      builder: (sheetContext) => AppSheetSurface(
        colors: colors,
        child: SafeArea(
          top: false,
          child: FractionallySizedBox(
            heightFactor: 0.75,
            child: Column(
              children: [
                const AppSheetHeader(title: 'PDF 大纲'),
                const Divider(),
                Expanded(
                  child: FutureBuilder<List<PdfOutlineEntry>>(
                    future: outline,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Text(
                            '无法读取 PDF 大纲',
                            style: TextStyle(color: colors.secondary),
                          ),
                        );
                      }
                      final entries = snapshot.data;
                      if (entries == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (entries.isEmpty) {
                        return Center(
                          child: Text(
                            '这份 PDF 没有可用大纲',
                            style: TextStyle(color: colors.secondary),
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return ListTile(
                            contentPadding: EdgeInsets.only(
                              left: 20 + entry.depth.clamp(0, 8) * 14,
                              right: 16,
                            ),
                            title: Text(
                              entry.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(
                              '${entry.pageIndex + 1}',
                              style: TextStyle(color: colors.secondary),
                            ),
                            onTap: () =>
                                Navigator.of(sheetContext).pop(entry.pageIndex),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _goToPage(selected);
    if (mounted && _chromeVisible) _scheduleChromeAutoHide();
  }

  Future<void> _deleteUnavailablePdf() async {
    if (_deleting) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      colors: _overlayColors,
      builder: (dialogContext) => AppDialog(
        title: const Text('删除这本 PDF？'),
        content: Text('「${widget.book.title}」的源文件已经丢失或无法渲染。可以从书架中移除它。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          AppDestructiveButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    await _storage.deleteBook(widget.book.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<String> _pageImage(int pageIndex, int widthPx) {
    final sourcePath = _sourcePath;
    if (sourcePath == null) {
      return Future<String>.error(const FormatException('PDF 文件路径无效'));
    }
    final normalizedWidth = (widthPx / 120).round() * 120;
    final key = '$pageIndex:$normalizedWidth';
    final existing = _renderTasks.remove(key);
    if (existing != null) {
      _renderTasks[key] = existing;
      return existing;
    }

    late final Future<String> task;
    task = () async {
      try {
        return await _renderer.renderPage(
          filePath: sourcePath,
          pageIndex: pageIndex,
          widthPx: normalizedWidth,
        );
      } on Object {
        if (identical(_renderTasks[key], task)) _renderTasks.remove(key);
        rethrow;
      }
    }();
    _renderTasks[key] = task;
    while (_renderTasks.length > 18) {
      _renderTasks.remove(_renderTasks.keys.first);
    }
    return task;
  }

  /// Per-page zoom tracking. While a page is zoomed in, horizontal drags must
  /// pan the image instead of turning the page, so the PageView's scroll is
  /// locked for exactly that page.
  TransformationController _transformControllerFor(int pageIndex) {
    final existing = _transformControllers[pageIndex];
    if (existing != null) return existing;
    final controller = TransformationController();
    controller.addListener(() {
      final zoomed = controller.value.getMaxScaleOnAxis() > 1.01;
      if (zoomed == _zoomedPages.contains(pageIndex)) return;
      setState(() {
        if (zoomed) {
          _zoomedPages.add(pageIndex);
        } else {
          _zoomedPages.remove(pageIndex);
        }
      });
    });
    _transformControllers[pageIndex] = controller;
    while (_transformControllers.length > 9) {
      final oldest = _transformControllers.keys.first;
      if (oldest == pageIndex) break;
      _transformControllers.remove(oldest)?.dispose();
      _zoomedPages.remove(oldest);
    }
    return controller;
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    if (_ready && _fatalError == null && _pageCount > 0) {
      unawaited(_savePage(_currentPage));
    }
    unawaited(_setWakelock(false));
    _renderTasks.clear();
    for (final controller in _transformControllers.values) {
      controller.dispose();
    }
    _transformControllers.clear();
    _pageController?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Color get _pdfPageBackground => switch (_displayTheme) {
    PdfDisplayTheme.original => const Color(0xFF111111),
    PdfDisplayTheme.paper => const Color(0xFFB8AD94),
    PdfDisplayTheme.dark => const Color(0xFF080808),
  };

  Widget _applyPdfDisplayTheme(Widget child) {
    final matrix = switch (_displayTheme) {
      PdfDisplayTheme.original => null,
      PdfDisplayTheme.paper => const <double>[
        0.86,
        0.10,
        0.02,
        0,
        12,
        0.05,
        0.82,
        0.05,
        0,
        8,
        0.02,
        0.08,
        0.72,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ],
      PdfDisplayTheme.dark => const <double>[
        -0.86,
        0,
        0,
        0,
        232,
        0,
        -0.86,
        0,
        0,
        232,
        0,
        0,
        -0.86,
        0,
        232,
        0,
        0,
        0,
        1,
        0,
      ],
    };
    return matrix == null
        ? child
        : ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: child);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _pageController;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleChrome,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!_ready || controller == null)
                const Center(child: CircularProgressIndicator())
              else if (_fatalError != null)
                _buildError(_fatalError!, allowDelete: true)
              else if (_pageCount <= 0 || _sourcePath == null)
                _buildError('PDF 文件数据不完整', allowDelete: true)
              else
                PageView.builder(
                  controller: controller,
                  itemCount: _pageCount,
                  physics: _zoomedPages.contains(_currentPage)
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  onPageChanged: (page) {
                    setState(() => _currentPage = page);
                    _savePage(page);
                  },
                  itemBuilder: (context, pageIndex) => LayoutBuilder(
                    builder: (context, constraints) {
                      final widthPx =
                          (constraints.maxWidth *
                                  MediaQuery.devicePixelRatioOf(context))
                              .round()
                              .clamp(480, 4096);
                      return FutureBuilder<String>(
                        future: _pageImage(pageIndex, widthPx),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return _buildError(
                              '第 ${pageIndex + 1} 页无法渲染',
                              allowDelete: true,
                            );
                          }
                          final path = snapshot.data;
                          if (path == null) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          return ColoredBox(
                            color: _pdfPageBackground,
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              child: InteractiveViewer(
                                transformationController:
                                    _transformControllerFor(pageIndex),
                                minScale: 1,
                                maxScale: 5,
                                boundaryMargin: const EdgeInsets.all(80),
                                child: Center(
                                  child: _applyPdfDisplayTheme(
                                    Image.file(
                                      File(path),
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.high,
                                      errorBuilder: (_, _, _) =>
                                          _buildError('页面图像读取失败'),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

              // ── Top chrome ────────────────────────────────
              Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomBar(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return IgnorePointer(
      ignoring: !_chromeVisible,
      child: AnimatedSlide(
        offset: _chromeVisible ? Offset.zero : const Offset(0, -1),
        duration: AppMotion.menu,
        curve: AppMotion.standard,
        child: AnimatedOpacity(
          opacity: _chromeVisible ? 1.0 : 0.0,
          duration: AppMotion.menu,
          curve: AppMotion.gentle,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.85),
                  Colors.black.withValues(alpha: 0.70),
                ],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: () async {
                        if (_ready && _fatalError == null && _pageCount > 0) {
                          await _savePage(_currentPage);
                        }
                        if (mounted) Navigator.of(context).maybePop();
                      },
                      icon: const Icon(
                        Icons.arrow_back_ios,
                        color: Colors.white,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            _pageCount > 0
                                ? '${_currentPage + 1} / $_pageCount 页'
                                : 'PDF',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'PDF 大纲',
                      onPressed: _fatalError == null && _pageCount > 0
                          ? _showPdfOutline
                          : null,
                      icon: const Icon(Icons.toc_rounded, color: Colors.white),
                    ),
                    IconButton(
                      tooltip: '搜索 PDF',
                      onPressed: _fatalError == null && _pageCount > 0
                          ? _showPdfSearch
                          : null,
                      icon: const Icon(
                        Icons.search_rounded,
                        color: Colors.white,
                      ),
                    ),
                    AppPopupMenuButton<String>(
                      colors: _overlayColors,
                      tooltip: 'PDF 工具',
                      enabled: _fatalError == null && _pageCount > 0,
                      icon: const Icon(Icons.more_vert, color: Colors.white),
                      onSelected: (value) {
                        switch (value) {
                          case 'theme':
                            unawaited(_showDisplayThemeSheet());
                          case 'ocr-page':
                            unawaited(_recognizeCurrentPage());
                          case 'ocr-search':
                            unawaited(_showPdfSearch(useOcr: true));
                        }
                      },
                      entries: const [
                        AppMenuEntry(
                          value: 'theme',
                          label: '显示主题',
                          icon: Icons.brightness_6_outlined,
                        ),
                        AppMenuEntry(
                          value: 'ocr-page',
                          label: '识别当前页',
                          icon: Icons.document_scanner_outlined,
                        ),
                        AppMenuEntry(
                          value: 'ocr-search',
                          label: '扫描件全文搜索',
                          icon: Icons.manage_search_rounded,
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

  Widget _buildBottomBar() {
    if (!_ready || _fatalError != null || _pageCount <= 0) {
      return const SizedBox.shrink();
    }
    final sliderPage = (_sliderPage ?? _currentPage).clamp(
      0,
      math.max(0, _pageCount - 1),
    );
    return IgnorePointer(
      ignoring: !_chromeVisible,
      child: AnimatedSlide(
        offset: _chromeVisible ? Offset.zero : const Offset(0, 1),
        duration: AppMotion.menu,
        curve: AppMotion.standard,
        child: AnimatedOpacity(
          opacity: _chromeVisible ? 1 : 0,
          duration: AppMotion.menu,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.68),
                  Colors.black.withValues(alpha: 0.90),
                ],
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '书签列表',
                      onPressed: _showBookmarks,
                      icon: const Icon(
                        Icons.bookmarks_outlined,
                        color: Colors.white70,
                      ),
                    ),
                    IconButton(
                      tooltip: _bookmarks.contains(_currentPage)
                          ? '取消书签'
                          : '添加书签',
                      onPressed: _toggleBookmark,
                      icon: Icon(
                        _bookmarks.contains(_currentPage)
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        color: _bookmarks.contains(_currentPage)
                            ? Colors.amberAccent
                            : Colors.white70,
                      ),
                    ),
                    IconButton(
                      tooltip: _notes.containsKey(_currentPage)
                          ? '编辑笔记'
                          : '添加笔记',
                      onPressed: _editPageNote,
                      icon: Icon(
                        _notes.containsKey(_currentPage)
                            ? Icons.note_alt_rounded
                            : Icons.note_add_outlined,
                        color: _notes.containsKey(_currentPage)
                            ? Colors.lightBlueAccent
                            : Colors.white70,
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          overlayColor: Colors.white12,
                        ),
                        child: Slider(
                          min: 0,
                          max: math.max(1, _pageCount - 1).toDouble(),
                          value: sliderPage.toDouble(),
                          onChanged: _pageCount <= 1
                              ? null
                              : (value) =>
                                    setState(() => _sliderPage = value.round()),
                          onChangeEnd: _pageCount <= 1
                              ? null
                              : (value) => _goToPage(value.round()),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _showPageJumpDialog,
                      child: Text(
                        '${sliderPage + 1} / $_pageCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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

  Widget _buildError(String message, {bool allowDelete = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.picture_as_pdf_outlined,
              color: Colors.white70,
              size: 48,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (allowDelete) ...[
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton.icon(
                onPressed: _deleting ? null : _deleteUnavailablePdf,
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(_deleting ? '正在删除…' : '从书架删除'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white30),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
