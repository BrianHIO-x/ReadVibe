// Rich reading notes and inline annotations for both reflowable books and PDFs.

import 'dart:math' as math;

import 'package:flutter/material.dart';

const maxReaderNotesPerBook = 1000;
const maxReaderNoteQuote = 1200;
const maxReaderNoteContent = 8000;
const maxReaderNoteTags = 6;
const maxReaderNoteTagLength = 20;

/// Curated palette designed for legible contrast across light, warm, dark,
/// and OLED black reading themes.
enum NoteColor {
  amber('琥珀'),
  terracotta('陶红'),
  sage('松绿'),
  sky('靛青'),
  plum('丁香');

  const NoteColor(this.label);

  final String label;

  Color swatchColor(bool isDark) => switch (this) {
    NoteColor.amber => isDark ? const Color(0xFFE0A94F) : const Color(0xFFC88318),
    NoteColor.terracotta =>
      isDark ? const Color(0xFFE38268) : const Color(0xFFB3543A),
    NoteColor.sage => isDark ? const Color(0xFF6BB084) : const Color(0xFF3E7B57),
    NoteColor.sky => isDark ? const Color(0xFF6DA6DB) : const Color(0xFF356CA3),
    NoteColor.plum => isDark ? const Color(0xFFB58AD6) : const Color(0xFF7B509D),
  };

  Color highlightFill(bool isDark) =>
      swatchColor(isDark).withValues(alpha: isDark ? 0.26 : 0.21);

  Color cardTint(bool isDark) =>
      swatchColor(isDark).withValues(alpha: isDark ? 0.12 : 0.075);
}

/// Visual rendering style for inline text annotations.
enum NoteStyle {
  highlight('荧光'),
  underline('直线'),
  wavy('波浪'),
  dashed('虚线');

  const NoteStyle(this.label);

  final String label;

  IconData get icon => switch (this) {
    NoteStyle.highlight => Icons.format_color_fill_rounded,
    NoteStyle.underline => Icons.format_underlined_rounded,
    NoteStyle.wavy => Icons.waves_rounded,
    NoteStyle.dashed => Icons.more_horiz_rounded,
  };
}

/// Semantic category tag helping readers organize highlights and thoughts.
enum NoteCategory {
  highlight('摘录', Icons.format_quote_rounded),
  thought('想法', Icons.lightbulb_outline_rounded),
  insight('金句', Icons.auto_awesome_outlined),
  question('疑问', Icons.help_outline_rounded),
  summary('批注', Icons.edit_note_rounded);

  const NoteCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Normalizes and bounds custom note tags while preserving insertion order.
List<String> normalizeNoteTags(Iterable<Object?> raw) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! String) continue;
    var text = item.trim();
    while (text.startsWith('#')) {
      text = text.substring(1).trim();
    }
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) continue;
    text = clampNoteText(text, maxReaderNoteTagLength);
    if (text.isEmpty || !seen.add(text)) continue;
    normalized.add(text);
    if (normalized.length >= maxReaderNoteTags) break;
  }
  return List<String>.unmodifiable(normalized);
}

/// Trims a string without splitting UTF-16 surrogate pairs.
String clampNoteText(Object? value, int maxLength) {
  if (value is! String) return '';
  final trimmed = value.trim();
  if (trimmed.length <= maxLength) return trimmed;
  var end = math.min(maxLength, trimmed.length);
  final unit = trimmed.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  return trimmed.substring(0, end).trimRight();
}

