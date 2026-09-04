import 'package:flutter/material.dart';
import '../models/library_filter.dart';
import '../theme/app_theme.dart';
import 'app_popup_menu.dart';

class LibraryFilterButton extends StatelessWidget {
  const LibraryFilterButton({
    super.key,
    required this.filter,
    required this.colors,
    required this.onSelected,
  });
  final ShelfFilter filter;
  final ReaderThemeColors colors;
  final ValueChanged<ShelfFilter> onSelected;

  @override
  Widget build(BuildContext context) => AppPopupMenuButton<ShelfFilter>(
    colors: colors,
    tooltip: '筛选书架',
    onSelected: onSelected,
    icon: Icon(
      filter == ShelfFilter.all
          ? Icons.filter_list_rounded
          : Icons.filter_list_alt,
      color: filter == ShelfFilter.all ? colors.secondary : colors.accent,
    ),
    entries: [
      for (final choice in ShelfFilter.values)
        AppMenuEntry(
          value: choice,
          label: choice.label,
          selected: choice == filter,
        ),
    ],
  );
}

class LibrarySearchControls extends StatelessWidget {
  const LibrarySearchControls({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.filter,
    required this.colors,
    required this.onChanged,
    required this.onClearFilter,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final ShelfFilter filter;
  final ReaderThemeColors colors;
  final VoidCallback onChanged;
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(24),
      borderSide: BorderSide(color: color),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('shelf-search-input'),
          controller: controller,
          focusNode: focusNode,
          onChanged: (_) => onChanged(),
          style: TextStyle(color: colors.text, fontSize: 14),
          cursorColor: colors.accent,
          decoration: InputDecoration(
            hintText: '搜索书名、作者或格式',
            hintStyle: TextStyle(color: colors.secondary, fontSize: 14),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: colors.secondary,
              size: 21,
            ),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    onPressed: () {
                      controller.clear();
                      onChanged();
                    },
                    icon: Icon(
                      Icons.close_rounded,
                      color: colors.secondary,
                      size: 20,
                    ),
                  ),
            filled: true,
            fillColor: colors.headerBg,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: border(colors.border),
            enabledBorder: border(colors.border),
            focusedBorder: border(colors.accent),
          ),
        ),
        if (filter != ShelfFilter.all)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  '筛选',
                  style: TextStyle(color: colors.secondary, fontSize: 12),
                ),
                InputChip(
                  key: const ValueKey('shelf-active-filter'),
                  label: Text(filter.label),
                  labelStyle: TextStyle(
                    color: colors.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  backgroundColor: colors.accent.withValues(alpha: 0.08),
                  side: BorderSide(
                    color: colors.accent.withValues(alpha: 0.25),
                  ),
                  shape: const StadiumBorder(),
                  deleteIcon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: colors.accent,
                  ),
                  deleteButtonTooltipMessage: '清除筛选',
                  onDeleted: onClearFilter,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
