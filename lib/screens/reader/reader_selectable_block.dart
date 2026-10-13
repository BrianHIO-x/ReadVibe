import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        PipelineOwner,
        RenderProxyBox,
        Selectable,
        SelectionRegistrar,
        SelectionStatus;

/// Retains only selected lazy content, including its off-screen endpoints.
/// Clearing or shrinking the selection releases it back to the sliver cache.
///
/// Also paints the selection highlight in place of the paragraphs' own.
class ReaderSelectableBlock extends StatefulWidget {
  const ReaderSelectableBlock({
    super.key,
    this.retainSelection = true,
    required this.child,
  });

  /// Whether selected content survives being scrolled out of the cache.
  /// Pages that never scroll only need the highlight.
  final bool retainSelection;
  final Widget child;

  @override
  State<ReaderSelectableBlock> createState() => _ReaderSelectableBlockState();
}

class _ReaderSelectableBlockState extends State<ReaderSelectableBlock>
    with AutomaticKeepAliveClientMixin
    implements SelectionRegistrar {
  final _selectables = <Selectable>{};
  final _selectionRevision = ValueNotifier<int>(0);
  SelectionRegistrar? _parent;
  bool _selected = false;
  bool _disposing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = SelectionContainer.maybeOf(context);
    if (identical(parent, _parent)) return;
    for (final selectable in _selectables) {
      _parent?.remove(selectable);
      parent?.add(selectable);
    }
    _parent = parent;
  }

  // Observe registration without introducing an additional selectable boundary.
  // The scrollable still receives the original paragraph and owns its anchor.
  @override
  void add(Selectable selectable) {
    if (_disposing || !_selectables.add(selectable)) return;
    selectable.addListener(_selectionChanged);
    _parent?.add(selectable);
    _selectionChanged();
  }

  @override
  void remove(Selectable selectable) {
    if (!_selectables.remove(selectable)) return;
    selectable.removeListener(_selectionChanged);
    _parent?.remove(selectable);
    _selectionChanged();
  }

  void _selectionChanged() {
    if (_disposing || !mounted) return;
    _selectionRevision.value++;
    final selected = _selectables.any(
      (selectable) => selectable.value.status != SelectionStatus.none,
    );
    if (selected == _selected) return;
    _selected = selected;
    updateKeepAlive();
  }

  @override
  void didUpdateWidget(covariant ReaderSelectableBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retainSelection != widget.retainSelection) updateKeepAlive();
  }

  @override
  bool get wantKeepAlive => widget.retainSelection && _selected;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _SelectionBands(
      selectables: _selectables,
      color:
          DefaultSelectionStyle.of(context).selectionColor ??
          DefaultSelectionStyle.defaultColor,
      revision: _selectionRevision,
      // The paragraphs' own highlight follows each font run's height, so
      // punctuation from a fallback font dips below the text around it.
      child: DefaultSelectionStyle.merge(
        selectionColor: const Color(0x00000000),
        child: SelectionRegistrarScope(registrar: this, child: widget.child),
      ),
    );
  }

  @override
  void dispose() {
    _disposing = true;
    for (final selectable in _selectables) {
      selectable.removeListener(_selectionChanged);
      _parent?.remove(selectable);
    }
    _selectables.clear();
    _selectionRevision.dispose();
    super.dispose();
  }
}

class _SelectionBands extends SingleChildRenderObjectWidget {
  const _SelectionBands({
    required this.selectables,
    required this.color,
    required this.revision,
    super.child,
  });

  final Set<Selectable> selectables;
  final Color color;
  final Listenable revision;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSelectionBands(
      selectables: selectables,
      color: color,
      revision: revision,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSelectionBands renderObject,
  ) {
    renderObject
      ..selectables = selectables
      ..color = color
      ..revision = revision;
  }
}

/// Paints one band per selected line beneath the text. Each band spans the
/// line's selected runs and takes the height of its widest run, which is the
/// body font rather than a stray punctuation fallback.
class _RenderSelectionBands extends RenderProxyBox {
  _RenderSelectionBands({
    required this._selectables,
    required this._color,
    required this._revision,
  });

  Set<Selectable> _selectables;
  set selectables(Set<Selectable> value) {
    if (identical(value, _selectables)) return;
    _selectables = value;
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  Listenable _revision;
  set revision(Listenable value) {
    if (identical(value, _revision)) return;
    if (attached) {
      _revision.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _revision = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _revision.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _revision.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    Paint? paint;
    for (final selectable in _selectables) {
      final geometry = selectable.value;
      if (geometry.status == SelectionStatus.none ||
          geometry.selectionRects.isEmpty) {
        continue;
      }
      final transform = selectable.getTransformTo(this);
      for (final band in _lineBands(geometry.selectionRects)) {
        final rect = MatrixUtils.transformRect(transform, band);
        if (!rect.isFinite || rect.isEmpty) continue;
        context.canvas.drawRect(
          rect.shift(offset),
          paint ??= Paint()..color = _color,
        );
      }
    }
    super.paint(context, offset);
  }

  static List<Rect> _lineBands(List<Rect> rects) {
    final sorted = [...rects]
      ..sort((a, b) => a.center.dy.compareTo(b.center.dy));
    final bands = <Rect>[];
    Rect? widest;
    var left = 0.0;
    var right = 0.0;
    var bottom = 0.0;
    void flush() {
      final line = widest;
      if (line != null) {
        bands.add(Rect.fromLTRB(left, line.top, right, line.bottom));
      }
    }

    for (final rect in sorted) {
      final line = widest;
      if (line != null && rect.center.dy < bottom) {
        if (rect.left < left) left = rect.left;
        if (rect.right > right) right = rect.right;
        if (rect.bottom > bottom) bottom = rect.bottom;
        if (rect.width > line.width) widest = rect;
        continue;
      }
      flush();
      widest = rect;
      left = rect.left;
      right = rect.right;
      bottom = rect.bottom;
    }
    flush();
    return bands;
  }
}
