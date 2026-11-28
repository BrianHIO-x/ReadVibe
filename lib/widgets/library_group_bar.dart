import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_choice_pill.dart';
import 'app_dialog.dart';
import 'app_sheet.dart';
import 'app_toast.dart';

/// Horizontal chip strip for filtering the active shelf by custom group.
class LibraryGroupBar extends StatelessWidget {
  const LibraryGroupBar({
    super.key,
    required this.colors,
    required this.groups,
    required this.selectedGroup,
    required this.onSelected,
    required this.onManageGroups,
    this.onClose,
  });

  final ReaderThemeColors colors;
  final List<String> groups;
  final String? selectedGroup;
  final ValueChanged<String?> onSelected;
  final VoidCallback onManageGroups;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final barHeight = math.max(36.0, scaler.scale(13.0) + 22.0);
    return SizedBox(
      height: barHeight,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        children: [
          _GroupChip(
            label: '全部',
            selected: selectedGroup == null,
            colors: colors,
            onTap: () => onSelected(null),
          ),
          for (final group in groups) ...[
            const SizedBox(width: AppSpacing.xs),
            _GroupChip(
              label: group,
              selected: selectedGroup == group,
              colors: colors,
              onTap: () => onSelected(selectedGroup == group ? null : group),
            ),
          ],
          const SizedBox(width: AppSpacing.xs),
          _GroupActionChip(
            icon: Icons.tune_rounded,
            label: groups.isEmpty ? '新建分组' : '管理分组',
            colors: colors,
            onTap: onManageGroups,
          ),
          if (onClose != null) ...[
            const SizedBox(width: AppSpacing.xs),
            _GroupActionChip(
              icon: Icons.close_rounded,
              label: '收起',
              colors: colors,
              onTap: onClose!,
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final ReaderThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppChoicePill(
        label: label,
        selected: selected,
        colors: colors,
        compact: true,
        pillShape: true,
        onTap: onTap,
      ),
    );
  }
}

class _GroupActionChip extends StatelessWidget {
  const _GroupActionChip({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final ReaderThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppChoicePill(
        icon: icon,
        label: label,
        selected: false,
        colors: colors,
        compact: true,
        pillShape: true,
        onTap: onTap,
      ),
    );
  }
}

Future<void> showShelfGroupManagerSheet(
  BuildContext context, {
  required LibraryRepository storage,
  required ReaderThemeColors colors,
  required bool private,
  required Future<void> Function() onChanged,
}) {
  return showAppSheet<void>(
    context: context,
    colors: colors,
    builder: (sheetContext) => _ShelfGroupManagerSheet(
      storage: storage,
      colors: colors,
      private: private,
      onChanged: onChanged,
    ),
  );
}

class _ShelfGroupManagerSheet extends StatefulWidget {
  const _ShelfGroupManagerSheet({
    required this.storage,
    required this.colors,
    required this.private,
    required this.onChanged,
  });

  final LibraryRepository storage;
  final ReaderThemeColors colors;
  final bool private;
  final Future<void> Function() onChanged;

  @override
  State<_ShelfGroupManagerSheet> createState() =>
      _ShelfGroupManagerSheetState();
}

class _ShelfGroupManagerSheetState extends State<_ShelfGroupManagerSheet> {
  final _newGroupController = TextEditingController();
  List<String> _groups = const <String>[];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _newGroupController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final groups = await widget.storage.getShelfGroups(private: widget.private);
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  Future<void> _addGroup() async {
    if (_busy) return;
    final normalized = normalizeBookGroups(<String>[
      _newGroupController.text,
    ], maxGroups: 1);
    if (normalized.isEmpty) {
      AppToast.error(context, '分组名称不能为空', colors: widget.colors);
      return;
    }
    final name = normalized.first;
    if (_groups.contains(name)) {
      AppToast.error(context, '分组「$name」已存在', colors: widget.colors);
      return;
    }
    if (_groups.length >= 64) {
      AppToast.error(context, '最多支持 64 个自定义分组', colors: widget.colors);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.storage.saveShelfGroups(<String>[
        ..._groups,
        name,
      ], private: widget.private);
      _newGroupController.clear();
      await _reload();
      await widget.onChanged();
    } on Object {
      if (mounted) {
        AppToast.error(context, '添加分组失败，请重试', colors: widget.colors);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameGroup(String oldName) async {
    if (_busy) return;
    final controller = TextEditingController(text: oldName);
    final newName = await showAppDialog<String>(
      context: context,
      colors: widget.colors,
      builder: (dialogContext) => AppDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(labelText: '分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.storage.renameShelfGroup(
        oldName: oldName,
        newName: newName,
        private: widget.private,
      );
      await _reload();
      await widget.onChanged();
    } on FormatException catch (error) {
      if (mounted) {
        AppToast.error(context, error.message, colors: widget.colors);
      }
    } on Object {
      if (mounted) {
        AppToast.error(context, '重命名失败，请重试', colors: widget.colors);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteGroup(String name) async {
    if (_busy) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      colors: widget.colors,
      builder: (dialogContext) => AppDialog(
        title: const Text('删除分组'),
        content: Text('确定删除分组「$name」吗？书籍本身不会被删除。'),
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
    setState(() => _busy = true);
    try {
      await widget.storage.deleteShelfGroup(name, private: widget.private);
      await _reload();
      await widget.onChanged();
    } on Object {
      if (mounted) {
        AppToast.error(context, '删除分组失败，请重试', colors: widget.colors);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final viewInsetsBottom = mq.viewInsets.bottom;
    final availableHeight = math.max(
      240.0,
      math.min(
        mq.size.height * 0.72,
        mq.size.height - mq.viewPadding.top - viewInsetsBottom - 16,
      ),
    );
    final bottomPad = AppSpacing.lg + (viewInsetsBottom > 0 ? 0.0 : mq.padding.bottom);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: availableHeight),
        child: AppSheetSurface(
          colors: widget.colors,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSheetHeader(
                title: widget.private ? '管理隐私分组' : '管理书架分组',
                subtitle: '普通书架与隐私书架的分组相互隔离，每本书最多加入 12 个分组',
              ),
              Flexible(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    0,
                    AppSpacing.xl,
                    bottomPad,
                  ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newGroupController,
                            maxLength: 24,
                            decoration: const InputDecoration(
                              hintText: '输入新分组名称',
                              counterText: '',
                              isDense: true,
                            ),
                            onSubmitted: (_) => _addGroup(),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        FilledButton(
                          onPressed: _busy ? null : _addGroup,
                          child: const Text('新建'),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (_loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(AppSpacing.xl),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (_groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xl,
                        ),
                        child: Center(
                          child: Text(
                            '还没有自定义分组，可以在上方输入名称创建',
                            style: TextStyle(
                              color: widget.colors.secondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _groups.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: widget.colors.border),
                          itemBuilder: (context, index) {
                            final name = _groups[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                name,
                                style: TextStyle(
                                  color: widget.colors.text,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '重命名',
                                    onPressed: _busy
                                        ? null
                                        : () => _renameGroup(name),
                                    icon: Icon(
                                      Icons.edit_outlined,
                                      color: widget.colors.secondary,
                                      size: 20,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '删除分组',
                                    onPressed: _busy
                                        ? null
                                        : () => _deleteGroup(name),
                                    icon: Icon(
                                      Icons.delete_outline_rounded,
                                      color: widget.colors.secondary,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

Future<bool> showAssignBookGroupsSheet(
  BuildContext context, {
  required LibraryRepository storage,
  required ReaderThemeColors colors,
  required bool private,
  required List<Book> targets,
  required Future<void> Function() onApplied,
}) async {
  if (targets.isEmpty) return false;
  final saved = await showAppSheet<bool>(
    context: context,
    colors: colors,
    builder: (_) => _AssignBookGroupsSheet(
      storage: storage,
      colors: colors,
      private: private,
      targets: targets,
      onApplied: onApplied,
    ),
  );
  return saved == true;
}

class _AssignBookGroupsSheet extends StatefulWidget {
  const _AssignBookGroupsSheet({
    required this.storage,
    required this.colors,
    required this.private,
    required this.targets,
    required this.onApplied,
  });

  final LibraryRepository storage;
  final ReaderThemeColors colors;
  final bool private;
  final List<Book> targets;
  final Future<void> Function() onApplied;

  @override
  State<_AssignBookGroupsSheet> createState() => _AssignBookGroupsSheetState();
}

class _AssignBookGroupsSheetState extends State<_AssignBookGroupsSheet> {
  final _newGroupController = TextEditingController();
  final List<String> _groups = <String>[];
  final Map<String, bool?> _checks = <String, bool?>{};
  bool _loading = true;
  bool _saving = false;

  bool get _isBatch => widget.targets.length > 1;

  @override
  void initState() {
    super.initState();
    _initGroups();
  }

  @override
  void dispose() {
    _newGroupController.dispose();
    super.dispose();
  }

  Future<void> _initGroups() async {
    final catalog = await widget.storage.getShelfGroups(
      private: widget.private,
    );
    final merged = normalizeBookGroups(<String>[
      ...catalog,
      for (final book in widget.targets) ...book.groups,
    ], maxGroups: 64);

    if (!mounted) return;
    setState(() {
      _groups
        ..clear()
        ..addAll(merged);
      for (final group in _groups) {
        final members = widget.targets
            .where((book) => book.groups.contains(group))
            .length;
        if (members == widget.targets.length) {
          _checks[group] = true;
        } else if (members == 0) {
          _checks[group] = false;
        } else {
          _checks[group] = null;
        }
      }
      _loading = false;
    });
  }

  void _addInlineGroup() {
    final normalized = normalizeBookGroups(<String>[
      _newGroupController.text,
    ], maxGroups: 1);
    if (normalized.isEmpty) {
      AppToast.error(context, '分组名称不能为空', colors: widget.colors);
      return;
    }
    final name = normalized.first;
    _newGroupController.clear();
    setState(() {
      if (!_groups.contains(name)) {
        if (_groups.length >= 64) {
          AppToast.error(context, '最多支持 64 个自定义分组', colors: widget.colors);
          return;
        }
        _groups.add(name);
      }
      _checks[name] = true;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final ids = <String>[for (final book in widget.targets) book.id];
      if (!_isBatch) {
        final selected = <String>[
          for (final group in _groups)
            if (_checks[group] == true) group,
        ];
        await widget.storage.setBooksGroups(ids, selected);
      } else {
        final add = <String>[
          for (final group in _groups)
            if (_checks[group] == true) group,
        ];
        final remove = <String>[
          for (final group in _groups)
            if (_checks[group] == false) group,
        ];
        await widget.storage.updateBooksGroups(ids, add: add, remove: remove);
      }
      await widget.onApplied();
      if (mounted) Navigator.pop(context, true);
    } on Object {
      if (mounted) {
        AppToast.error(context, '保存分组失败，请重试', colors: widget.colors);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final viewInsetsBottom = mq.viewInsets.bottom;
    final availableHeight = math.max(
      240.0,
      math.min(
        mq.size.height * 0.72,
        mq.size.height - mq.viewPadding.top - viewInsetsBottom - 16,
      ),
    );
    final bottomPad = AppSpacing.lg + (viewInsetsBottom > 0 ? 0.0 : mq.padding.bottom);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: availableHeight),
        child: AppSheetSurface(
          colors: widget.colors,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSheetHeader(
                title: _isBatch
                    ? '为已选 ${widget.targets.length} 本书设置分组'
                    : '设置分组 · ${widget.targets.first.title}',
                subtitle: _isBatch ? '半选状态将保留每本书原有的分组归属' : null,
              ),
              Flexible(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    0,
                    AppSpacing.xl,
                    bottomPad,
                  ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newGroupController,
                            maxLength: 24,
                            decoration: const InputDecoration(
                              hintText: '输入新分组名称',
                              counterText: '',
                              isDense: true,
                            ),
                            onSubmitted: (_) => _addInlineGroup(),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        OutlinedButton(
                          onPressed: _saving ? null : _addInlineGroup,
                          child: const Text('添加'),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (_loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(AppSpacing.xl),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (_groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xl,
                        ),
                        child: Center(
                          child: Text(
                            '暂无分组，先在上方添加一个分组吧',
                            style: TextStyle(
                              color: widget.colors.secondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final group in _groups)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                tristate: _isBatch,
                                value: _checks[group],
                                activeColor: widget.colors.accent,
                                title: Text(
                                  group,
                                  style: TextStyle(color: widget.colors.text),
                                ),
                                onChanged: _saving
                                    ? null
                                    : (next) {
                                        setState(() {
                                          if (!_isBatch) {
                                            _checks[group] = next ?? false;
                                          } else {
                                            final cur = _checks[group];
                                            _checks[group] = cur == null
                                                ? true
                                                : cur
                                                ? false
                                                : true;
                                          }
                                        });
                                      },
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? '保存中…' : '保存'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
