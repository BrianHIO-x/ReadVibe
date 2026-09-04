import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Extends a selection while its dragged edge stays inside a viewport edge band.
/// The child must be a single vertical Scrollable inside a SelectionArea.
/// Flutter still owns character selection and anchoring across lazy children.
class ReaderSelectionEdgeScroller extends StatefulWidget {
  const ReaderSelectionEdgeScroller({
    super.key,
    required this.controller,
    required this.selectionActive,
    required this.selectionBlocked,
    required this.onSelectionChanged,
    required this.child,
    this.enabled = true,
  });

  final ScrollController controller;
  final ValueListenable<bool> selectionActive;
  final ValueListenable<bool> selectionBlocked;
  final ValueChanged<SelectedContent?> onSelectionChanged;
  final Widget child;
  final bool enabled;

  @override
  State<ReaderSelectionEdgeScroller> createState() =>
      _ReaderSelectionEdgeScrollerState();
}

class _ReaderSelectionEdgeScrollerState
    extends State<ReaderSelectionEdgeScroller>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _edgeBand = 56.0;
  static const _maxSpeed = 420.0;
  late final Ticker _ticker = createTicker(_tick);
  late final _EdgeSelectionDelegate _delegate = _EdgeSelectionDelegate(
    onEdge: _handleEdge,
    onClear: _clearDrag,
    mapEdge: _clampEdge,
  );
  ValueListenable<SelectableRegionSelectionStatus>? _selectionStatus;
  SelectionEdgeUpdateEvent? _dragEdge;
  Duration? _lastTick;
  bool _selectionUpdateScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.selectionActive.addListener(_syncTicker);
    widget.selectionBlocked.addListener(_syncTicker);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final status = SelectableRegionSelectionStatusScope.maybeOf(context);
    if (!identical(status, _selectionStatus)) {
      _selectionStatus?.removeListener(_handleStatus);
      _selectionStatus = status;
      status?.addListener(_handleStatus);
      _clearDrag();
    }
  }

  @override
  void didUpdateWidget(covariant ReaderSelectionEdgeScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selectionActive, widget.selectionActive)) {
      oldWidget.selectionActive.removeListener(_syncTicker);
      widget.selectionActive.addListener(_syncTicker);
    }
    if (!identical(oldWidget.selectionBlocked, widget.selectionBlocked)) {
      oldWidget.selectionBlocked.removeListener(_syncTicker);
      widget.selectionBlocked.addListener(_syncTicker);
    }
    if (!identical(oldWidget.controller, widget.controller) ||
        !widget.enabled) {
      _clearDrag();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _clearDrag();
  }

  bool get _canScroll =>
      widget.enabled &&
      widget.selectionActive.value &&
      !widget.selectionBlocked.value &&
      _selectionStatus?.value == SelectableRegionSelectionStatus.changing &&
      widget.controller.positions.length == 1 &&
      widget.controller.position.hasContentDimensions;

  Rect? get _viewport {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // Keep events inside the real Scrollable so its outside-viewport auto scroller
  // cannot race our inside-edge scroller. Preserve the other selection endpoint.
  SelectionEdgeUpdateEvent _clampEdge(SelectionEdgeUpdateEvent event) {
    final rect = _viewport;
    if (rect == null || rect.width <= 2 || rect.height <= 2) return event;
    final point = Offset(
      event.globalPosition.dx.clamp(rect.left + 1, rect.right - 1),
      event.globalPosition.dy.clamp(rect.top + 1, rect.bottom - 1),
    );
    return event.type == SelectionEventType.startEdgeUpdate
        ? SelectionEdgeUpdateEvent.forStart(
            globalPosition: point,
            granularity: event.granularity,
          )
        : SelectionEdgeUpdateEvent.forEnd(
            globalPosition: point,
            granularity: event.granularity,
          );
  }

  void _handleEdge(SelectionEdgeUpdateEvent event) {
    _dragEdge = event;
    _syncTicker();
  }

  void _handleStatus() {
    if (_selectionStatus?.value == SelectableRegionSelectionStatus.finalized) {
      _clearDrag();
      // Materialize the selected text only after the gesture is finalized;
      // rebuilding an ever-growing string on every scroll frame stalls large
      // selections and is unnecessary for updating the selection geometry.
      widget.onSelectionChanged(_delegate.getSelectedContent());
    } else {
      _syncTicker();
    }
  }

  double get _velocity {
    final rect = _viewport;
    final edge = _dragEdge;
    if (rect == null || edge == null || rect.height <= 2) return 0;
    final media = MediaQuery.of(context);
    final top = math.max(rect.top, media.viewPadding.top);
    final bottom = math.min(
      rect.bottom,
      media.size.height - media.viewPadding.bottom,
    );
    final band = math.min(_edgeBand, (bottom - top) / 3);
    if (band <= 0) return 0;
    final y = edge.globalPosition.dy;
    if (y < top + band) {
      return -_maxSpeed * ((top + band - y) / band).clamp(0.0, 1.0);
    }
    if (y > bottom - band) {
      return _maxSpeed * ((y - bottom + band) / band).clamp(0.0, 1.0);
    }
    return 0;
  }

  void _syncTicker() {
    if (!_canScroll || _dragEdge == null || _velocity == 0) {
      _stopTicker();
    } else if (!_ticker.isActive) {
      _lastTick = null;
      _ticker.start();
    }
  }

  void _stopTicker() {
    _ticker.stop();
    _lastTick = null;
  }

  void _clearDrag() {
    _dragEdge = null;
    _stopTicker();
  }

  void _tick(Duration elapsed) {
    if (!_canScroll || _dragEdge == null) {
      _clearDrag();
      return;
    }
    final previous = _lastTick;
    _lastTick = elapsed;
    if (previous == null) return;
    final seconds = ((elapsed - previous).inMicroseconds / 1000000).clamp(
      0.0,
      0.05,
    );
    final position = widget.controller.position;
    final target = (position.pixels + _velocity * seconds).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.01) {
      _stopTicker();
      return;
    }
    position.jumpTo(target);
    // Lazy paragraphs/chapters must finish layout before resolving the dragged
    // endpoint again. Replaying only that endpoint preserves the fixed anchor.
    if (_selectionUpdateScheduled) return;
    _selectionUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionUpdateScheduled = false;
      if (!mounted || !_canScroll || _dragEdge == null) return;
      _delegate.replayEdge(_dragEdge!);
    });
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _selectionStatus?.removeListener(_handleStatus);
    widget.selectionActive.removeListener(_syncTicker);
    widget.selectionBlocked.removeListener(_syncTicker);
    _ticker.dispose();
    _delegate.dispose();
    super.dispose();
  }
}

class _EdgeSelectionDelegate extends StaticSelectionContainerDelegate {
  _EdgeSelectionDelegate({
    required this.onEdge,
    required this.onClear,
    required this.mapEdge,
  });

  final ValueChanged<SelectionEdgeUpdateEvent> onEdge;
  final VoidCallback onClear;
  final SelectionEdgeUpdateEvent Function(SelectionEdgeUpdateEvent) mapEdge;

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (event is ClearSelectionEvent) onClear();
    if (event is SelectionEdgeUpdateEvent) {
      onEdge(event);
      return super.dispatchSelectionEvent(mapEdge(event));
    }
    return super.dispatchSelectionEvent(event);
  }

  void replayEdge(SelectionEdgeUpdateEvent event) {
    super.dispatchSelectionEvent(mapEdge(event));
  }
}
