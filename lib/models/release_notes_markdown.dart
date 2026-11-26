import 'dart:math' as math;

/// A contiguous inline text segment parsed from Markdown release notes.
class ReleaseNotesInlineRun {
  const ReleaseNotesInlineRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strikethrough = false,
    this.isLink = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final bool strikethrough;
  final bool isLink;

  bool hasSameStyle(ReleaseNotesInlineRun other) =>
      bold == other.bold &&
      italic == other.italic &&
      code == other.code &&
      strikethrough == other.strikethrough &&
      isLink == other.isLink;
}

/// Base node for structured blocks inside parsed release notes.
sealed class ReleaseNotesBlock {
  const ReleaseNotesBlock();
}

/// ATX or Setext heading (`#`..`######`, clamped to level 1..6).
class ReleaseNotesHeadingBlock extends ReleaseNotesBlock {
  const ReleaseNotesHeadingBlock(this.level, this.runs);

  final int level;
  final List<ReleaseNotesInlineRun> runs;
}

/// Standard paragraph preserving soft/explicit line breaks from source notes.
class ReleaseNotesParagraphBlock extends ReleaseNotesBlock {
  const ReleaseNotesParagraphBlock(this.runs);

  final List<ReleaseNotesInlineRun> runs;
}

/// Bullet, ordered, or task-checkbox list item.
class ReleaseNotesListItemBlock extends ReleaseNotesBlock {
  const ReleaseNotesListItemBlock(
    this.runs, {
    this.indent = 0,
    this.ordered = false,
    this.marker,
    this.checked,
  });

  final List<ReleaseNotesInlineRun> runs;
  final int indent;
  final bool ordered;
  final String? marker;
  final bool? checked;
}

/// Blockquote or GitHub Alert callout (`> [!NOTE]`, etc.).
class ReleaseNotesQuoteBlock extends ReleaseNotesBlock {
  const ReleaseNotesQuoteBlock(this.children, {this.alertLabel});

  final List<ReleaseNotesBlock> children;
  final String? alertLabel;
}

/// Fenced code block whose body is kept verbatim without inline parsing.
class ReleaseNotesCodeBlock extends ReleaseNotesBlock {
  const ReleaseNotesCodeBlock(this.code, {this.language});

  final String code;
  final String? language;
}

/// GitHub-flavored Markdown pipe table.
class ReleaseNotesTableBlock extends ReleaseNotesBlock {
  const ReleaseNotesTableBlock(this.headers, this.rows);

  final List<List<ReleaseNotesInlineRun>> headers;
  final List<List<List<ReleaseNotesInlineRun>>> rows;
}

/// Horizontal thematic break (`---`, `***`, `___`, `<hr>`).
class ReleaseNotesDividerBlock extends ReleaseNotesBlock {
  const ReleaseNotesDividerBlock();
}

/// Dedicated verification digest block (e.g. `SHA-256：...`).
class ReleaseNotesChecksumBlock extends ReleaseNotesBlock {
  const ReleaseNotesChecksumBlock(this.label, this.value);

  final String label;
  final String value;
}

/// Parses GitHub release notes / Markdown into structured UI-agnostic blocks.
List<ReleaseNotesBlock> parseReleaseNotesMarkdown(String raw) {
  final preprocessed = _preprocessMarkdown(raw);
  if (preprocessed.trim().isEmpty) return const [];
  final lines = preprocessed.split('\n');
  return _parseBlocks(lines);
}

/// Parses inline Markdown spans into flattened styled runs.
List<ReleaseNotesInlineRun> parseReleaseNotesInlineRuns(String text) {
  if (text.isEmpty) return const [];
  return _parseInline(text, const _InlineStyle());
}

/// Extracts plain rendered text from [blocks] with Markdown syntax stripped.
String releaseNotesPlainText(List<ReleaseNotesBlock> blocks) {
  final buffer = StringBuffer();
  void writeRuns(List<ReleaseNotesInlineRun> runs) {
    for (final run in runs) {
      buffer.write(run.text);
    }
  }

  void writeBlocks(List<ReleaseNotesBlock> items) {
    for (var i = 0; i < items.length; i++) {
      if (i > 0) buffer.writeln();
      switch (items[i]) {
        case ReleaseNotesHeadingBlock(:final runs):
          writeRuns(runs);
        case ReleaseNotesParagraphBlock(:final runs):
          writeRuns(runs);
        case ReleaseNotesListItemBlock(:final runs):
          writeRuns(runs);
        case ReleaseNotesQuoteBlock(:final children, :final alertLabel):
          if (alertLabel != null) {
            buffer.write('$alertLabel: ');
          }
          writeBlocks(children);
        case ReleaseNotesCodeBlock(:final code):
          buffer.write(code);
        case ReleaseNotesTableBlock(:final headers, :final rows):
          for (var c = 0; c < headers.length; c++) {
            if (c > 0) buffer.write(' | ');
            writeRuns(headers[c]);
          }
          for (final row in rows) {
            buffer.writeln();
            for (var c = 0; c < row.length; c++) {
              if (c > 0) buffer.write(' | ');
              writeRuns(row[c]);
            }
          }
        case ReleaseNotesDividerBlock():
          break;
        case ReleaseNotesChecksumBlock(:final label, :final value):
          buffer.write('$label：$value');
      }
    }
  }

  writeBlocks(blocks);
  return buffer.toString();
}

