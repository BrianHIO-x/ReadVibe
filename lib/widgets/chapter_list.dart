import 'package:flutter/foundation.dart' show ValueListenable, setEquals;
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_sheet.dart';
import '../services/word_count_service.dart';

typedef TocGroupExpansionChanged = void Function(String groupId, bool expanded);

/// Full-screen chapter list modal.
///
/// Books with explicit volume markers use a two-level directory. Books without
/// a volume stay as the original flat chapter list. Collapsed volume IDs are
/// supplied by the reader so expansion state survives closing the sheet and
/// reopening the app.
class ChapterListSheet extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentChapter;
  final ValueChanged<int> onSelect;
  final ScrollController scrollController;
  final ReaderThemeColors colors;
  final ValueListenable<int?> wordCountListenable;
  final ValueListenable<List<int>?> chapterWordCountsListenable;
  final Set<String> collapsedGroupIds;
  final TocGroupExpansionChanged onGroupExpansionChanged;

  const ChapterListSheet({
    super.key,
    required this.chapters,
    required this.currentChapter,
    required this.onSelect,
    required this.scrollController,
    required this.colors,
    required this.wordCountListenable,
    required this.chapterWordCountsListenable,
    required this.collapsedGroupIds,
    required this.onGroupExpansionChanged,
  });

  @override
  State<ChapterListSheet> createState() => _ChapterListSheetState();
}

class _ChapterListSheetState extends State<ChapterListSheet> {
  late Set<String> _collapsedGroupIds;
  bool _initialScrollScheduled = false;

  @override
  void initState() {
    super.initState();
    _collapsedGroupIds = Set<String>.from(widget.collapsedGroupIds);
  }

