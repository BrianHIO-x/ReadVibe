// Reader display settings model.

import 'package:flutter/material.dart';

enum ReaderThemeMode { system, light, warm, dark }

enum ReaderPageMargin { compact, medium, wide }

enum ReaderFontWeight { light, regular, bold }

enum ReaderParagraphSpacing { none, blankLine }

enum ReaderPageTurnMode { smooth, book }

extension ReaderThemeModeInfo on ReaderThemeMode {
  String get label => switch (this) {
    ReaderThemeMode.system => '系统',
    ReaderThemeMode.light => '浅色',
    ReaderThemeMode.warm => '暖色',
    ReaderThemeMode.dark => '深色',
  };
}

extension ReaderPageMarginInfo on ReaderPageMargin {
  String get label => switch (this) {
    ReaderPageMargin.compact => '窄',
    ReaderPageMargin.medium => '中',
    ReaderPageMargin.wide => '宽',
  };

  double get horizontalPadding => switch (this) {
    ReaderPageMargin.compact => 16.0,
    ReaderPageMargin.medium => 24.0,
    ReaderPageMargin.wide => 32.0,
  };
}

extension ReaderFontWeightInfo on ReaderFontWeight {
  String get label => switch (this) {
    ReaderFontWeight.light => '细',
    ReaderFontWeight.regular => '常规',
    ReaderFontWeight.bold => '粗',
  };

  FontWeight get value => switch (this) {
    ReaderFontWeight.light => FontWeight.w300,
    ReaderFontWeight.regular => FontWeight.w400,
    ReaderFontWeight.bold => FontWeight.w600,
  };
}

extension ReaderParagraphSpacingInfo on ReaderParagraphSpacing {
  String get label => switch (this) {
    ReaderParagraphSpacing.none => '不空行',
    ReaderParagraphSpacing.blankLine => '空一行',
  };
}

extension ReaderPageTurnModeInfo on ReaderPageTurnMode {
  String get label => switch (this) {
    ReaderPageTurnMode.smooth => '平滑',
    ReaderPageTurnMode.book => '翻书',
  };
}

class ReaderSettings {
  static const schemaVersion = 3;
  static const systemFontFamily = 'system';
  static const builtinSerifFamily = 'SourceHanSerifSC';

  final double fontSize;
  final double lineHeight;
  final ReaderThemeMode theme;
  final ReaderFontWeight fontWeight;
  final String fontFamily;
  final String? importedFontFamily;
  final String? importedFontName;
  final String? importedFontPath;
  final ReaderPageMargin pageMargin;
  final ReaderParagraphSpacing paragraphSpacing;
  final ReaderPageTurnMode pageTurnMode;

  const ReaderSettings({
    this.fontSize = 20.0,
    this.lineHeight = 1.8,
    this.theme = ReaderThemeMode.system,
    this.fontWeight = ReaderFontWeight.regular,
    this.fontFamily = systemFontFamily,
    this.importedFontFamily,
    this.importedFontName,
    this.importedFontPath,
    this.pageMargin = ReaderPageMargin.medium,
    this.paragraphSpacing = ReaderParagraphSpacing.none,
    this.pageTurnMode = ReaderPageTurnMode.smooth,
  });

  bool get usesSystemFont => fontFamily == systemFontFamily;

  bool get usesBuiltinSerif => fontFamily == builtinSerifFamily;

  bool get hasImportedFont =>
      importedFontFamily?.trim().isNotEmpty == true &&
      importedFontName?.trim().isNotEmpty == true &&
      importedFontPath?.trim().isNotEmpty == true;

