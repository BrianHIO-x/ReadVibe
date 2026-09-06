import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme/app_spacing.dart';
import '../models/book_content_revision.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';

typedef ChapterEditSaver = Future<void> Function(String title, String content);

/// Paints a background tint behind every find hit, with a stronger tint on the
/// active one. Doing it in the controller keeps the hits visible while the body
/// field is unfocused, so navigating matches never has to summon the keyboard.
class _FindHighlightController extends TextEditingController {
  _FindHighlightController({super.text});

  List<TextRange> _matches = const <TextRange>[];
  int _activeIndex = -1;
  Color _matchColor = const Color(0x00000000);
  Color _activeColor = const Color(0x00000000);

  void applyHighlights({
    required List<TextRange> matches,
    required int activeIndex,
    required Color matchColor,
    required Color activeColor,
  }) {
    _matches = matches;
    _activeIndex = activeIndex;
    _matchColor = matchColor;
    _activeColor = activeColor;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing = withComposing && value.isComposingRangeValid;
    if (_matches.isEmpty || composing) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final source = text;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var index = 0; index < _matches.length; index++) {
      final range = _matches[index];
      if (range.start < cursor || range.end > source.length) break;
      if (range.start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, range.start)));
      }
      spans.add(
        TextSpan(
          text: source.substring(range.start, range.end),
          style: TextStyle(
            backgroundColor: index == _activeIndex ? _activeColor : _matchColor,
          ),
        ),
      );
      cursor = range.end;
    }
    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }
    return TextSpan(style: style, children: spans);
  }
}

/// Full-page chapter editor with a safe header and keyboard-resized body.
class ChapterEditorSheet extends StatefulWidget {
  final String initialTitle;
  final String initialContent;
  final bool hasRichContent;
  final ReaderThemeColors colors;
  final ChapterEditSaver onSave;

  /// Character offset in [initialContent] that the reader was sitting on. The
  /// body opens with the line holding that offset pinned to the very top.
  final int? initialAnchorOffset;

  const ChapterEditorSheet({
    super.key,
    required this.initialTitle,
    required this.initialContent,
    required this.hasRichContent,
    required this.colors,
    required this.onSave,
    this.initialAnchorOffset,
  });

  @override
  State<ChapterEditorSheet> createState() => _ChapterEditorSheetState();
}