final _fenceOpenPattern = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})(.*)$');
final _atxHeadingPattern = RegExp(
  r'^[ \t]{0,3}(#{1,6}|＃{1,6})[ \t\u3000]+(.*)$',
);
final _emptyAtxHeadingPattern = RegExp(
  r'^[ \t]{0,3}(#{1,6}|＃{1,6})[ \t\u3000]*$',
);
final _tolerantAtxHeadingPattern = RegExp(
  r'^[ \t]{0,3}(#{2,6}|＃{2,6})([^\s#＃].*)$',
);
final _closingHashesPattern = RegExp(r'[ \t\u3000]+(?:#+|＃+)[ \t\u3000]*$');
final _setextH1Pattern = RegExp(r'^[ \t]{0,3}={2,}[ \t]*$');
final _setextH2Pattern = RegExp(r'^[ \t]{0,3}-{3,}[ \t]*$');
final _dividerPattern = RegExp(
  r'^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$',
);
final _checksumPattern = RegExp(
  r'^\s*(?:[-*+•]\s+)?(?:\*\*|__)?(SHA-?256)(?:\*\*|__)?\s*[：:]\s*[`*]*([0-9a-fA-F]{64})[`*]*\s*$',
  caseSensitive: false,
);
final _quotePattern = RegExp(r'^[ \t]{0,3}>[ \t]?(.*)$');
final _alertPattern = RegExp(
  r'^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(.*)$',
  caseSensitive: false,
);
final _unorderedListPattern = RegExp(r'^([ \t]*)([-*+•])[ \t]+(.*)$');
final _orderedListPattern = RegExp(r'^([ \t]*)(\d{1,3})([.)])[ \t]+(.*)$');
final _taskPrefixPattern = RegExp(r'^\[([ xX])\][ \t]+(.*)$');
final _tableDelimiterMultiPattern = RegExp(
  r'^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(?:\|[ \t]*:?-{2,}:?[ \t]*)+\|?[ \t]*$',
);
final _tableDelimiterSinglePattern = RegExp(
  r'^[ \t]*\|[ \t]*:?-{2,}:?[ \t]*\|[ \t]*$',
);
final _htmlCommentPattern = RegExp(r'<!--[\s\S]*?-->');
final _hrTagPattern = RegExp(
  r'^[ \t]{0,3}<hr\s*/?>[ \t]*$',
  caseSensitive: false,
  multiLine: true,
);
final _detailsOpenPattern = RegExp(
  r'<details(?:\s[^<>]*)?>',
  caseSensitive: false,
);
final _detailsClosePattern = RegExp(r'</details>', caseSensitive: false);
final _summaryPattern = RegExp(
  r'<summary(?:\s[^<>]*)?>([\s\S]*?)</summary>',
  caseSensitive: false,
);

const _alertLabels = <String, String>{
  'NOTE': '说明',
  'TIP': '提示',
  'IMPORTANT': '重要',
  'WARNING': '注意',
  'CAUTION': '警示',
};

String _preprocessMarkdown(String raw) {
  final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final output = StringBuffer();
  final nonFenceLines = <String>[];

  void flushNonFence() {
    if (nonFenceLines.isEmpty) return;
    output.write(_preprocessNonFenceChunk(nonFenceLines.join('\n')));
    nonFenceLines.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final fence = _matchFenceOpen(lines[i]);
    if (fence == null) {
      nonFenceLines.add(lines[i]);
      i++;
      continue;
    }
    flushNonFence();
    if (output.isNotEmpty) output.writeln();
    output.write(lines[i]);
    i++;
    while (i < lines.length) {
      output.writeln();
      output.write(lines[i]);
      final isClose = fence.closePattern.hasMatch(lines[i]);
      i++;
      if (isClose) break;
    }
    if (i < lines.length) output.writeln();
  }
  flushNonFence();
  return output.toString();
}