  String? get effectiveFontFamily {
    if (usesSystemFont) return null;
    if (usesBuiltinSerif) return builtinSerifFamily;
    return fontFamily;
  }

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    ReaderThemeMode? theme,
    ReaderFontWeight? fontWeight,
    String? fontFamily,
    String? importedFontFamily,
    String? importedFontName,
    String? importedFontPath,
    ReaderPageMargin? pageMargin,
    ReaderParagraphSpacing? paragraphSpacing,
    ReaderPageTurnMode? pageTurnMode,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      theme: theme ?? this.theme,
      fontWeight: fontWeight ?? this.fontWeight,
      fontFamily: fontFamily ?? this.fontFamily,
      importedFontFamily: importedFontFamily ?? this.importedFontFamily,
      importedFontName: importedFontName ?? this.importedFontName,
      importedFontPath: importedFontPath ?? this.importedFontPath,
      pageMargin: pageMargin ?? this.pageMargin,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      pageTurnMode: pageTurnMode ?? this.pageTurnMode,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'theme': theme.name,
    'fontWeight': fontWeight.name,
    'fontFamily': fontFamily,
    'importedFontFamily': importedFontFamily,
    'importedFontName': importedFontName,
    'importedFontPath': importedFontPath,
    'pageMargin': pageMargin.name,
    'paragraphSpacing': paragraphSpacing.name,
    'pageTurnMode': pageTurnMode.name,
  };

  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    final rawFontFamily = _nonEmptyString(json['fontFamily']);
    final fontFamily = switch (rawFontFamily) {
      null => systemFontFamily,
      // Older releases used Android's generic `serif` family for the Song
      // option. Keep that user choice when migrating to the bundled font.
      'serif' => builtinSerifFamily,
      _ => rawFontFamily,
    };
    final rawSchemaVersion = json['schemaVersion'];
    final storedSchemaVersion = rawSchemaVersion is num
        ? rawSchemaVersion.toInt()
        : 1;
    return ReaderSettings(
      fontSize: _normalizeFontSize(json['fontSize']),
      lineHeight: _finiteDouble(
        json['lineHeight'],
        fallback: 1.8,
        min: 1.2,
        max: 3.0,
      ),
      theme: ReaderThemeMode.values.firstWhere(
        (t) => t.name == json['theme'],
        orElse: () => ReaderThemeMode.system,
      ),
      fontWeight: ReaderFontWeight.values.firstWhere(
        (w) => w.name == json['fontWeight'],
        orElse: () => ReaderFontWeight.regular,
      ),
      fontFamily: fontFamily,
      importedFontFamily: _nonEmptyString(json['importedFontFamily']),
      importedFontName: _nonEmptyString(json['importedFontName']),
      importedFontPath: _nonEmptyString(json['importedFontPath']),
      pageMargin: ReaderPageMargin.values.firstWhere(
        (m) => m.name == json['pageMargin'],
        orElse: () => ReaderPageMargin.medium,
      ),
      // The pre-v2 default was "blank line". Migrate old records once so an
      // existing installation receives the new "no blank line" default too.
      paragraphSpacing: storedSchemaVersion < 2
          ? ReaderParagraphSpacing.none
          : ReaderParagraphSpacing.values.firstWhere(
              (s) => s.name == json['paragraphSpacing'],
              orElse: () => ReaderParagraphSpacing.none,
            ),
      pageTurnMode: ReaderPageTurnMode.values.firstWhere(
        (m) => m.name == json['pageTurnMode'],
        orElse: () => ReaderPageTurnMode.smooth,
      ),
    );
  }
}

double _normalizeFontSize(Object? value) {
  const supported = <double>[16, 18, 20, 22, 24];
  final parsed = _finiteDouble(value, fallback: 20, min: 12, max: 32);
  return supported.reduce(
    (best, candidate) =>
        (candidate - parsed).abs() < (best - parsed).abs() ? candidate : best,
  );
}

/// Reading progress for a specific book
class ReadingProgress {
  final String bookId;
  final int chapterIndex;
  final double scrollOffset;
  final double scrollProgress;
  final Map<int, double> chapterOffsets;
  final Map<int, double> chapterProgress;
  final DateTime lastReadDate;

