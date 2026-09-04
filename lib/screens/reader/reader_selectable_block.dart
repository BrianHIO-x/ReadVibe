import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show Selectable, SelectionRegistrar, SelectionStatus;

/// Retains only selected lazy content, including its off-screen endpoints.
/// Clearing or shrinking the selection releases it back to the sliver cache.
class ReaderSelectableBlock extends StatefulWidget {
  const ReaderSelectableBlock({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderSelectableBlock> createState() => _ReaderSelectableBlockState();
}

class _ReaderSelectableBlockState extends State<ReaderSelectableBlock>
    with AutomaticKeepAliveClientMixin
    implements SelectionRegistrar {
  final _selectables = <Selectable>{};
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
    final selected = _selectables.any(
      (selectable) => selectable.value.status != SelectionStatus.none,
    );
    if (selected == _selected) return;
    _selected = selected;
    updateKeepAlive();
  }

  @override
  bool get wantKeepAlive => _selected;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SelectionRegistrarScope(registrar: this, child: widget.child);
  }

  @override
  void dispose() {
    _disposing = true;
    for (final selectable in _selectables) {
      selectable.removeListener(_selectionChanged);
      _parent?.remove(selectable);
    }
    _selectables.clear();
    super.dispose();
  }
}