String _preprocessNonFenceChunk(String chunk) {
  var result = chunk.replaceAll(_htmlCommentPattern, '');
  result = result.replaceAll(_hrTagPattern, '---');
  result = result.replaceAll(_detailsOpenPattern, '\n');
  result = result.replaceAll(_detailsClosePattern, '\n');
  result = result.replaceAllMapped(_summaryPattern, (match) {
    final title = (match.group(1) ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return title.isEmpty ? '\n' : '\n### $title\n';
  });
  return result;
}

class _FenceInfo {
  const _FenceInfo(this.language, this.closePattern);
  final String? language;
  final RegExp closePattern;
}

_FenceInfo? _matchFenceOpen(String line) {
  final match = _fenceOpenPattern.firstMatch(line);
  if (match == null) return null;
  final fence = match.group(1)!;
  final info = match.group(2)!;
  final fenceChar = fence[0];
  // CommonMark rejects backtick code fences whose info string also contains `.
  if (fenceChar == '`' && info.contains('`')) return null;
  final trimmedInfo = info.trim();
  final language = trimmedInfo.isEmpty
      ? null
      : trimmedInfo.split(RegExp(r'\s+')).first;
  final closePattern = RegExp(
    '^[ \\t]{0,3}${RegExp.escape(fenceChar)}{${fence.length},}[ \\t]*\$',
  );
  return _FenceInfo(language, closePattern);
}

List<ReleaseNotesBlock> _parseBlocks(List<String> lines, {int quoteDepth = 0}) {
  final blocks = <ReleaseNotesBlock>[];
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    final fence = _matchFenceOpen(line);
    if (fence != null) {
      final codeLines = <String>[];
      i++;
      while (i < lines.length) {
        if (fence.closePattern.hasMatch(lines[i])) {
          i++;
          break;
        }
        codeLines.add(lines[i]);
        i++;
      }
      blocks.add(
        ReleaseNotesCodeBlock(
          codeLines.join('\n'),
          language: fence.language,
        ),
      );
      continue;
    }

    final checksum = _checksumPattern.firstMatch(line);
    if (checksum != null) {
      blocks.add(ReleaseNotesChecksumBlock('SHA-256', checksum.group(2)!));
      i++;
      continue;
    }

    final heading = _tryParseAtxHeading(line);
    if (heading != null) {
      if (heading.runs.isNotEmpty) blocks.add(heading);
      i++;
      continue;
    }

    if (_dividerPattern.hasMatch(line)) {
      blocks.add(const ReleaseNotesDividerBlock());
      i++;
      continue;
    }

    if (_quotePattern.hasMatch(line)) {
      final quoteLines = <String>[];
      while (i < lines.length) {
        final qMatch = _quotePattern.firstMatch(lines[i]);
        if (qMatch == null) break;
        quoteLines.add(qMatch.group(1)!);
        i++;
      }
      blocks.add(_buildQuoteBlock(quoteLines, quoteDepth: quoteDepth));
      continue;
    }

    if (i + 1 < lines.length &&
        line.contains('|') &&
        _isTableDelimiter(lines[i + 1])) {
      final table = _tryParseTable(lines, i);
      if (table != null) {
        blocks.add(table.block);
        i = table.nextIndex;
        continue;
      }
    }

    final listMarker = _parseListMarker(line);
    if (listMarker != null) {
      final consumed = _consumeListItem(lines, i, listMarker);
      blocks.add(consumed.block);
      i = consumed.nextIndex;
      continue;
    }

    // Check single-line Setext heading before collecting a paragraph.
    if (i + 1 < lines.length) {
      final setextLevel = _setextLevel(lines[i + 1]);
      if (setextLevel != null) {
        final runs = parseReleaseNotesInlineRuns(line.trim());
        if (runs.isNotEmpty) {
          blocks.add(ReleaseNotesHeadingBlock(setextLevel, runs));
        }
        i += 2;
        continue;
      }
    }

    final paragraphLines = <String>[_stripHardBreakSuffix(line)];
    i++;
    while (i < lines.length) {
      final next = lines[i];
      if (next.trim().isEmpty) break;
      if (_setextLevel(next) != null) break;
      if (_startsDistinctBlock(lines, i)) break;
      paragraphLines.add(_stripHardBreakSuffix(next));
      i++;
    }
    final runs = parseReleaseNotesInlineRuns(paragraphLines.join('\n'));
    if (runs.isNotEmpty) {
      blocks.add(ReleaseNotesParagraphBlock(runs));
    }
  }

  return blocks;
}

ReleaseNotesHeadingBlock? _tryParseAtxHeading(String line) {
  if (_emptyAtxHeadingPattern.hasMatch(line)) {
    return const ReleaseNotesHeadingBlock(1, []);
  }
  final match =
      _atxHeadingPattern.firstMatch(line) ??
      _tolerantAtxHeadingPattern.firstMatch(line);
  if (match == null) return null;
  final level = match.group(1)!.length.clamp(1, 6);
  var body = match.group(2)!.trim();
  body = body.replaceFirst(_closingHashesPattern, '').trim();
  if (body.isEmpty) return const ReleaseNotesHeadingBlock(1, []);
  return ReleaseNotesHeadingBlock(level, parseReleaseNotesInlineRuns(body));
}

int? _setextLevel(String line) {
  if (_setextH1Pattern.hasMatch(line)) return 1;
  if (_setextH2Pattern.hasMatch(line)) return 2;
  return null;
}

ReleaseNotesQuoteBlock _buildQuoteBlock(
  List<String> quoteLines, {
  required int quoteDepth,
}) {
  String? alertLabel;
  final inner = List<String>.of(quoteLines);
  final firstNonEmpty = inner.indexWhere((line) => line.trim().isNotEmpty);
  if (firstNonEmpty >= 0) {
    final alertMatch = _alertPattern.firstMatch(inner[firstNonEmpty].trim());
    if (alertMatch != null) {
      alertLabel = _alertLabels[alertMatch.group(1)!.toUpperCase()];
      final remainder = alertMatch.group(2)!.trim();
      if (remainder.isEmpty) {
        inner.removeAt(firstNonEmpty);
      } else {
        inner[firstNonEmpty] = remainder;
      }
    }
  }

  final List<ReleaseNotesBlock> children;
  if (quoteDepth < 2) {
    children = _parseBlocks(inner, quoteDepth: quoteDepth + 1);
  } else {
    final text = inner
        .map((line) => line.replaceFirst(RegExp(r'^[ \t]*>+[ \t]?'), ''))
        .where((line) => line.trim().isNotEmpty)
        .join('\n');
    children = text.isEmpty
        ? const []
        : [ReleaseNotesParagraphBlock(parseReleaseNotesInlineRuns(text))];
  }
  return ReleaseNotesQuoteBlock(children, alertLabel: alertLabel);
}

