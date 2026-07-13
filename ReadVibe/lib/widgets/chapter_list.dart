import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../models/book.dart';

/// Full-screen chapter list modal
class ChapterListSheet extends StatelessWidget {
  final List<Chapter> chapters;
  final int currentChapter;
  final ValueChanged<int> onSelect;
  final ScrollController scrollController;
  final ReaderThemeColors colors;

  const ChapterListSheet({
    super.key,
    required this.chapters,
    required this.currentChapter,
    required this.onSelect,
    required this.scrollController,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;
      final desiredOffset = currentChapter * 56.0;
      scrollController.jumpTo(
        desiredOffset.clamp(0.0, scrollController.position.maxScrollExtent),
      );
    });

    return Container(
      decoration: BoxDecoration(
        color: colors.headerBg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.pill),
        ),
      ),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(
              20,
              AppSpacing.xl,
              AppSpacing.sm,
              AppSpacing.md,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '目录',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                  icon: Icon(Icons.close, color: colors.secondary),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.border),
          // Chapter list
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: chapters.length,
              itemBuilder: (context, index) {
                final isActive = index == currentChapter;
                return AnimatedContainer(
                  duration: AppMotion.normal,
                  curve: AppMotion.standard,
                  color: isActive
                      ? colors.text.withValues(alpha: 0.06)
                      : Colors.transparent,
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      leading: Text(
                        '${index + 1}'.padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: 12,
                          color: isActive ? colors.accent : colors.secondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      title: Text(
                        chapters[index].title,
                        style: TextStyle(
                          fontSize: 16,
                          color: isActive ? colors.accent : colors.text,
                          fontWeight: isActive
                              ? FontWeight.w500
                              : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        onSelect(index);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
