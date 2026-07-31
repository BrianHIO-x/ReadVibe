import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/pdf_renderer_service.dart';
import '../services/storage_service.dart';
import '../theme/app_spacing.dart';

class PdfReaderScreen extends StatefulWidget {
  final Book book;

  const PdfReaderScreen({super.key, required this.book});

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final _storage = StorageService();
  final Map<String, Future<String>> _renderTasks = <String, Future<String>>{};
  PageController? _pageController;
  int _currentPage = 0;
  bool _ready = false;

  int get _pageCount => widget.book.pageCount ?? 0;
  String? get _sourcePath => widget.book.sourcePath;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    try {
      final progress = await _storage.getProgress(widget.book.id);
      final page = _pageCount > 0
          ? (progress?.chapterIndex ?? 0).clamp(0, _pageCount - 1)
          : 0;
      if (!mounted) return;
      setState(() {
        _currentPage = page;
        _pageController = PageController(initialPage: page);
        _ready = true;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _pageController = PageController();
        _ready = true;
      });
    }
  }

  Future<void> _savePage(int page) async {
    try {
      final progress = ReadingProgress(
        bookId: widget.book.id,
        chapterIndex: page,
        scrollOffset: 0,
        scrollProgress: _pageCount <= 1 ? 0 : page / (_pageCount - 1),
        lastReadDate: DateTime.now(),
      );
      await _storage.saveProgress(progress);
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to save PDF progress: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
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
        return await PdfRendererService.renderPage(
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

  @override
  void dispose() {
    _renderTasks.clear();
    _pageController?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _pageController;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        appBar: AppBar(
          backgroundColor: const Color(0xFF181818),
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _pageCount > 0 ? '${_currentPage + 1} / $_pageCount 页' : 'PDF',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        ),
        body: !_ready || controller == null
            ? const Center(child: CircularProgressIndicator())
            : _pageCount <= 0 || _sourcePath == null
            ? _buildError('PDF 文件数据不完整')
            : PageView.builder(
                controller: controller,
                itemCount: _pageCount,
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
                          return _buildError('第 ${pageIndex + 1} 页无法渲染');
                        }
                        final path = snapshot.data;
                        if (path == null) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: InteractiveViewer(
                            minScale: 1,
                            maxScale: 5,
                            boundaryMargin: const EdgeInsets.all(80),
                            child: Center(
                              child: Image.file(
                                File(path),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (_, _, _) =>
                                    _buildError('页面图像读取失败'),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }

  Widget _buildError(String message) {
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
          ],
        ),
      ),
    );
  }
}