bool _isTableDelimiter(String line) =>
    _tableDelimiterMultiPattern.hasMatch(line) ||
    _tableDelimiterSinglePattern.hasMatch(line);

class _TableResult {
  const _TableResult(this.block, this.nextIndex);
  final ReleaseNotesTableBlock block;
  final int nextIndex;
}

_TableResult? _tryParseTable(List<String> lines, int startIndex) {
  final headerCells = _splitTableRow(lines[startIndex]);
  final delimiterCells = _splitTableRow(lines[startIndex + 1]);
  if (headerCells.isEmpty || headerCells.length != delimiterCells.length) {
    return null;
  }
  final columnCount = headerCells.length;
  final headers = [
    for (final cell in headerCells) parseReleaseNotesInlineRuns(cell),
  ];
  final rows = <List<List<ReleaseNotesInlineRun>>>[];
  var i = startIndex + 2;
  while (i < lines.length) {
    final rowLine = lines[i];
    if (rowLine.trim().isEmpty || !rowLine.contains('|')) break;
    if (_startsDistinctBlock(lines, i)) break;
    final rawCells = _splitTableRow(rowLine);
    final normalizedRow = <List<ReleaseNotesInlineRun>>[
      for (var col = 0; col < columnCount; col++)
        col < rawCells.length
            ? parseReleaseNotesInlineRuns(rawCells[col])
            : const [],
    ];
    rows.add(normalizedRow);
    i++;
  }
  return _TableResult(ReleaseNotesTableBlock(headers, rows), i);
}