  const ReadingProgress({
    required this.bookId,
    required this.chapterIndex,
    this.scrollOffset = 0,
    this.scrollProgress = 0,
    this.chapterOffsets = const <int, double>{},
    this.chapterProgress = const <int, double>{},
    required this.lastReadDate,
  });

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'chapterIndex': chapterIndex,
    'scrollOffset': scrollOffset,
    'scrollProgress': scrollProgress,
    'chapterOffsets': chapterOffsets.map((k, v) => MapEntry(k.toString(), v)),
    'chapterProgress': chapterProgress.map((k, v) => MapEntry(k.toString(), v)),
    'lastReadDate': lastReadDate.toIso8601String(),
  };

  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    final rawOffsets = json['chapterOffsets'];
    final chapterOffsets = <int, double>{};
    if (rawOffsets is Map) {
      for (final entry in rawOffsets.entries) {
        final idx = int.tryParse(entry.key.toString());
        final value = entry.value;
        if (idx != null && idx >= 0 && value is num) {
          final offset = value.toDouble();
          if (offset.isFinite && offset >= 0) {
            chapterOffsets[idx] = offset;
          }
        }
      }
    }

    final rawProgress = json['chapterProgress'];
    final chapterProgress = <int, double>{};
    if (rawProgress is Map) {
      for (final entry in rawProgress.entries) {
        final idx = int.tryParse(entry.key.toString());
        final value = entry.value;
        if (idx != null && idx >= 0 && value is num) {
          final progress = value.toDouble();
          if (progress.isFinite && progress >= 0 && progress <= 1) {
            chapterProgress[idx] = progress;
          }
        }
      }
    }

    final rawChapterIndex = json['chapterIndex'];
    final chapterIndex = rawChapterIndex is num
        ? rawChapterIndex.toInt().clamp(0, 0x7fffffff)
        : 0;
    final scrollOffset = _finiteDouble(
      json['scrollOffset'],
      fallback: 0,
      min: 0,
      max: double.maxFinite,
    );
    final scrollProgress = _finiteDouble(
      json['scrollProgress'],
      fallback: chapterProgress[chapterIndex] ?? 0,
      min: 0,
      max: 1,
    );
    final rawLastReadDate = json['lastReadDate'];
    final lastReadDate = rawLastReadDate is String
        ? DateTime.tryParse(rawLastReadDate) ?? DateTime.now()
        : DateTime.now();

    return ReadingProgress(
      bookId: _nonEmptyString(json['bookId']) ?? '',
      chapterIndex: chapterIndex,
      scrollOffset: scrollOffset,
      scrollProgress: scrollProgress,
      chapterOffsets: chapterOffsets,
      chapterProgress: chapterProgress,
      lastReadDate: lastReadDate,
    );
  }

  /// Returns a snapshot in which [chapterIndex] is the active chapter and its
  /// latest scroll [offset] is stored atomically with the rest of the map.
  ReadingProgress recordPosition(
    int chapterIndex,
    double offset, {
    double? progress,
  }) {
    final safeIndex = chapterIndex.clamp(0, 0x7fffffff);
    final safeOffset = offset.isFinite && offset >= 0 ? offset : 0.0;
    final safeProgress = progress != null && progress.isFinite
        ? progress.clamp(0.0, 1.0).toDouble()
        : chapterProgress[safeIndex] ??
              (safeIndex == this.chapterIndex ? scrollProgress : 0.0);
    final updated = Map<int, double>.from(chapterOffsets)
      ..[safeIndex] = safeOffset;
    final updatedProgress = Map<int, double>.from(chapterProgress)
      ..[safeIndex] = safeProgress;
    return ReadingProgress(
      bookId: bookId,
      chapterIndex: safeIndex,
      scrollOffset: safeOffset,
      scrollProgress: safeProgress,
      chapterOffsets: updated,
      chapterProgress: updatedProgress,
      lastReadDate: DateTime.now(),
    );
  }

  ReadingProgress withChapterOffset(int chapterIndex, double offset) {
    final safeOffset = offset.isFinite && offset >= 0 ? offset : 0.0;
    final updated = Map<int, double>.from(chapterOffsets);
    updated[chapterIndex] = safeOffset;
    return ReadingProgress(
      bookId: bookId,
      chapterIndex: this.chapterIndex,
      scrollOffset: chapterIndex == this.chapterIndex
          ? safeOffset
          : scrollOffset,
      scrollProgress: scrollProgress,
      chapterOffsets: updated,
      chapterProgress: chapterProgress,
      lastReadDate: DateTime.now(),
    );
  }

  ReadingProgress withChapter(int newChapterIndex, {double? scrollOffset}) {
    return ReadingProgress(
      bookId: bookId,
      chapterIndex: newChapterIndex,
      scrollOffset: scrollOffset ?? 0,
      scrollProgress: chapterProgress[newChapterIndex] ?? 0,
      chapterOffsets: chapterOffsets,
      chapterProgress: chapterProgress,
      lastReadDate: DateTime.now(),
    );
  }
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

double _finiteDouble(
  Object? value, {
  required double fallback,
  required double min,
  required double max,
}) {
  if (value is! num) return fallback;
  final parsed = value.toDouble();
  if (!parsed.isFinite) return fallback;
  return parsed.clamp(min, max).toDouble();
}