class _ChapterEditorSheetState extends State<ChapterEditorSheet>
    with WidgetsBindingObserver {
  /// Highlighting and replacing every hit in a long chapter costs more than it
  /// helps, so the panel works on a bounded window and says when it is capped.
  static const _maxFindMatches = 500;

  late final TextEditingController _titleController;
  late final _FindHighlightController _contentController;
  final _findController = TextEditingController();
  final _replaceController = TextEditingController();
  final _findFocus = FocusNode();
  final _contentScrollController = ScrollController();
  final _contentFieldKey = GlobalKey();
  bool _saving = false;
  bool _allowPop = false;
  String? _errorMessage;
  String? _notice;
  bool _findVisible = false;
  late String _lastContent;
  List<TextRange> _matches = const <TextRange>[];
  int _matchIndex = -1;
  bool _anchorApplied = false;
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
    _contentController = _FindHighlightController(text: widget.initialContent);
    _lastContent = widget.initialContent;
    _titleController.addListener(_handleTitleChanged);
    _contentController.addListener(_handleContentChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyInitialAnchor());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _barRestoreTimer?.cancel();
    _titleController
      ..removeListener(_handleTitleChanged)
      ..dispose();
    _contentController
      ..removeListener(_handleContentChanged)
      ..dispose();
    _findController.dispose();
    _replaceController.dispose();
    _findFocus.dispose();
    _contentScrollController.dispose();
    super.dispose();
  }

  // ── Reading anchor ────────────────────────────────────

  /// Walks down to the body field's [RenderEditable] so caret geometry can be
  /// read straight from the laid-out text instead of being re-measured.
  RenderEditable? _findRenderEditable(RenderObject? node) {
    if (node == null) return null;
    if (node is RenderEditable) return node;
    RenderEditable? found;
    node.visitChildren((child) {
      found ??= _findRenderEditable(child);
    });
    return found;
  }

  /// Pins the line holding [characterOffset] to the top of the body field.
  /// The caret rect starts at the line box and is measured against the field's
  /// current scroll, so the result always lands on a whole line instead of
  /// leaving a sliced one at the top edge.
  bool _scrollContentTo(int characterOffset) {
    if (!mounted || !_contentScrollController.hasClients) return false;
    final position = _contentScrollController.position;
    if (!position.hasContentDimensions) return false;
    final editable = _findRenderEditable(
      _contentFieldKey.currentContext?.findRenderObject(),
    );
    if (editable == null || !editable.hasSize) return false;
    final safe = characterOffset.clamp(0, _contentController.text.length);
    final caret = editable.getLocalRectForCaret(TextPosition(offset: safe));
    _contentScrollController.jumpTo(
      (position.pixels + caret.top).clamp(0.0, position.maxScrollExtent),
    );
    return true;
  }

  void _applyInitialAnchor([int attempt = 0]) {
    if (!mounted || _anchorApplied) return;
    final anchor = widget.initialAnchorOffset;
    if (anchor == null || anchor <= 0 || _scrollContentTo(anchor)) {
      _anchorApplied = true;
      return;
    }
    if (attempt >= 4) {
      _anchorApplied = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyInitialAnchor(attempt + 1),
    );
  }

  // ── Find and replace ──────────────────────────────────

  List<TextRange> _computeMatches(String query, String text) {
    if (query.isEmpty || text.isEmpty) return const <TextRange>[];
    var haystack = text;
    var needle = query;
    final foldedHaystack = text.toLowerCase();
    final foldedNeedle = query.toLowerCase();
    // Case folding grows a few characters. Fall back to an exact match there so
    // the ranges keep addressing the original text.
    if (foldedHaystack.length == text.length &&
        foldedNeedle.length == query.length) {
      haystack = foldedHaystack;
      needle = foldedNeedle;
    }
    final found = <TextRange>[];
    var start = 0;
    while (found.length < _maxFindMatches) {
      final at = haystack.indexOf(needle, start);
      if (at < 0) break;
      found.add(TextRange(start: at, end: at + needle.length));
      start = at + needle.length;
    }
    return found;
  }

  void _handleTitleChanged() {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _notice = null;
    });
  }

  void _handleContentChanged() {
    if (!mounted) return;
    // The controller also reports selection moves. Only a real edit should
    // clear the footer message or rebuild the match list.
    final text = _contentController.text;
    if (text == _lastContent) return;
    _lastContent = text;
    final matches = _findVisible
        ? _computeMatches(_findController.text, _contentController.text)
        : const <TextRange>[];
    setState(() {
      _errorMessage = null;
      _notice = null;
      _matches = matches;
      _matchIndex = matches.isEmpty
          ? -1
          : _matchIndex.clamp(0, matches.length - 1);
    });
  }

  void _handleQueryChanged() {
    if (!mounted) return;
    final matches = _computeMatches(
      _findController.text,
      _contentController.text,
    );
    setState(() {
      _notice = null;
      _matches = matches;
      _matchIndex = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) _revealMatch(0);
  }

  void _revealMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final range = _matches[index];
    _contentController.selection = TextSelection(
      baseOffset: range.start,
      extentOffset: range.end,
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollContentTo(range.start),
    );
  }

  void _moveMatch(int delta) {
    if (_matches.isEmpty) return;
    final next = (_matchIndex + delta) % _matches.length;
    final index = next < 0 ? next + _matches.length : next;
    setState(() => _matchIndex = index);
    _revealMatch(index);
  }

  void _toggleFind() {
    final opening = !_findVisible;
    setState(() {
      _findVisible = opening;
      if (!opening) {
        _matches = const <TextRange>[];
        _matchIndex = -1;
        _notice = null;
      }
    });
    if (!opening) {
      _findFocus.unfocus();
      return;
    }
    if (_findController.text.isNotEmpty) _handleQueryChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _findVisible) _findFocus.requestFocus();
    });
  }

  void _replaceCurrent() {
    if (_saving) return;
    if (_matchIndex < 0 || _matchIndex >= _matches.length) return;
    final range = _matches[_matchIndex];
    final text = _contentController.text;
    if (range.end > text.length) return;
    final replacement = _replaceController.text;
    final target = _matchIndex;
    // Writing the value re-runs the content listener, which refreshes _matches
    // against the new text before the next statement reads it back.
    _contentController.value = TextEditingValue(
      text: text.replaceRange(range.start, range.end, replacement),
      selection: TextSelection.collapsed(
        offset: range.start + replacement.length,
      ),
    );
    final index = _matches.isEmpty
        ? -1
        : math.min(target, _matches.length - 1);
    setState(() {
      _matchIndex = index;
      _notice = '已替换 1 处';
    });
    if (index >= 0) _revealMatch(index);
  }

  void _replaceAll() {
    if (_saving || _matches.isEmpty) return;
    final text = _contentController.text;
    final replacement = _replaceController.text;
    final capped = _matches.length >= _maxFindMatches;
    final buffer = StringBuffer();
    var cursor = 0;
    var count = 0;
    for (final range in _matches) {
      if (range.start < cursor || range.end > text.length) break;
      buffer
        ..write(text.substring(cursor, range.start))
        ..write(replacement);
      cursor = range.end;
      count++;
    }
    buffer.write(text.substring(cursor));
    final restoreScroll = _contentScrollController.hasClients
        ? _contentScrollController.offset
        : null;
    _contentController.value = TextEditingValue(
      text: buffer.toString(),
      selection: const TextSelection.collapsed(offset: 0),
    );
    setState(() {
      _matchIndex = _matches.isEmpty ? -1 : 0;
      _notice = capped ? '已替换 $count 处，可再次替换剩余匹配' : '已替换 $count 处';
    });
    if (restoreScroll == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_contentScrollController.hasClients) return;
      _contentScrollController.jumpTo(
        restoreScroll.clamp(
          0.0,
          _contentScrollController.position.maxScrollExtent,
        ),
      );
    });
  }

  // ── Saving ────────────────────────────────────────────

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
      _notice = null;
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
        _errorMessage = switch (error) {
          BookEditConflict() => error.message.toString(),
          FormatException() => error.message.toString(),
          _ => '保存失败，请检查存储空间后重试',
        };
      });
    }
  }

  // ── Layout ────────────────────────────────────────────

  InputBorder _fieldBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: color, width: width),
      );

  InputDecoration _panelFieldDecoration(
    ReaderThemeColors colors, {
    required String hint,
    required IconData icon,
  }) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: colors.secondary, fontSize: 13),
    prefixIcon: Icon(icon, size: 18, color: colors.secondary),
    prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    filled: true,
    fillColor: colors.background,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.sm,
      vertical: 10,
    ),
    border: _fieldBorder(colors.border),
    enabledBorder: _fieldBorder(colors.border),
    focusedBorder: _fieldBorder(colors.accent, width: 1.5),
  );

  Widget _buildHeader(ReaderThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _saving ? null : _requestClose,
            tooltip: '关闭编辑器',
            icon: Icon(Icons.close_rounded, color: colors.secondary),
          ),
          Expanded(
            child: TextField(
              controller: _titleController,
              enabled: !_saving,
              maxLength: 200,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
              decoration: InputDecoration(
                hintText: '章节标题',
                hintStyle: TextStyle(
                  color: colors.secondary,
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
                counterText: '',
                filled: true,
                fillColor: colors.headerBg,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: 10,
                ),
                border: _fieldBorder(colors.border),
                enabledBorder: _fieldBorder(colors.border),
                focusedBorder: _fieldBorder(colors.accent, width: 1.5),
              ),
            ),
          ),
          IconButton(
            onPressed: _saving ? null : _toggleFind,
            tooltip: _findVisible ? '收起查找替换' : '查找替换',
            icon: Icon(
              _findVisible
                  ? Icons.search_off_rounded
                  : Icons.find_replace_rounded,
              color: _findVisible ? colors.accent : colors.secondary,
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
    );
  }

  Widget _buildFindPanel(ReaderThemeColors colors) {
    final total = _matches.length;
    final counter = total == 0
        ? (_findController.text.isEmpty ? '' : '无匹配')
        : '${_matchIndex + 1}/$total${total >= _maxFindMatches ? '+' : ''}';
    return Container(
      color: colors.headerBg,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _findController,
                  focusNode: _findFocus,
                  enabled: !_saving,
                  onChanged: (_) => _handleQueryChanged(),
                  onSubmitted: (_) => _moveMatch(1),
                  textInputAction: TextInputAction.search,
                  style: TextStyle(color: colors.text, fontSize: 14),
                  decoration: _panelFieldDecoration(
                    colors,
                    hint: '查找当前章内容',
                    icon: Icons.search_rounded,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: 56,
                child: Text(
                  counter,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.secondary, fontSize: 12),
                ),
              ),
              IconButton(
                onPressed: total == 0 ? null : () => _moveMatch(-1),
                tooltip: '上一个匹配',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: colors.secondary,
                ),
              ),
              IconButton(
                onPressed: total == 0 ? null : () => _moveMatch(1),
                tooltip: '下一个匹配',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: colors.secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _replaceController,
                  enabled: !_saving,
                  style: TextStyle(color: colors.text, fontSize: 14),
                  decoration: _panelFieldDecoration(
                    colors,
                    hint: '替换为（留空即删除）',
                    icon: Icons.swap_horiz_rounded,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              TextButton(
                onPressed: total == 0 ? null : _replaceCurrent,
                child: const Text('替换'),
              ),
              TextButton(
                onPressed: total == 0 ? null : _replaceAll,
                child: const Text('全部替换'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    _contentController.applyHighlights(
      matches: _findVisible ? _matches : const <TextRange>[],
      activeIndex: _matchIndex,
      matchColor: colors.accent.withValues(alpha: 0.16),
      activeColor: colors.accent.withValues(alpha: 0.38),
    );
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final editor = PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestClose();
      },
      child: Material(
        color: colors.background,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(colors),
              Divider(height: 1, color: colors.border),
              if (_findVisible) ...[
                _buildFindPanel(colors),
                Divider(height: 1, color: colors.border),
              ],
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
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: TextField(
                    key: _contentFieldKey,
                    controller: _contentController,
                    scrollController: _contentScrollController,
                    enabled: !_saving,
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
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.md + bottomInset,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _errorMessage ?? _notice ?? '修改不会回写原始书籍文件',
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