List<String> _splitTableRow(String line) {
  var trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
  if (trimmed.endsWith('|') && !_isEscapedAt(trimmed, trimmed.length - 1)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final cells = <String>[];
  final current = StringBuffer();
  var i = 0;
  while (i < trimmed.length) {
    final ch = trimmed[i];
    if (ch == r'\' && i + 1 < trimmed.length) {
      if (trimmed[i + 1] == '|') {
        current.write('|');
        i += 2;
        continue;
      }
      current.write(ch);
      current.write(trimmed[i + 1]);
      i += 2;
      continue;
    }
    if (ch == '`') {
      final closeIndex = _findCodeSpanClose(trimmed, i);
      if (closeIndex != null) {
        current.write(trimmed.substring(i, closeIndex));
        i = closeIndex;
        continue;
      }
    }
    if (ch == '|') {
      cells.add(current.toString().trim());
      current.clear();
      i++;
      continue;
    }
    current.write(ch);
    i++;
  }
  cells.add(current.toString().trim());
  return cells;
}

class _ListMarker {
  const _ListMarker({
    required this.rawIndentWidth,
    required this.indentLevel,
    required this.ordered,
    required this.marker,
    required this.checked,
    required this.body,
  });

  final int rawIndentWidth;
  final int indentLevel;
  final bool ordered;
  final String? marker;
  final bool? checked;
  final String body;
}

_ListMarker? _parseListMarker(String line) {
  final unordered = _unorderedListPattern.firstMatch(line);
  if (unordered != null) {
    final rawIndent = _indentWidth(unordered.group(1)!);
    final indentLevel = math.min(2, rawIndent ~/ 2);
    var body = unordered.group(3)!;
    bool? checked;
    final task = _taskPrefixPattern.firstMatch(body);
    if (task != null) {
      final mark = task.group(1)!;
      checked = mark == 'x' || mark == 'X';
      body = task.group(2)!;
    }
    return _ListMarker(
      rawIndentWidth: rawIndent,
      indentLevel: indentLevel,
      ordered: false,
      marker: null,
      checked: checked,
      body: body,
    );
  }
  final ordered = _orderedListPattern.firstMatch(line);
  if (ordered != null) {
    final rawIndent = _indentWidth(ordered.group(1)!);
    final indentLevel = math.min(2, rawIndent ~/ 2);
    final number = ordered.group(2)!;
    return _ListMarker(
      rawIndentWidth: rawIndent,
      indentLevel: indentLevel,
      ordered: true,
      marker: '$number.',
      checked: null,
      body: ordered.group(4)!,
    );
  }
  return null;
}

class _ConsumedListItem {
  const _ConsumedListItem(this.block, this.nextIndex);
  final ReleaseNotesListItemBlock block;
  final int nextIndex;
}

_ConsumedListItem _consumeListItem(
  List<String> lines,
  int startIndex,
  _ListMarker first,
) {
  final bodyLines = <String>[_stripHardBreakSuffix(first.body)];
  var i = startIndex + 1;
  while (i < lines.length) {
    final next = lines[i];
    if (next.trim().isEmpty) break;
    if (_parseListMarker(next) != null || _startsDistinctBlock(lines, i)) {
      break;
    }
    final nextIndent = _leadingIndentWidth(next);
    if (nextIndent <= first.rawIndentWidth) break;
    bodyLines.add(_stripHardBreakSuffix(next.trimLeft()));
    i++;
  }
  final joined = bodyLines.join('\n').trimRight();
  return _ConsumedListItem(
    ReleaseNotesListItemBlock(
      parseReleaseNotesInlineRuns(joined),
      indent: first.indentLevel,
      ordered: first.ordered,
      marker: first.marker,
      checked: first.checked,
    ),
    i,
  );
}

bool _startsDistinctBlock(List<String> lines, int index) {
  final line = lines[index];
  if (_matchFenceOpen(line) != null) return true;
  if (_checksumPattern.hasMatch(line)) return true;
  if (_atxHeadingPattern.hasMatch(line) ||
      _tolerantAtxHeadingPattern.hasMatch(line) ||
      _emptyAtxHeadingPattern.hasMatch(line)) {
    return true;
  }
  if (_dividerPattern.hasMatch(line)) return true;
  if (_quotePattern.hasMatch(line)) return true;
  if (index + 1 < lines.length &&
      line.contains('|') &&
      _isTableDelimiter(lines[index + 1])) {
    return true;
  }
  if (_parseListMarker(line) != null) return true;
  return false;
}

String _stripHardBreakSuffix(String line) {
  var result = line;
  if (result.endsWith(r'\') && !_isEscapedAt(result, result.length - 1)) {
    result = result.substring(0, result.length - 1);
  }
  return result.replaceFirst(RegExp(r' {2,}$'), '');
}

int _leadingIndentWidth(String line) {
  var width = 0;
  for (var i = 0; i < line.length; i++) {
    final unit = line.codeUnitAt(i);
    if (unit == 0x20) {
      width += 1;
    } else if (unit == 0x09) {
      width += 2;
    } else {
      break;
    }
  }
  return width;
}

int _indentWidth(String whitespace) => _leadingIndentWidth(whitespace);

bool _isEscapedAt(String text, int index) {
  var backslashes = 0;
  for (var i = index - 1; i >= 0 && text.codeUnitAt(i) == 0x5C; i--) {
    backslashes++;
  }
  return backslashes.isOdd;
}

class _InlineStyle {
  const _InlineStyle({
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.isLink = false,
  });

  final bool bold;
  final bool italic;
  final bool strikethrough;
  final bool isLink;

  _InlineStyle copyWith({
    bool? bold,
    bool? italic,
    bool? strikethrough,
    bool? isLink,
  }) => _InlineStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    strikethrough: strikethrough ?? this.strikethrough,
    isLink: isLink ?? this.isLink,
  );
}

List<ReleaseNotesInlineRun> _parseInline(String input, _InlineStyle style) {
  final out = <ReleaseNotesInlineRun>[];
  final plain = StringBuffer();

  void emitRun(ReleaseNotesInlineRun run) {
    if (run.text.isEmpty) return;
    if (out.isNotEmpty && out.last.hasSameStyle(run)) {
      final previous = out.removeLast();
      out.add(
        ReleaseNotesInlineRun(
          '${previous.text}${run.text}',
          bold: run.bold,
          italic: run.italic,
          code: run.code,
          strikethrough: run.strikethrough,
          isLink: run.isLink,
        ),
      );
      return;
    }
    out.add(run);
  }

  void flushPlain() {
    if (plain.isEmpty) return;
    emitRun(
      ReleaseNotesInlineRun(
        plain.toString(),
        bold: style.bold,
        italic: style.italic,
        strikethrough: style.strikethrough,
        isLink: style.isLink,
      ),
    );
    plain.clear();
  }

  void appendRuns(List<ReleaseNotesInlineRun> runs) {
    flushPlain();
    for (final run in runs) {
      emitRun(run);
    }
  }

  var i = 0;
  while (i < input.length) {
    final unit = input.codeUnitAt(i);

    // Backslash escape for ASCII punctuation or newline hard break.
    if (unit == 0x5C && i + 1 < input.length) {
      final next = input.codeUnitAt(i + 1);
      if (next == 0x0A) {
        plain.writeCharCode(0x0A);
        i += 2;
        continue;
      }
      if (_isAsciiPunctuation(next)) {
        plain.writeCharCode(next);
        i += 2;
        continue;
      }
    }

    // Inline code span (`code` or ``a ` b``).
    if (unit == 0x60) {
      final codeSpan = _tryMatchCodeSpan(input, i);
      if (codeSpan != null) {
        flushPlain();
        emitRun(
          ReleaseNotesInlineRun(
            codeSpan.text,
            bold: style.bold,
            italic: style.italic,
            code: true,
            strikethrough: style.strikethrough,
            isLink: style.isLink,
          ),
        );
        i = codeSpan.endIndex;
        continue;
      }
      var tickEnd = i + 1;
      while (tickEnd < input.length && input.codeUnitAt(tickEnd) == 0x60) {
        tickEnd++;
      }
      plain.write(input.substring(i, tickEnd));
      i = tickEnd;
      continue;
    }

    // Image syntax ![alt](url) — strip syntax, show alt text offline.
    if (unit == 0x21 &&
        i + 1 < input.length &&
        input.codeUnitAt(i + 1) == 0x5B) {
      final matched = _tryMatchBracketParen(input, i + 1);
      if (matched != null) {
        if (matched.label.isNotEmpty) {
          appendRuns(_parseInline(matched.label, style));
        }
        i = matched.endIndex;
        continue;
      }
    }

    // Link syntax [label](url).
    if (unit == 0x5B) {
      final matched = _tryMatchBracketParen(input, i);
      if (matched != null) {
        appendRuns(
          _parseInline(matched.label, style.copyWith(isLink: true)),
        );
        i = matched.endIndex;
        continue;
      }
    }

    // Inline HTML comments, autolinks, whitelisted HTML tags.
    if (unit == 0x3C) {
      final htmlResult = _tryParseInlineHtmlOrAutolink(input, i, style);
      if (htmlResult != null) {
        appendRuns(htmlResult.runs);
        i = htmlResult.endIndex;
        continue;
      }
    }

    // HTML entities (&amp;, &lt;, numeric entities, etc.).
    if (unit == 0x26) {
      final entity = _tryDecodeEntity(input, i);
      if (entity != null) {
        plain.write(entity.decoded);
        i = entity.endIndex;
        continue;
      }
    }

    // Strikethrough (~~text~~). Keep single ~ literal for ranges like 1~2.
    if (unit == 0x7E) {
      if (i + 1 < input.length && input.codeUnitAt(i + 1) == 0x7E) {
        final canOpen =
            i + 2 < input.length && !_isWhitespace(input.codeUnitAt(i + 2));
        if (canOpen) {
          final closeIndex = _findDoubleTildeClose(input, i + 2);
          if (closeIndex != null) {
            appendRuns(
              _parseInline(
                input.substring(i + 2, closeIndex),
                style.copyWith(strikethrough: true),
              ),
            );
            i = closeIndex + 2;
            continue;
          }
        }
        plain.write('~~');
        i += 2;
        continue;
      }
      plain.writeCharCode(unit);
      i++;
      continue;
    }

    // Emphasis and bold (* or _).
    if (unit == 0x2A || unit == 0x5F) {
      final delimChar = String.fromCharCode(unit);
      var runEnd = i + 1;
      while (runEnd < input.length && input.codeUnitAt(runEnd) == unit) {
        runEnd++;
      }
      final runLen = runEnd - i;
      if (runLen <= 3) {
        final matched = _tryMatchEmphasis(input, i, runLen, delimChar, style);
        if (matched != null) {
          appendRuns(matched.runs);
          i = matched.endIndex;
          continue;
        }
      }
      plain.write(input.substring(i, runEnd));
      i = runEnd;
      continue;
    }

    plain.writeCharCode(unit);
    i++;
  }

  flushPlain();
  return out;
}

class _CodeSpanMatch {
  const _CodeSpanMatch(this.text, this.endIndex);
  final String text;
  final int endIndex;
}

int? _findCodeSpanClose(String input, int openStart) =>
    _tryMatchCodeSpan(input, openStart)?.endIndex;

_CodeSpanMatch? _tryMatchCodeSpan(String input, int openStart) {
  var tickCount = 0;
  while (openStart + tickCount < input.length &&
      input.codeUnitAt(openStart + tickCount) == 0x60) {
    tickCount++;
  }
  if (tickCount == 0) return null;

  var j = openStart + tickCount;
  while (j < input.length) {
    if (input.codeUnitAt(j) == 0x60) {
      var closeCount = 0;
      while (j + closeCount < input.length &&
          input.codeUnitAt(j + closeCount) == 0x60) {
        closeCount++;
      }
      if (closeCount == tickCount) {
        var inner = input.substring(openStart + tickCount, j);
        inner = inner.replaceAll('\n', ' ');
        if (inner.length >= 2 &&
            inner.startsWith(' ') &&
            inner.endsWith(' ') &&
            inner.trim().isNotEmpty) {
          inner = inner.substring(1, inner.length - 1);
        }
        return _CodeSpanMatch(inner, j + closeCount);
      }
      j += closeCount;
      continue;
    }
    j++;
  }
  return null;
}

class _BracketParenMatch {
  const _BracketParenMatch(this.label, this.endIndex);
  final String label;
  final int endIndex;
}

_BracketParenMatch? _tryMatchBracketParen(String input, int openBracket) {
  var bracketDepth = 1;
  var j = openBracket + 1;
  while (j < input.length && bracketDepth > 0) {
    final unit = input.codeUnitAt(j);
    if (unit == 0x5C && j + 1 < input.length) {
      j += 2;
      continue;
    }
    if (unit == 0x60) {
      final close = _findCodeSpanClose(input, j);
      if (close != null) {
        j = close;
        continue;
      }
    }
    if (unit == 0x5B) {
      bracketDepth++;
    } else if (unit == 0x5D) {
      bracketDepth--;
      if (bracketDepth == 0) break;
    }
    j++;
  }
  if (bracketDepth != 0 ||
      j + 1 >= input.length ||
      input.codeUnitAt(j + 1) != 0x28) {
    return null;
  }

  final label = input.substring(openBracket + 1, j);
  var parenDepth = 1;
  var k = j + 2;
  while (k < input.length && parenDepth > 0) {
    final unit = input.codeUnitAt(k);
    if (unit == 0x0A) return null;
    if (unit == 0x5C && k + 1 < input.length) {
      k += 2;
      continue;
    }
    if (unit == 0x28) {
      parenDepth++;
    } else if (unit == 0x29) {
      parenDepth--;
      if (parenDepth == 0) break;
    }
    k++;
  }
  if (parenDepth != 0) return null;
  final rawDest = input.substring(j + 2, k).trim();
  if (!_looksLikeLinkDestination(rawDest)) return null;
  return _BracketParenMatch(label, k + 1);
}

bool _looksLikeLinkDestination(String dest) {
  if (dest.isEmpty) return true;
  if (dest.startsWith('<')) return dest.contains('>');
  final firstWhitespace = dest.indexOf(RegExp(r'\s'));
  if (firstWhitespace < 0) return true;
  final tail = dest.substring(firstWhitespace).trim();
  return tail.startsWith('"') || tail.startsWith("'") || tail.startsWith('(');
}

class _HtmlParseResult {
  const _HtmlParseResult(this.runs, this.endIndex);
  final List<ReleaseNotesInlineRun> runs;
  final int endIndex;
}

final _inlineCommentPattern = RegExp(r'<!--[\s\S]*?-->');
final _autolinkPattern = RegExp(r'<(https?://[^\s<>]+|mailto:[^\s<>]+)>');
final _brTagPattern = RegExp(r'<br\s*/?>', caseSensitive: false);
final _htmlOpenTagPattern = RegExp(r'<([a-zA-Z][a-zA-Z0-9]*)(?:\s[^<>]*)?>');

const _htmlBoldTags = {'b', 'strong'};
const _htmlItalicTags = {'i', 'em'};
const _htmlCodeTags = {'code', 'kbd'};
const _htmlStrikeTags = {'s', 'del', 'strike'};
const _htmlLinkTags = {'a'};
const _htmlStripTags = {'span', 'u', 'sup', 'sub', 'ins', 'p', 'div', 'small'};

_HtmlParseResult? _tryParseInlineHtmlOrAutolink(
  String input,
  int start,
  _InlineStyle style,
) {
  final commentMatch = _inlineCommentPattern.matchAsPrefix(input, start);
  if (commentMatch != null) {
    return _HtmlParseResult(const [], commentMatch.end);
  }

  final autolinkMatch = _autolinkPattern.matchAsPrefix(input, start);
  if (autolinkMatch != null) {
    final target = autolinkMatch.group(1)!;
    final display = target.startsWith('mailto:')
        ? target.substring('mailto:'.length)
        : target;
    return _HtmlParseResult([
      ReleaseNotesInlineRun(
        display,
        bold: style.bold,
        italic: style.italic,
        strikethrough: style.strikethrough,
        isLink: true,
      ),
    ], autolinkMatch.end);
  }

  final brMatch = _brTagPattern.matchAsPrefix(input, start);
  if (brMatch != null) {
    return _HtmlParseResult([
      ReleaseNotesInlineRun(
        '\n',
        bold: style.bold,
        italic: style.italic,
        strikethrough: style.strikethrough,
        isLink: style.isLink,
      ),
    ], brMatch.end);
  }

  final openMatch = _htmlOpenTagPattern.matchAsPrefix(input, start);
  if (openMatch == null) return null;
  final rawTag = openMatch.group(0)!;
  if (rawTag.endsWith('/>')) return null;
  final tagName = openMatch.group(1)!.toLowerCase();
  final supported =
      _htmlBoldTags.contains(tagName) ||
      _htmlItalicTags.contains(tagName) ||
      _htmlCodeTags.contains(tagName) ||
      _htmlStrikeTags.contains(tagName) ||
      _htmlLinkTags.contains(tagName) ||
      _htmlStripTags.contains(tagName);
  if (!supported) return null;

  final tagPair = _findClosingHtmlTag(input, openMatch.end, tagName);
  if (tagPair == null) return null;

  final inner = input.substring(openMatch.end, tagPair.closeStart);
  if (_htmlCodeTags.contains(tagName)) {
    return _HtmlParseResult([
      ReleaseNotesInlineRun(
        _decodeEntitiesOnly(inner),
        bold: style.bold,
        italic: style.italic,
        code: true,
        strikethrough: style.strikethrough,
        isLink: style.isLink,
      ),
    ], tagPair.closeEnd);
  }

  final nextStyle = style.copyWith(
    bold: style.bold || _htmlBoldTags.contains(tagName),
    italic: style.italic || _htmlItalicTags.contains(tagName),
    strikethrough: style.strikethrough || _htmlStrikeTags.contains(tagName),
    isLink: style.isLink || _htmlLinkTags.contains(tagName),
  );
  return _HtmlParseResult(_parseInline(inner, nextStyle), tagPair.closeEnd);
}

class _ClosingHtmlTag {
  const _ClosingHtmlTag(this.closeStart, this.closeEnd);
  final int closeStart;
  final int closeEnd;
}

_ClosingHtmlTag? _findClosingHtmlTag(
  String input,
  int searchStart,
  String tagName,
) {
  final anySameTag = RegExp(
    '<(/?)${RegExp.escape(tagName)}(?:\\s[^<>]*)?>',
    caseSensitive: false,
  );
  var depth = 1;
  for (final match in anySameTag.allMatches(input, searchStart)) {
    final full = match.group(0)!;
    final isClose = match.group(1) == '/';
    if (!isClose && full.endsWith('/>')) continue;
    depth += isClose ? -1 : 1;
    if (depth == 0) {
      return _ClosingHtmlTag(match.start, match.end);
    }
  }
  return null;
}

class _EntityMatch {
  const _EntityMatch(this.decoded, this.endIndex);
  final String decoded;
  final int endIndex;
}

final _entityPattern = RegExp(
  r'&(amp|lt|gt|quot|apos|nbsp|#(\d+)|#x([0-9a-fA-F]+));',
  caseSensitive: false,
);

_EntityMatch? _tryDecodeEntity(String input, int start) {
  final match = _entityPattern.matchAsPrefix(input, start);
  if (match == null) return null;
  final token = match.group(1)!.toLowerCase();
  final String? decoded = switch (token) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    'apos' => "'",
    'nbsp' => ' ',
    _ when match.group(2) != null => _codePointToString(
      int.tryParse(match.group(2)!),
    ),
    _ when match.group(3) != null => _codePointToString(
      int.tryParse(match.group(3)!, radix: 16),
    ),
    _ => null,
  };
  if (decoded == null) return null;
  return _EntityMatch(decoded, match.end);
}