  @override
  void didUpdateWidget(covariant ChapterListSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.collapsedGroupIds, widget.collapsedGroupIds)) {
      _collapsedGroupIds = Set<String>.from(widget.collapsedGroupIds);
    }
  }

  @override
  Widget build(BuildContext context) {
    final directory = _TocDirectory.fromChapters(widget.chapters);
    _scheduleInitialScroll(directory);

    return AppSheetSurface(
      colors: widget.colors,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                20,
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.md,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '目录',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: widget.colors.text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        ValueListenableBuilder<int?>(
                          valueListenable: widget.wordCountListenable,
                          builder: (context, wordCount, _) => Text(
                            '${widget.chapters.length} 章 · ${formatBookWordCount(wordCount)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.colors.secondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                    icon: Icon(Icons.close, color: widget.colors.secondary),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: widget.colors.border),
            Expanded(
              child: CustomScrollView(
                controller: widget.scrollController,
                slivers: _buildDirectorySlivers(directory),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDirectorySlivers(_TocDirectory directory) {
    return directory.entries
        .map((entry) {
          return switch (entry) {
            _TocDirectEntry(:final chapterIndex) => SliverToBoxAdapter(
              child: _buildChapterRow(
                chapterIndex,
                isTopLevel: directory.hasVolumes,
              ),
            ),
            _TocVolumeEntry() => _buildVolumeSection(entry),
          };
        })
        .toList(growable: false);
  }

  Widget _buildVolumeSection(_TocVolumeEntry entry) {
    final expanded = !_collapsedGroupIds.contains(entry.id);
    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _TocVolumeHeaderDelegate(
            child: _buildVolumeRow(entry, expanded),
          ),
        ),
        if (expanded)
          SliverList.builder(
            itemCount: entry.chapterIndexes.length,
            itemBuilder: (context, index) => _buildChapterRow(
              entry.chapterIndexes[index],
              volumeTitle: entry.title,
            ),
          ),
      ],
    );
  }

  Widget _buildVolumeRow(_TocVolumeEntry entry, bool expanded) {
    final containsActive = entry.chapterIndexes.contains(widget.currentChapter);
    final background = Color.alphaBlend(
      containsActive
          ? widget.colors.text.withValues(alpha: 0.06)
          : Colors.transparent,
      widget.colors.headerBg,
    );
    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      color: background,
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 20),
          leading: AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: AppMotion.control,
            curve: AppMotion.standard,
            child: Icon(
              Icons.chevron_right,
              color: containsActive
                  ? widget.colors.accent
                  : widget.colors.secondary,
            ),
          ),
          title: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: containsActive ? widget.colors.accent : widget.colors.text,
            ),
          ),
          trailing: Text(
            '${entry.chapterIndexes.length} 项',
            style: TextStyle(fontSize: 12, color: widget.colors.secondary),
          ),
          onTap: () => _toggleVolume(entry.id, expanded),
        ),
      ),
    );
  }

  Widget _buildChapterRow(
    int chapterIndex, {
    bool isTopLevel = false,
    String? volumeTitle,
  }) {
    final chapter = widget.chapters[chapterIndex];
    final isActive = chapterIndex == widget.currentChapter;
    final isVolumeLanding =
        volumeTitle != null &&
        isVolumeChapterTitle(chapter.title) &&
        chapter.title.trim() == volumeTitle.trim();
    final displayTitle = isVolumeLanding ? '卷首' : chapter.title;

    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      color: isActive
          ? widget.colors.text.withValues(alpha: 0.06)
          : Colors.transparent,
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          contentPadding: EdgeInsets.only(
            left: isTopLevel ? 20 : (volumeTitle == null ? 16 : 44),
            right: 20,
          ),
          minLeadingWidth: isTopLevel ? 18 : 6,
          horizontalTitleGap: isTopLevel ? 12 : 8,
          leading: isTopLevel
              ? Icon(
                  Icons.description_outlined,
                  size: 18,
                  color: isActive
                      ? widget.colors.accent
                      : widget.colors.secondary,
                )
              : const SizedBox(width: 6),
          title: Text(
            displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              color: isActive ? widget.colors.accent : widget.colors.text,
              fontWeight: isTopLevel || isActive
                  ? FontWeight.w500
                  : FontWeight.normal,
            ),
          ),
          trailing: SizedBox(
            width: 84,
            child: ValueListenableBuilder<List<int>?>(
              valueListenable: widget.chapterWordCountsListenable,
              builder: (context, chapterWordCounts, _) {
                final wordCount =
                    chapterWordCounts != null &&
                        chapterIndex < chapterWordCounts.length
                    ? chapterWordCounts[chapterIndex]
                    : null;
                return Text(
                  formatChapterWordCount(wordCount),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 12,
                    color: isActive
                        ? widget.colors.accent
                        : widget.colors.secondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                );
              },
            ),
          ),
          onTap: () {
            widget.onSelect(chapterIndex);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  void _toggleVolume(String groupId, bool currentlyExpanded) {
    final expanded = !currentlyExpanded;
    setState(() {
      if (expanded) {
        _collapsedGroupIds.remove(groupId);
      } else {
        _collapsedGroupIds.add(groupId);
      }
    });
    widget.onGroupExpansionChanged(groupId, expanded);
  }

  void _scheduleInitialScroll(_TocDirectory directory) {
    if (_initialScrollScheduled) return;
    _initialScrollScheduled = true;
    final rowIndex = directory.visibleRowForChapter(
      widget.currentChapter,
      _collapsedGroupIds,
    );
    final keepVolumeHeaderVisible = directory.isChapterInExpandedVolume(
      widget.currentChapter,
      _collapsedGroupIds,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.scrollController.hasClients) return;
      final desiredOffset =
          (rowIndex - (keepVolumeHeaderVisible ? 1 : 0)) * 56.0;
      widget.scrollController.jumpTo(
        desiredOffset.clamp(
          0.0,
          widget.scrollController.position.maxScrollExtent,
        ),
      );
    });
  }
}

class _TocVolumeHeaderDelegate extends SliverPersistentHeaderDelegate {
  static const double extent = 56;

  final Widget child;

  const _TocVolumeHeaderDelegate({required this.child});

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox.expand(child: child);

  @override
  bool shouldRebuild(covariant _TocVolumeHeaderDelegate oldDelegate) =>
      oldDelegate.child != child;
}

sealed class _TocEntry {
  const _TocEntry();
}

class _TocDirectEntry extends _TocEntry {
  final int chapterIndex;

