import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';

typedef ChapterEditSaver = Future<void> Function(String title, String content);

/// Full-page chapter editor with a safe header and keyboard-resized body.
class ChapterEditorSheet extends StatefulWidget {
  final String initialTitle;
  final String initialContent;
  final bool hasRichContent;
  final ReaderThemeColors colors;
  final ChapterEditSaver onSave;

  const ChapterEditorSheet({
    super.key,
    required this.initialTitle,
    required this.initialContent,
    required this.hasRichContent,
    required this.colors,
    required this.onSave,
  });

  @override
  State<ChapterEditorSheet> createState() => _ChapterEditorSheetState();
}

class _ChapterEditorSheetState extends State<ChapterEditorSheet>
    with WidgetsBindingObserver {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  bool _saving = false;
  bool _allowPop = false;
  String? _errorMessage;
  bool _keyboardVisible = false;
  bool _routeCurrent = false;
  bool _foreground = true;
  bool _barSyncQueued = false;
  Timer? _barRestoreTimer;

  SystemUiOverlayStyle get _systemBarStyle =>
      AppTheme.systemUiOverlayStyle(widget.colors).copyWith(
        systemNavigationBarColor: widget.colors.background,
        systemNavigationBarDividerColor: widget.colors.background,
      );

  bool get _canRestoreBars =>
      mounted &&
      !_allowPop &&
      _foreground &&
      _routeCurrent &&
      !_keyboardVisible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardVisible = View.of(context).viewInsets.bottom > 0;
    final current = ModalRoute.of(context)?.isCurrent ?? false;
    if (current == _routeCurrent) return;
    _routeCurrent = current;
    if (current) {
      _queueSystemBarRestore();
    } else {
      _barRestoreTimer?.cancel();
    }
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final visible = View.of(context).viewInsets.bottom > 0;
    final wasVisible = _keyboardVisible;
    _keyboardVisible = visible;
    if (visible) {
      _barRestoreTimer?.cancel();
    } else if (wasVisible) {
      _queueSystemBarRestore();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _queueSystemBarRestore();
    } else {
      _barRestoreTimer?.cancel();
    }
  }

  void _queueSystemBarRestore() {
    _barRestoreTimer?.cancel();
    if (_barSyncQueued) return;
    _barSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _barSyncQueued = false;
      if (!_canRestoreBars) return;
      _restoreSystemBars();
      // Android can defer overlay changes for one second after IME dismissal.
      _barRestoreTimer = Timer(
        const Duration(milliseconds: 1100),
        _restoreSystemBars,
      );
    });
  }

  void _restoreSystemBars() {
    if (!_canRestoreBars) return;
    SystemChrome.setSystemUIOverlayStyle(_systemBarStyle);
    // Refresh the embedder's cached mode/style even when Flutter's style value
    // is unchanged. The IME can temporarily own the navigation-bar appearance.
    scheduleMicrotask(() {
      if (!_canRestoreBars) return;
      unawaited(
        SystemChrome.restoreSystemUIOverlays().catchError((
          Object error,
          StackTrace stack,
        ) {
          debugPrint('Failed to restore editor system bars: $error');
        }),
      );
    });
  }

  bool get _dirty =>
      _titleController.text != widget.initialTitle ||
      _contentController.text != widget.initialContent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _titleController = TextEditingController(text: widget.initialTitle);
    _contentController = TextEditingController(text: widget.initialContent);
    _titleController.addListener(_handleChanged);
    _contentController.addListener(_handleChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _barRestoreTimer?.cancel();
    _titleController
      ..removeListener(_handleChanged)
      ..dispose();
    _contentController
      ..removeListener(_handleChanged)
      ..dispose();
    super.dispose();
  }

  void _handleChanged() {
    if (!mounted) return;
    setState(() => _errorMessage = null);
  }

  void _popAfterRebuild() {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      _popAfterRebuild();
      return;
    }
    final discard = await showAppDialog<bool>(
      context: context,
      colors: widget.colors,
      builder: (dialogContext) => AppDialog(
        title: const Text('放弃修改？'),
        content: const Text('当前章节还有未保存的修改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续编辑'),
          ),
          AppDestructiveButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) _popAfterRebuild();
  }

  Future<bool> _confirmFlattenRichContent() async {
    if (!widget.hasRichContent) return true;
    return await showAppDialog<bool>(
          context: context,
          colors: widget.colors,
          builder: (dialogContext) => AppDialog(
            title: const Text('转为纯文本章节？'),
            content: const Text(
              '这一章包含 EPUB 或 Word 的图片、强调和排版样式。保存正文修改后，'
              '只会把当前章节转为纯文本，其他章节和原始文件不受影响。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('继续保存'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _titleController.text.trim();
    final content = _contentController.text;
    if (title.isEmpty) {
      setState(() => _errorMessage = '章节标题不能为空');
      return;
    }
    if (content.trim().isEmpty) {
      setState(() => _errorMessage = '章节正文不能为空');
      return;
    }
    if (!_dirty) {
      _popAfterRebuild();
      return;
    }
    if (!await _confirmFlattenRichContent() || !mounted) return;

    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      await widget.onSave(title, content);
      if (!mounted) return;
      _popAfterRebuild();
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to save chapter edit: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage = error is FormatException
            ? error.message.toString()
            : '保存失败，请检查存储空间后重试';
      });
    }
  }

  InputBorder _fieldBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final editor = PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestClose();
      },
      child: Material(
        color: colors.background,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 12, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _saving ? null : _requestClose,
                      tooltip: '关闭编辑器',
                      icon: Icon(Icons.close_rounded, color: colors.secondary),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '编辑当前章节',
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '仅分章滑动模式 · 保存到本地副本',
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined, size: 18),
                      label: Text(_saving ? '保存中' : '保存'),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.border),
              if (widget.hasRichContent)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(
                      color: colors.accent.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Text(
                    '当前章节含富文本。保存后本章会转为纯文本，原始导入文件不会被修改。',
                    style: TextStyle(
                      color: colors.secondary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: TextField(
                  controller: _titleController,
                  enabled: !_saving,
                  maxLength: 200,
                  style: TextStyle(
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    labelText: '章节标题',
                    labelStyle: TextStyle(color: colors.secondary),
                    counterText: '',
                    filled: true,
                    fillColor: colors.headerBg,
                    border: _fieldBorder(colors.border),
                    enabledBorder: _fieldBorder(colors.border),
                    focusedBorder: _fieldBorder(colors.accent, width: 1.5),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: TextField(
                    controller: _contentController,
                    enabled: !_saving,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 17,
                      height: 1.65,
                    ),
                    decoration: InputDecoration(
                      hintText: '输入章节正文',
                      hintStyle: TextStyle(color: colors.secondary),
                      filled: true,
                      fillColor: colors.headerBg,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                      ),
                      border: _fieldBorder(colors.border),
                      enabledBorder: _fieldBorder(colors.border),
                      focusedBorder: _fieldBorder(colors.accent, width: 1.5),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _errorMessage ?? '修改不会回写原始书籍文件',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _errorMessage == null
                              ? colors.secondary
                              : colors.accent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Text(
                      '${_contentController.text.runes.length} 字符',
                      style: TextStyle(color: colors.secondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemBarStyle,
      child: Scaffold(
        backgroundColor: colors.background,
        resizeToAvoidBottomInset: true,
        body: editor,
      ),
    );
  }
}