String? _codePointToString(int? codePoint) {
  if (codePoint == null || codePoint <= 0 || codePoint > 0x10FFFF) return null;
  // Disallow UTF-16 surrogate code points.
  if (codePoint >= 0xD800 && codePoint <= 0xDFFF) return null;
  return String.fromCharCode(codePoint);
}

String _decodeEntitiesOnly(String input) {
  if (!input.contains('&')) return input;
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    if (input.codeUnitAt(i) == 0x26) {
      final decoded = _tryDecodeEntity(input, i);
      if (decoded != null) {
        out.write(decoded.decoded);
        i = decoded.endIndex;
        continue;
      }
    }
    out.writeCharCode(input.codeUnitAt(i));
    i++;
  }
  return out.toString();
}

int? _findDoubleTildeClose(String input, int searchStart) {
  var j = searchStart;
  while (j < input.length) {
    final unit = input.codeUnitAt(j);
    if (unit == 0x5C && j + 1 < input.length) {
      j += 2;
      continue;
    }
    if (unit == 0x60) {
      final close = _findCodeSpanClose(input, j);
      if (close != null) {
        j = close;
        continue;
      }
    }
    if (unit == 0x7E &&
        j + 1 < input.length &&
        input.codeUnitAt(j + 1) == 0x7E &&
        j > searchStart &&
        !_isWhitespace(input.codeUnitAt(j - 1))) {
      return j;
    }
    j++;
  }
  return null;
}

