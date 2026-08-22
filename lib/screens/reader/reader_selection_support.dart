part of '../reader_screen.dart';

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
        AppToast.error(context, translate ? '所选 AI 应用无法接收翻译内容' : '所选浏览器无法打开搜索');
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to launch a system text action: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        AppToast.error(context, '无法打开所选外部应用');
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
      AppToast.info(
        context,
        action == SystemTextActionType.translate
            ? '没有检测到可接收文字的 AI 应用'
            : '没有可用的浏览器',
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