/// A rich reading note or inline highlight attached to either a reflowable book
/// paragraph span or a fixed-layout PDF page.
class ReaderNote {
  final String id;
  final String bookId;
  final int chapterIndex;
  final String chapterTitle;
  final int paragraphIndex;
  final int startOffset;
  final int endOffset;
  final String quote;
  final String content;
  final NoteColor color;
  final NoteStyle style;
  final NoteCategory category;
  final List<String> tags;
  final double chapterProgress;
  final bool isPdf;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ReaderNote({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.paragraphIndex,
    this.startOffset = 0,
    this.endOffset = 0,
    this.quote = '',
    this.content = '',
    this.color = NoteColor.amber,
    this.style = NoteStyle.highlight,
    this.category = NoteCategory.thought,
    this.tags = const <String>[],
    this.chapterProgress = 0,
    this.isPdf = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get hasContent => content.trim().isNotEmpty;
  bool get hasQuote => quote.trim().isNotEmpty;
  bool get hasInlineSpan =>
      !isPdf && paragraphIndex >= 0 && endOffset > startOffset;
  bool get isPureHighlight => !hasContent;

  ReaderNote copyWith({
    int? chapterIndex,
    String? chapterTitle,
    int? paragraphIndex,
    int? startOffset,
    int? endOffset,
    String? quote,
    String? content,
    NoteColor? color,
    NoteStyle? style,
    NoteCategory? category,
    List<String>? tags,
    double? chapterProgress,
    DateTime? updatedAt,
  }) {
    return ReaderNote(
      id: id,
      bookId: bookId,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      paragraphIndex: paragraphIndex ?? this.paragraphIndex,
      startOffset: startOffset ?? this.startOffset,
      endOffset: endOffset ?? this.endOffset,
      quote: quote == null ? this.quote : clampNoteText(quote, maxReaderNoteQuote),
      content: content == null
          ? this.content
          : clampNoteText(content, maxReaderNoteContent),
      color: color ?? this.color,
      style: style ?? this.style,
      category: category ?? this.category,
      tags: tags == null ? this.tags : normalizeNoteTags(tags),
      chapterProgress: chapterProgress ?? this.chapterProgress,
      isPdf: isPdf,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'bookId': bookId,
    'chapterIndex': chapterIndex,
    'chapterTitle': chapterTitle,
    'paragraphIndex': paragraphIndex,
    'startOffset': startOffset,
    'endOffset': endOffset,
    if (quote.isNotEmpty) 'quote': quote,
    if (content.isNotEmpty) 'content': content,
    'color': color.name,
    'style': style.name,
    'category': category.name,
    if (tags.isNotEmpty) 'tags': tags,
    'chapterProgress': chapterProgress,
    if (isPdf) 'isPdf': true,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static ReaderNote? fromJson(Object? source, {String? fallbackBookId}) {
    if (source is! Map) return null;
    final json = Map<String, dynamic>.from(source);
    final chapterIndex = _boundedInt(json['chapterIndex']);
    if (chapterIndex == null) return null;
    final rawParagraph = json['paragraphIndex'];
    final paragraphIndex = rawParagraph is num && rawParagraph.isFinite
        ? rawParagraph.toInt().clamp(-1, 0x7fffffff)
        : -1;
    final isPdf = json['isPdf'] == true || paragraphIndex < 0;
    final startOffset = _boundedInt(json['startOffset']) ?? 0;
    final rawEndOffset = _boundedInt(json['endOffset']) ?? startOffset;
    final endOffset = math.max(startOffset, rawEndOffset);

    final bookIdRaw = json['bookId'];
    final bookId = bookIdRaw is String && bookIdRaw.trim().isNotEmpty
        ? bookIdRaw.trim()
        : (fallbackBookId ?? '');
    if (bookId.isEmpty) return null;

    final createdRaw = json['createdAt'];
    final createdAt = createdRaw is String
        ? DateTime.tryParse(createdRaw) ?? DateTime.now()
        : DateTime.now();
    final updatedRaw = json['updatedAt'];
    final updatedAt = updatedRaw is String
        ? DateTime.tryParse(updatedRaw) ?? createdAt
        : createdAt;

    final rawId = json['id'];
    final id = rawId is String && rawId.isNotEmpty && rawId.length <= 96
        ? rawId
        : '$chapterIndex:$paragraphIndex:$startOffset:${createdAt.microsecondsSinceEpoch}';

    final progress = json['chapterProgress'];
    final quote = clampNoteText(json['quote'], maxReaderNoteQuote);
    final content = clampNoteText(json['content'], maxReaderNoteContent);
    if (quote.isEmpty && content.isEmpty) return null;

    return ReaderNote(
      id: id,
      bookId: bookId,
      chapterIndex: chapterIndex,
      chapterTitle: clampNoteText(json['chapterTitle'], 120),
      paragraphIndex: paragraphIndex,
      startOffset: startOffset,
      endOffset: endOffset,
      quote: quote,
      content: content,
      color: NoteColor.values.asNameMap()[json['color']] ?? NoteColor.amber,
      style: NoteStyle.values.asNameMap()[json['style']] ?? NoteStyle.highlight,
      category:
          NoteCategory.values.asNameMap()[json['category']] ??
          (content.isEmpty ? NoteCategory.highlight : NoteCategory.thought),
      tags: json['tags'] is Iterable
          ? normalizeNoteTags((json['tags'] as Iterable).cast<Object?>())
          : const <String>[],
      chapterProgress: progress is num && progress.isFinite
          ? progress.toDouble().clamp(0.0, 1.0)
          : 0.0,
      isPdf: isPdf,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static int? _boundedInt(Object? value) {
    if (value is! num || !value.isFinite) return null;
    final result = value.toInt();
    return result >= 0 && result <= 0x7fffffff ? result : null;
  }
}

List<ReaderNote> sortedReaderNotes(
  Iterable<ReaderNote> notes, {
  bool byTime = false,
}) {
  final list = notes.toList();
  if (byTime) {
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }
  list.sort((a, b) {
    final byChapter = a.chapterIndex.compareTo(b.chapterIndex);
    if (byChapter != 0) return byChapter;
    final byParagraph = a.paragraphIndex.compareTo(b.paragraphIndex);
    if (byParagraph != 0) return byParagraph;
    final byStart = a.startOffset.compareTo(b.startOffset);
    if (byStart != 0) return byStart;
    return a.createdAt.compareTo(b.createdAt);
  });
  return list;
}

String formatNotesAsMarkdown({
  required String bookTitle,
  String author = '',
  required List<ReaderNote> notes,
}) {
  final sorted = sortedReaderNotes(notes);
  final buffer = StringBuffer();
  buffer.writeln('# 《$bookTitle》读书笔记');
  if (author.trim().isNotEmpty) {
    buffer.writeln('作者：$author');
  }
  buffer.writeln('共 ${sorted.length} 条记录');
  buffer.writeln();

  int? lastChapter;
  for (final note in sorted) {
    if (lastChapter != note.chapterIndex) {
      lastChapter = note.chapterIndex;
      final heading = note.chapterTitle.isNotEmpty
          ? note.chapterTitle
          : (note.isPdf
                ? '第 ${note.chapterIndex + 1} 页'
                : '第 ${note.chapterIndex + 1} 章');
      buffer.writeln('## $heading');
      buffer.writeln();
    }
    final local = note.updatedAt.toLocal();
    final dateStr =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final tagSuffix = note.tags.isEmpty
        ? ''
        : ' · ${note.tags.map((t) => '#$t').join(' ')}';
    buffer.writeln('**[${note.category.label}]** · $dateStr$tagSuffix');
    if (note.hasQuote) {
      for (final line in note.quote.split('\n')) {
        buffer.writeln('> $line');
      }
      buffer.writeln();
    }
    if (note.hasContent) {
      buffer.writeln(note.content);
      buffer.writeln();
    }
    buffer.writeln('---');
    buffer.writeln();
  }
  return buffer.toString().trimRight();
}