class _EmphasisMatch {
  const _EmphasisMatch(this.runs, this.endIndex);
  final List<ReleaseNotesInlineRun> runs;
  final int endIndex;
}

_EmphasisMatch? _tryMatchEmphasis(
  String input,
  int start,
  int runLen,
  String delimChar,
  _InlineStyle style,
) {
  final delimCode = delimChar.codeUnitAt(0);
  if (delimChar == '_' && start > 0 && _isAsciiAlnum(input.codeUnitAt(start - 1))) {
    return null;
  }
  if (start + runLen >= input.length ||
      _isWhitespace(input.codeUnitAt(start + runLen))) {
    return null;
  }

  for (var opLen = runLen; opLen >= 1; opLen--) {
    final closeIndex = _findClosingEmphasis(
      input,
      start + opLen,
      delimCode,
      opLen,
      allowFallback: opLen == 1 || opLen == runLen && opLen == 2,
    );
    if (closeIndex == null) continue;
    final inner = input.substring(start + opLen, closeIndex);
    final nextStyle = style.copyWith(
      bold: style.bold || opLen >= 2,
      italic: style.italic || opLen == 1 || opLen == 3,
    );
    return _EmphasisMatch(_parseInline(inner, nextStyle), closeIndex + opLen);
  }
  return null;
}