  const _TocDirectEntry(this.chapterIndex);
}

class _TocVolumeEntry extends _TocEntry {
  final String id;
  final String title;
  final List<int> chapterIndexes;

  const _TocVolumeEntry({
    required this.id,
    required this.title,
    required this.chapterIndexes,
  });
}

class _TocDirectory {
  final bool hasVolumes;
  final List<_TocEntry> entries;

  const _TocDirectory({required this.hasVolumes, required this.entries});

  factory _TocDirectory.fromChapters(List<Chapter> chapters) {
    final introductory = <_TocDirectEntry>[];
    final ungroupedBeforeVolumes = <_TocDirectEntry>[];
    final ungroupedAfterVolumes = <_TocDirectEntry>[];
    final volumes = <_MutableTocVolume>[];
    String? inferredVolumeTitle;
    _MutableTocVolume? activeVolume;

    for (var chapterIndex = 0; chapterIndex < chapters.length; chapterIndex++) {
      final chapter = chapters[chapterIndex];
      if (isVolumeChapterTitle(chapter.title)) {
        inferredVolumeTitle = chapter.volumeTitle ?? chapter.title.trim();
      }

      final volumeTitle = isStandaloneChapterTitle(chapter.title)
          ? null
          : chapter.volumeTitle ?? inferredVolumeTitle;
      if (volumeTitle != null && volumeTitle.trim().isNotEmpty) {
        final normalizedTitle = volumeTitle.trim();
        if (activeVolume == null || activeVolume.title != normalizedTitle) {
          activeVolume = _MutableTocVolume(
            id: 'volume:$chapterIndex:$normalizedTitle',
            title: normalizedTitle,
          );
          volumes.add(activeVolume);
        }
        activeVolume.chapterIndexes.add(chapterIndex);
        continue;
      }

      final entry = _TocDirectEntry(chapterIndex);
      if (isIntroductoryChapterTitle(chapter.title)) {
        introductory.add(entry);
      } else if (volumes.isEmpty) {
        ungroupedBeforeVolumes.add(entry);
      } else {
        ungroupedAfterVolumes.add(entry);
      }
    }

    if (volumes.isEmpty) {
      return _TocDirectory(
        hasVolumes: false,
        entries: List<_TocEntry>.generate(
          chapters.length,
          (index) => _TocDirectEntry(index),
        ),
      );
    }

    return _TocDirectory(
      hasVolumes: true,
      entries: <_TocEntry>[
        ...introductory,
        ...ungroupedBeforeVolumes,
        ...volumes.map(
          (volume) => _TocVolumeEntry(
            id: volume.id,
            title: volume.title,
            chapterIndexes: List<int>.unmodifiable(volume.chapterIndexes),
          ),
        ),
        ...ungroupedAfterVolumes,
      ],
    );
  }

  int visibleRowForChapter(int chapterIndex, Set<String> collapsedGroupIds) {
    var row = 0;
    for (final entry in entries) {
      switch (entry) {
        case _TocDirectEntry(chapterIndex: final index):
          if (index == chapterIndex) return row;
          row++;
        case _TocVolumeEntry():
          if (entry.chapterIndexes.contains(chapterIndex)) {
            if (collapsedGroupIds.contains(entry.id)) return row;
            final childIndex = entry.chapterIndexes.indexOf(chapterIndex);
            return row + 1 + childIndex;
          }
          row +=
              1 +
              (collapsedGroupIds.contains(entry.id)
                  ? 0
                  : entry.chapterIndexes.length);
      }
    }
    return 0;
  }

  bool isChapterInExpandedVolume(
    int chapterIndex,
    Set<String> collapsedGroupIds,
  ) {
    for (final entry in entries) {
      if (entry is _TocVolumeEntry &&
          entry.chapterIndexes.contains(chapterIndex)) {
        return !collapsedGroupIds.contains(entry.id);
      }
    }
    return false;
  }
}

class _MutableTocVolume {
  final String id;
  final String title;
  final List<int> chapterIndexes = <int>[];

  _MutableTocVolume({required this.id, required this.title});
}