int? _findClosingEmphasis(
  String input,
  int searchStart,
  int delimCode,
  int targetLen, {
  required bool allowFallback,
}) {
  final stack = <int>[];
  int? fallback;
  var j = searchStart;

  while (j < input.length) {
    final unit = input.codeUnitAt(j);
    if (unit == 0x5C && j + 1 < input.length) {
      j += 2;
      continue;
    }
    if (unit == 0x60) {
      final close = _findCodeSpanClose(input, j);
      if (close != null) {
        j = close;
        continue;
      }
    }
    if (unit != delimCode) {
      j++;
      continue;
    }

    var spanEnd = j + 1;
    while (spanEnd < input.length && input.codeUnitAt(spanEnd) == delimCode) {
      spanEnd++;
    }
    var remaining = spanEnd - j;
    var cursor = j;

    final canClose =
        j > searchStart &&
        !_isWhitespace(input.codeUnitAt(j - 1)) &&
        (delimCode != 0x5F ||
            spanEnd >= input.length ||
            !_isAsciiAlnum(input.codeUnitAt(spanEnd)));
    final canOpen =
        spanEnd < input.length &&
        !_isWhitespace(input.codeUnitAt(spanEnd)) &&
        (delimCode != 0x5F ||
            j == 0 ||
            !_isAsciiAlnum(input.codeUnitAt(j - 1)));

    if (canClose && remaining >= targetLen && fallback == null) {
      fallback = j + (remaining - targetLen);
    }

    if (canClose) {
      while (stack.isNotEmpty && remaining >= stack.last) {
        final popped = stack.removeLast();
        cursor += popped;
        remaining -= popped;
      }
      if (stack.isEmpty && remaining >= targetLen) {
        if (remaining == targetLen || !canOpen) {
          return cursor;
        }
      }
    }

    if (canOpen && remaining > 0 && remaining <= 3) {
      stack.add(remaining);
    }
    j = spanEnd;
  }

  return allowFallback ? fallback : null;
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D ||
    codeUnit == 0x3000;

bool _isAsciiAlnum(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

bool _isAsciiPunctuation(int codeUnit) =>
    (codeUnit >= 0x21 && codeUnit <= 0x2F) ||
    (codeUnit >= 0x3A && codeUnit <= 0x40) ||
    (codeUnit >= 0x5B && codeUnit <= 0x60) ||
    (codeUnit >= 0x7B && codeUnit <= 0x7E);
